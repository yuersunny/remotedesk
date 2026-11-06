#!/usr/bin/env bash
# 用本机自签名证书给 macOS 包重签。
#
# 为什么必须换掉 adhoc：
#   adhoc 签名的"指定要求"是 `cdhash H"..."`，也就是二进制的哈希。
#   每编译一次哈希就变，于是系统里那条辅助功能授权（System Settings ›
#   隐私与安全性 › 辅助功能）会**留在列表里显示"已开"，但对新二进制无效**，
#   表现为 AXIsProcessTrusted() 一直是 false，看着像"授权没保存"。
#   换成证书签名后，指定要求变成 `certificate leaf = H"..."`，
#   证书不变 → 重建不再失效，授权只需给一次。
#
# 用法：
#   ./scripts/mac-sign.sh          # 重签 Debug 产物（默认）
#   ./scripts/mac-sign.sh release  # 重签 Release 产物
#
# 幂等：证书已存在就跳过创建；每次只做签名 + 校验。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT/app"

KEYCHAIN="$HOME/Library/Keychains/remotedesk-dev.keychain-db"
KEYCHAIN_PASS="remotedesk"          # 只保护本机开发证书，不是机密
IDENTITY="RemoteDesk Dev"

MODE="${1:-debug}"
if [ "$MODE" != "debug" ] && [ "$MODE" != "release" ]; then
  echo "[x] 参数只能是 debug 或 release，收到：$MODE" >&2
  exit 2
fi

PRODUCT_DIR=$([ "$MODE" = "debug" ] && echo Debug || echo Release)
ENT_NAME=$([ "$MODE" = "debug" ] && echo DebugProfile || echo Release)
BUNDLE="$APP_DIR/build/macos/Build/Products/$PRODUCT_DIR/remotedesk.app"
ENTITLEMENTS="$APP_DIR/macos/Runner/$ENT_NAME.entitlements"

if [ ! -d "$BUNDLE" ]; then
  echo "[x] 没找到产物：$BUNDLE" >&2
  echo "    先跑 ./scripts/build-macos.sh $MODE" >&2
  exit 1
fi
if [ ! -f "$ENTITLEMENTS" ]; then
  echo "[x] 没找到 entitlements：$ENTITLEMENTS" >&2
  exit 1
fi

# ---- 1. 需要时创建证书 ------------------------------------------------------
ensure_keychain() {
  if security find-certificate -c "$IDENTITY" "$KEYCHAIN" >/dev/null 2>&1; then
    return 0
  fi

  # ${...} 必须带花括号：紧跟全角「」时 bash 会把多字节字符嚼进变量名
  echo "==> 创建自签名代码签名证书「${IDENTITY}」"
  local tmp
  tmp="$(mktemp -d)"
  # 双引号让路径立即展开：RETURN 之后 $tmp 已出作用域，set -u 会报 unbound
  trap "rm -rf '$tmp'" EXIT

  cat > "$tmp/openssl.cnf" <<'CNF'
[ req ]
distinguished_name = dn
prompt             = no
[ dn ]
CN = RemoteDesk Dev
O  = RemoteDesk (local dev only)
[ code ]
basicConstraints     = critical,CA:false
keyUsage             = critical,digitalSignature
extendedKeyUsage     = critical,codeSigning
subjectKeyIdentifier = hash
CNF

  openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$tmp/key.pem" -out "$tmp/cert.pem" \
    -config "$tmp/openssl.cnf" -extensions code >/dev/null 2>&1
  # -name 决定钥匙串里显示的名字，必须和 IDENTITY 一致
  openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
    -name "$IDENTITY" -out "$tmp/id.p12" -passout "pass:$KEYCHAIN_PASS" >/dev/null 2>&1

  if [ ! -f "$KEYCHAIN" ]; then
    security create-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN" >/dev/null
  fi
  security set-keychain-settings -lut 21600 "$KEYCHAIN"   # 空闲 6 小时才锁
  security unlock-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN"
  # -A 让任意进程可用该私钥（本机开发证书），免得签名时弹钥匙串密码框
  security import "$tmp/id.p12" -k "$KEYCHAIN" -P "$KEYCHAIN_PASS" \
    -T /usr/bin/codesign -A >/dev/null
  # macOS 10.15+ 必须显式授权 codesign 访问私钥，否则会卡在授权框
  security set-key-partition-list -S apple-tool:,apple:,codesign: \
    -s -k "$KEYCHAIN_PASS" "$KEYCHAIN" >/dev/null 2>&1

  if ! security find-certificate -c "$IDENTITY" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "[x] 证书导入失败，钥匙串里没有「$IDENTITY」" >&2
    exit 1
  fi
}

# codesign 只在自己的搜索列表里找身份，把开发钥匙串挂到用户搜索列表最前面
ensure_search_list() {
  local current
  current="$(security list-keychains -d user | sed 's/^[[:space:]]*"//; s/"$//' | tr -d '\r')"
  case "$current" in
    *"$KEYCHAIN"*) ;;
    *)
      # shellcheck disable=SC2086
      security list-keychains -d user -s "$KEYCHAIN" $current
      ;;
  esac
}

ensure_keychain
security unlock-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN"
ensure_search_list

# ---- 2. 签名 ----------------------------------------------------------------
echo "==> 重签：$PRODUCT_DIR/remotedesk.app"
# 只签 app 本体（主可执行文件 + 资源封印）。内部 Flutter 框架保持原样，
# 用 --deep 会把 app 的 entitlements 硬塞给框架，反而容易签坏。
codesign --force --sign "$IDENTITY" \
  --keychain "$KEYCHAIN" \
  --entitlements "$ENTITLEMENTS" \
  --timestamp=none \
  "$BUNDLE"

codesign --verify --strict --verbose=2 "$BUNDLE" 2>&1 | tail -2

# ---- 3. 校验：指定要求必须不再是 cdhash -------------------------------------
# 输出前缀在不同版本上是 "# designated =>" 或 "designated =>"，两种都吃
REQUIREMENT="$(codesign -d -r- "$BUNDLE" 2>&1 | sed -n 's/^[# ]*designated => //p')"
echo "==> 指定要求：$REQUIREMENT"
case "$REQUIREMENT" in
  *cdhash*)
    echo "[x] 仍然绑在 cdhash 上，重建会再次失效——说明签名没换成证书身份" >&2
    exit 1
    ;;
  *certificate*) echo "==> OK：指定要求绑在证书上，重建后授权不会失效" ;;
  *) echo "[!] 未识别的指定要求形式，请人工确认" >&2 ;;
esac

echo
echo "==> 签名者：$(codesign -dv --verbose=2 "$BUNDLE" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
echo "==> 沙盒：$(codesign -d --entitlements - "$BUNDLE" 2>/dev/null | grep -c 'app-sandbox' || true) 处 app-sandbox（应为 0）"
