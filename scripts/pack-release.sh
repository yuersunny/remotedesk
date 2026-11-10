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
echo "==> 复制源码"
rsync -a \
  --exclude 'dist/' \
  --exclude '.workbuddy/' \
  --exclude '.DS_Store' \
  --exclude 'app/build/' \
  --exclude 'app/.dart_tool/' \
  --exclude 'app/.flutter-plugins' \
  --exclude 'app/.flutter-plugins-dependencies' \
  --exclude 'app/macos/Pods/' \
  --exclude 'app/macos/.symlinks/' \
  --exclude 'app/macos/Flutter/ephemeral/' \
  --exclude 'app/windows/flutter/ephemeral/' \
  --exclude 'app/android/.gradle/' \
  --exclude 'app/android/keystore/' \
  --exclude 'app/android/key.properties' \
  --exclude 'app/android/local.properties' \
  --exclude 'node_modules/' \
  "$ROOT/" "$OUT/source/"

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

echo
echo "==> 体积：$(du -h "$ZIP" | cut -f1)，条目数：$(unzip -Z1 "$ZIP" | wc -l | tr -d ' ')"
if [ "$FAIL" -ne 0 ]; then
  echo "[x] 自检未通过，先别发这个包" >&2
  exit 1
fi
echo "==> OK：$ZIP"
