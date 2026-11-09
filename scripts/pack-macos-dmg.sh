#!/usr/bin/env bash
# 打包 macOS 分发包：构建 Release → 重签 → 装进 dmg。
#
#   ./scripts/pack-macos-dmg.sh            # 版本取 1.0.0
#   ./scripts/pack-macos-dmg.sh 1.1.0      # 指定版本号（只影响 dmg 文件名与卷标）
#
# 产物：dist/RemoteDesk-<版本>-macos-universal.dmg
#
# 为什么说明文件里要写"右键打开/去隔离标记"：本程序是自签名证书，
# 不是付费开发者证书，也没有公证，所以 spctl 会判 rejected。
# 从 U 盘或本机拷过去通常不带 quarantine 标记、可以直接双击；
# 从网上下载的会被拦，dmg 里放的 .command 就是给这种情况兜底的。
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
VER="${1:-1.0.0}"

APP="$ROOT/app/build/macos/Build/Products/Release/remotedesk.app"
OUT="$ROOT/dist/RemoteDesk-$VER-macos-universal.dmg"

echo "==> 构建 Release（内部会调 mac-sign.sh 重签）"
./scripts/build-macos.sh release

if [ ! -d "$APP" ]; then
  echo "构建产物不存在：$APP" >&2
  exit 1
fi

echo
echo "==> 核对产物"
BUNDLE_VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
echo "    bundle 版本: ${BUNDLE_VER}（dmg 文件名用 ${VER}）"
echo "    架构: $(lipo -archs "$APP/Contents/MacOS/remotedesk")"
echo "    大小: $(du -sh "$APP" | cut -f1)"
if ! strings -a "$APP/Contents/MacOS/remotedesk" | grep -q "remotedesk/input"; then
  echo "注入器通道没链进二进制，产物不完整" >&2
  exit 1
fi
echo "    注入器: 已链入"

echo
echo "==> 组装镜像内容"
STAGE="$(mktemp -d)"
trap "rm -rf '$STAGE'" EXIT

cp -R "$APP" "$STAGE/RemoteDesk.app"
ln -s /Applications "$STAGE/Applications"

cat > "$STAGE/使用说明.txt" <<'TXT'
RemoteDesk  macOS 版
======================

装起来
------
1. 把左边的 RemoteDesk.app 拖到右边 Applications 文件夹。
2. 从「启动台」或「应用程序」里双击打开。

支持 Intel 与 Apple Silicon（Universal 二进制），要求 macOS 12 或更高。


第一次打开可能被系统拦一下
--------------------------
本程序用自签名证书（不是 App Store / 付费开发者证书），
所以有些情况首次双击会提示「无法验证开发者」或「已损坏」。

按来源分两种：

  A. 从 U 盘、局域网共享、自己另一台机器拷过来的
     —— 一般不会拦，直接双击即可。

  B. 从网上下载得到的
     —— 双击本镜像里的「遇到拦截时双击我.command」，它会自动解除标记并启动。
        也可以自己开「终端」执行这一条：
            xattr -dr com.apple.quarantine /Applications/RemoteDesk.app

        或者在「系统设置 › 隐私与安全性」拉到最下面，
        看到「已阻止使用 RemoteDesk」时点「仍要打开」。

这一步只需要做一次，之后正常双击。


必须给的两项权限
----------------
启动后会弹窗，按提示同意；错过的话去「系统设置 › 隐私与安全性」手动打开：

  1. 屏幕录制  —— 没它就只看得到黑屏。★ 授予后必须完全退出程序再重开才生效。
  2. 辅助功能  —— 没它就只能看不能操作（鼠标键盘注入会静默失效，不报错）。

权限记在这台机器上，换机器要重新给一次。


怎么连（两步）
--------------
1. 在被控的那台机器上（通常是常开的那台）：
   - 打开「允许远程控制」开关
   - 你会看到「本机 ID」「连接密码」，下面还有一行
     「对方服务器填 ws://…」，这三样各点一下就能复制
   - 把它们发给操作的人

2. 在操作的那台机器上：
   - 在「连接另一台电脑」里填对方的 ID 和密码
   - 第一次用，要在「高级设置 → 信令服务器」里粘一次上面那个地址
   - 点「连接」，对方的屏幕就出来了

