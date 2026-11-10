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
# 只复制 **git 跟踪的文件**。以前用 rsync 复制整个工作目录，于是 .idea/ 这类被
# .gitignore 忽略的东西也会跟着进包——IDE 配置里写着构建机的绝对路径和用户名。
# 以 git 索引为准，被忽略的一律不可能漏进来。
echo "==> 复制源码（仅 git 跟踪的文件）"
cd "$ROOT"
git ls-files -z | rsync -a --from0 --files-from=- ./ "$OUT/source/"
# .git 一起带上（朋友能 git log 看这十几轮是怎么长出来的），去掉重写残留。
rsync -a \
  --exclude 'hooks/' \
  --exclude 'objects/info/commit-graph' \
  "$ROOT/.git" "$OUT/source/.git"
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
PRIV_HITS="$(grep -rIl --binary-files=without-match \
  -E '7Q4WT9|100\.86\.168\.53|100\.108\.183\.61|某人|192\.168\.1\.123' \
  "$CHK" 2>/dev/null | sed "s|$CHK/||" || true)"
IDE_HITS="$(find "$CHK" -type d -name '.idea' -o -type f -name 'local.properties' 2>/dev/null \
  | sed "s|$CHK/||" | head -5)"
HIST_HITS="$(git -C "$CHK/RemoteDesk-$VERSION/source" log --all --format='%s%n%b' 2>/dev/null \
  | grep -cE '7Q4WT9|100\.86\.168\.53|100\.108\.183\.61|某人' || true)"
rm -rf "$CHK"

if [ -n "$PRIV_HITS" ]; then
  echo "  [!!] 包内出现本机隐私串：" >&2
  echo "$PRIV_HITS" | sed 's/^/       /' >&2
  FAIL=1
else
  echo "  [ok] 文本里无密码 / tailnet IP / 真名残留"
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
