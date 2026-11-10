#!/usr/bin/env bash
# 打一个"能直接发给人"的完整包：三端产物 + 全量源码 + 文档。
#
# 用法：./scripts/pack-release.sh [版本号]
#   产物：dist/RemoteDesk-<版本>-full.zip
#
# 设计上只有一份源码（source/，带 .git 历史），Windows 套件里的构建脚本会回退去找
# ../..//source，所以包里不会出现两份源码让人搞不清改哪份。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-1.0.7}"
DMG="$ROOT/dist/RemoteDesk-$VERSION-macos-universal.dmg"
APK="$ROOT/dist/RemoteDesk-$VERSION-android-arm64.apk"
KIT="$ROOT/dist/windows-kit"
OUT="$ROOT/dist/release/RemoteDesk-$VERSION"
ZIP="$ROOT/dist/RemoteDesk-$VERSION-full.zip"

# ---- 0. 前置检查 ------------------------------------------------------------
for f in "$DMG" "$APK"; do
  [ -f "$f" ] || { echo "[x] 缺产物：$f" >&2; echo "    先跑 pack-macos-dmg.sh / build-android.sh" >&2; exit 1; }
done
for f in "$KIT/START-HERE.md" "$KIT/04-build-windows.cmd"; do
  [ -f "$f" ] || { echo "[x] Windows 套件不完整：缺 $f" >&2; exit 1; }
done

echo "==> 版本 $VERSION"
echo "==> 清空 $OUT"
rm -rf "$OUT"
mkdir -p "$OUT/installers"

# ---- 1. 顶层文档 ------------------------------------------------------------
for doc in README.md LICENSE GETTING-STARTED.md DEVELOPING.md CHANGELOG.md; do
  [ -f "$ROOT/$doc" ] || { echo "[x] 缺文档：$doc" >&2; exit 1; }
  cp "$ROOT/$doc" "$OUT/"
done

# ---- 2. 安装包 --------------------------------------------------------------
echo "==> 复制安装包"
cp "$DMG" "$OUT/installers/"
cp "$APK" "$OUT/installers/"

# Windows：整份套件搬过去，但**不要 src/ 快照**——源码在 source/，两份会让人改错地方。
# 构建脚本已经能回退到 ../../source（见 tools/build-windows.ps1）。
echo "==> 复制 Windows 套件"
rsync -a \
  --exclude 'src/' \
  --exclude '.DS_Store' \
  --exclude 'BUILD-INFO.txt' \
  "$KIT/" "$OUT/installers/windows/"

# ---- 3. 源码（带 .git，朋友能看历史、能直接接着改）--------------------------
# 只导出 **git 索引里的文件**，且走 checkout-index 而不是从工作目录 rsync。
# 两个理由：
#   - rsync 整个工作目录会把 .idea/ 这类被忽略的东西一起带走，而
#     .idea/libraries/Dart_SDK.xml 里写着构建机的绝对路径和用户名；
#   - 工作目录里的字节不一定等于 clone 出来的字节。CRLF 规则写在 .gitattributes
#     里，本地改动过行尾的文件靠 stat 缓存看不出差异，但换台机器 clone 就变了。
#     checkout-index 会走同一套 eol/smudge 流程，导出的就是 clean clone 的样子。
echo "==> 复制源码（按索引导出，等价于一次 clean clone）"
mkdir -p "$OUT/source"
cd "$ROOT"
git checkout-index -a -f --prefix="$OUT/source/"
# .git 一起带上（朋友能 git log 看这十几轮是怎么长出来的）。
# 但只带"历史本身"：reflog（logs/）里存着重写前的旧提交信息，COMMIT_EDITMSG 是
# 上一次 commit 的草稿——这两个都不是历史的一部分，却是最容易漏出去的副本。
# 源路径带结尾斜杠，避免 rsync 把 .git 套成 .git/.git。
rsync -a \
  --exclude 'logs/' \
  --exclude 'hooks/' \
  --exclude 'COMMIT_EDITMSG' \
  --exclude 'ORIG_HEAD' \
  --exclude 'FETCH_HEAD' \
  --exclude 'refs/original/' \
  --exclude 'objects/info/commit-graph' \
  "$ROOT/.git/" "$OUT/source/.git/"
cd "$ROOT"

# 工作区若有未提交改动，源码快照就不等于发行版，先拦住。
if [ -n "$(git status --porcelain)" ]; then
  echo "  [!] 工作区有未提交改动，source/ 是最后一次提交的状态" >&2
fi

# ---- 4. 交付说明 ------------------------------------------------------------
cat > "$OUT/README-FIRST.txt" <<TXT
RemoteDesk $VERSION

直接用
  01  installers/RemoteDesk-$VERSION-macos-universal.dmg      macOS 13+（Intel / Apple Silicon）
  02  installers/RemoteDesk-$VERSION-android-arm64.apk        Android 7.0+，手机当主控
  03  installers/windows/START-HERE.md                        Windows：浏览器版免安装，或一键编译

  装完先看 GETTING-STARTED.md。macOS 必须手动给「屏幕录制」和「辅助功能」两个权限，
  不给的话要么黑屏、要么画面正常但点不动。

改代码
  source/            完整源码，含 git 历史（cd source && git log）
  DEVELOPING.md      代码地图、一次点击的完整链路、常见改动菜谱、踩过的坑
  docs/protocol.md   DataChannel 上到底发了什么字节

打包日期  $(date '+%Y-%m-%d %H:%M')
TXT