不需要再单独启动什么服务：这个 app 自己就监听 8787 当信令服务器。
地址只填一次，之后开机自动连。

   ★ 只让一台当服务器。两台都停在 127.0.0.1 各转各的，会都显示"在线"
     却互相看不到 —— 操作那台的设备列表里应当出现对方的 ID。
   ★ 末尾的 /ws 不能漏，这是最常见的失败原因。
   ★ 两台机器的「本机 ID」不能相同。
   ★ 连不上时，窗口最上面会有一段红字，写明它试的是哪个地址。

连不上想看原因：「高级设置」最下面有「打开日志目录」，
把里面的 app-*.log 发给维护的人，里面有每一步的结果。


已知限制
--------
- 主控端看到的箭头是自己画的，不是被控端系统那颗鼠标。
  好处是跟手不延迟（被控端的鼠标要走完采集、编码、网络，慢 80~500ms）；
  代价是看不到对方的"文本竖线／拉边框双箭头"这类形状变化，点击位置本身是准的。
- 被控端窗口在前台时，注入的鼠标键盘会打在程序自己身上（系统机制，非缺陷）。
  被控端请最小化窗口或切到别的应用。
- 被控端不能睡眠，否则连不上：  sudo pmset -a sleep 0
- 信令是明文 ws://，只在可信网络里用。要跨公网请走 Tailscale / WireGuard
  这类私有网络（app 内置的服务器没有 AUTH_TOKEN 开关，那是 server/ 里
  Node 版才有的功能）。
- 内置服务器跟着程序走：程序退出，别的机器就连不上这台了 ——
  这也是为什么被控端通常是那台常开着的机器。
TXT

# 注意：.command 绝不能带 BOM，否则 shebang 失效、双击只在终端里报错。
cat > "$STAGE/遇到拦截时双击我.command" <<'CMD'
#!/bin/bash
# 遇到「无法验证开发者 / 已损坏」时双击这个文件。
# 作用：去掉「从网上下载」的隔离标记，然后启动程序。不改动程序本身。

cd "$(dirname "$0")" || exit 1

APP="/Applications/RemoteDesk.app"
if [ ! -d "$APP" ]; then
  APP="$(pwd)/RemoteDesk.app"
fi

if [ ! -d "$APP" ]; then
  echo "没找到 RemoteDesk.app，请先把左侧的 RemoteDesk.app 拖到 Applications 文件夹。"
  echo
  read -r -p "按回车关闭…" _
  exit 1
fi

echo "正在解除系统隔离标记：$APP"
xattr -dr com.apple.quarantine "$APP" 2>/dev/null
[ -d "$(pwd)/RemoteDesk.app" ] && xattr -dr com.apple.quarantine "$(pwd)/RemoteDesk.app" 2>/dev/null

echo "完成，正在启动…"
open "$APP"
sleep 1
CMD
chmod +x "$STAGE/遇到拦截时双击我.command"

echo "==> 校验镜像内的签名"
codesign --verify --deep --strict "$STAGE/RemoteDesk.app"

echo "==> 生成 dmg"
mkdir -p "$ROOT/dist"
rm -f "$OUT"
hdiutil create -volname "RemoteDesk $VER" -srcfolder "$STAGE" -ov -format UDZO -fs HFS+ "$OUT" >/dev/null
hdiutil verify "$OUT" 2>&1 | tail -1

echo
echo "==> 自检"
MP="$(hdiutil attach -nobrowse -readonly "$OUT" 2>/dev/null | grep -o '/Volumes/.*' | tail -1)"
fail=0
for f in "RemoteDesk.app" "使用说明.txt" "遇到拦截时双击我.command" "Applications"; do
  if [ -e "$MP/$f" ]; then echo "    ✓ $f"; else echo "    ✗ 缺 $f"; fail=1; fi
done
codesign --verify --deep --strict "$MP/RemoteDesk.app" 2>/dev/null \
  && echo "    ✓ 签名有效" || { echo "    ✗ 签名校验失败"; fail=1; }
DR="$(codesign -d -r- "$MP/RemoteDesk.app" 2>&1 | sed -n 's/^[# ]*designated => //p')"
case "$DR" in
  *cdhash*) echo "    ✗ 指定要求是 cdhash，重建会丢辅助功能授权"; fail=1 ;;
  *"certificate root"*) echo "    ✓ 指定要求绑在证书上" ;;
  *) echo "    ? 无法判定：$DR" ;;
esac
hdiutil detach "$MP" -quiet 2>/dev/null || true

echo
if [ "$fail" -eq 0 ]; then
  echo "完成：${OUT}（$(du -h "$OUT" | cut -f1)）"
else
  echo "自检未通过，产物可能不可用：$OUT" >&2
  exit 1
fi