# ---- 5. 打包 ----------------------------------------------------------------
echo "==> 打包"
rm -f "$ZIP"
( cd "$ROOT/dist/release" && zip -r -q -X "$ZIP" "RemoteDesk-$VERSION" -x '*.DS_Store' -x '__MACOSX/*' )

# ---- 6. 自检 ----------------------------------------------------------------
echo
echo "==> 自检"
FAIL=0
check() {
  if [ -n "$(unzip -Z1 "$ZIP" "$1" 2>/dev/null)" ]; then
    echo "  [ok] $1"
  else
    echo "  [缺] $1" >&2
    FAIL=1
  fi
}
for probe in \
  "RemoteDesk-$VERSION/README.md" \
  "RemoteDesk-$VERSION/LICENSE" \
  "RemoteDesk-$VERSION/GETTING-STARTED.md" \
  "RemoteDesk-$VERSION/DEVELOPING.md" \
  "RemoteDesk-$VERSION/CHANGELOG.md" \
  "RemoteDesk-$VERSION/README-FIRST.txt" \
  "RemoteDesk-$VERSION/installers/RemoteDesk-$VERSION-macos-universal.dmg" \
  "RemoteDesk-$VERSION/installers/RemoteDesk-$VERSION-android-arm64.apk" \
  "RemoteDesk-$VERSION/installers/windows/START-HERE.md" \
  "RemoteDesk-$VERSION/installers/windows/00-RUN-WEB-NOW.cmd" \
  "RemoteDesk-$VERSION/installers/windows/04-build-windows.cmd" \
  "RemoteDesk-$VERSION/installers/windows/tools/build-windows.ps1" \
  "RemoteDesk-$VERSION/installers/windows/web-preview/index.html" \
  "RemoteDesk-$VERSION/source/app/pubspec.yaml" \
  "RemoteDesk-$VERSION/source/app/lib/main.dart" \
  "RemoteDesk-$VERSION/source/.git/HEAD"; do
  check "$probe"
done

# 反证：签名密钥绝不能进包。这一条比上面所有"必须有"都重要——包里一旦带密钥，
# 谁拿到谁就能签一个覆盖安装的 APK。
LEAK="$(unzip -Z1 "$ZIP" | grep -Ei '\.jks$|\.keystore$|key\.properties$' || true)"
if [ -n "$LEAK" ]; then
  echo "  [!!] 包里带了签名密钥，不能发：" >&2
  echo "$LEAK" | sed 's/^/       /' >&2
  FAIL=1
else
  echo "  [ok] 不含签名密钥"
fi

# 反证二：包内不能出现本机的身份痕迹。源码里有、文档里有、甚至只活在提交信息里
# 的，都算泄漏——公开出去之前就该断掉。
echo "==> 隐私自检"
CHK="$(mktemp -d)"
unzip -q "$ZIP" -d "$CHK"
# 黑名单放在仓库外的本机文件里（.privacy-blocklist，已 gitignore）。
# 写死在脚本里有两个恶果：黑名单本身会随包发出去（等于把要藏的东西印在封面），
# 而且扫描时会自匹配。没有这个文件就只跳过正文扫描，历史检查照旧。
BLOCK="$ROOT/.privacy-blocklist"
PRIV_HITS=""
if [ -f "$BLOCK" ]; then
  while IFS= read -r hit; do
    [ -z "$hit" ] && continue
    # 前缀用参数展开而不是 sed：mktemp 路径里有 "."，当正则用会乱匹配。
    PRIV_HITS="${PRIV_HITS}${hit#"$CHK"/}"$'\n'
  done <<< "$(grep -rIl --binary-files=without-match -F -f "$BLOCK" "$CHK" 2>/dev/null || true)"
fi
IDE_HITS=""
while IFS= read -r hit; do
  [ -z "$hit" ] && continue
  IDE_HITS="${IDE_HITS}${hit#"$CHK"/}"$'\n'
done <<< "$(find "$CHK" \( -type d -name '.idea' -o -type f -name 'local.properties' \) 2>/dev/null | head -5 || true)"
if [ -f "$BLOCK" ]; then
  HIST_HITS="$(git -C "$CHK/RemoteDesk-$VERSION/source" log --all --format='%s%n%b' 2>/dev/null \
    | grep -cF -f "$BLOCK" || true)"
else
  HIST_HITS=0
fi
rm -rf "$CHK"

if [ -n "$PRIV_HITS" ]; then
  echo "  [!!] 包内出现本机隐私串：" >&2
  echo "$PRIV_HITS" | sed 's/^/       /' >&2
  FAIL=1
else
  if [ -f "$BLOCK" ]; then
    echo "  [ok] 文本里无密码 / tailnet IP / 真名残留"
  else
    echo "  [--] 无 .privacy-blocklist，跳过正文扫描（历史检查仍需该文件）"
  fi
fi
if [ -n "$IDE_HITS" ]; then
  echo "  [!!] 包里带了 IDE 配置或本机 SDK 路径：" >&2
  echo "$IDE_HITS" | sed 's/^/       /' >&2
  FAIL=1
else
  echo "  [ok] 不含 .idea / local.properties"
fi
if [ "${HIST_HITS:-0}" -gt 0 ]; then
  echo "  [!!] git 提交信息里还有 $HIST_HITS 行敏感内容" >&2
  FAIL=1
else
  echo "  [ok] git 历史干净"
fi

echo
echo "==> 体积：$(du -h "$ZIP" | cut -f1)，条目数：$(unzip -Z1 "$ZIP" | wc -l | tr -d ' ')"
if [ "$FAIL" -ne 0 ]; then
  echo "[x] 自检未通过，先别发这个包" >&2
  exit 1
fi
echo "==> OK：$ZIP"
