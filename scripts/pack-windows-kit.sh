#!/usr/bin/env bash
# 把当前仓库快照进 dist/windows-kit/src/，再打成一个可以直接发到 Windows 机器的 zip。
#
# 为什么要重新快照而不是沿用旧的：
#   dist/windows-kit/src/ 是"要拿到 Windows 上编译"的源码副本。它不跟着 git 走，
#   所以代码改了却不重新快照，Windows 那边编译出来的就是旧逻辑——今天 M2 的
#   键盘修复和自检入口都还没进那个包里。
#
# 用法：./scripts/pack-windows-kit.sh [版本号]
#   默认版本 m2.2，产物 dist/remotedesk-windows-kit-<版本>.zip
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIT="$ROOT/dist/windows-kit"
SNAP="$KIT/src/remotedesk"
VERSION="${1:-m2.2}"
ZIP="$ROOT/dist/remotedesk-windows-kit-$VERSION.zip"

if [ ! -d "$KIT" ]; then
  echo "[x] 找不到套件目录：$KIT" >&2
  exit 1
fi
if [ ! -f "$KIT/START-HERE.md" ]; then
  echo "[x] $KIT 不像是套件目录（缺 START-HERE.md）" >&2
  exit 1
fi

# ---- 1. 刷新源码快照 --------------------------------------------------------
# 排除的都是"本机产物"：进了包只会让体积暴涨，或者在 Windows 上互相打架。
echo "==> 刷新源码快照 → $SNAP"
mkdir -p "$SNAP"
# --delete-excluded：否则被 --exclude 的旧文件会留在快照里（只有 --delete 时，
# 被排除的文件受保护、不会被删），于是上一个包的文件会跟着进新包。
rsync -a --delete --delete-excluded \
  --exclude '.git/' \
  --exclude '.DS_Store' \
  --exclude '*.iml' \
  --exclude 'dist/' \
  --exclude '.workbuddy/' \
  --exclude 'app/build/' \
  --exclude 'app/.dart_tool/' \
  --exclude 'app/.flutter-plugins' \
  --exclude 'app/.flutter-plugins-dependencies' \
  --exclude 'app/macos/Pods/' \
  --exclude 'app/macos/.symlinks/' \
  --exclude 'app/macos/Flutter/ephemeral/' \
  --exclude 'app/windows/flutter/ephemeral/' \
  --exclude 'app/ios/Pods/' \
  --exclude 'app/android/.gradle/' \
  --exclude '*.command' \
  "$ROOT/" "$SNAP/"

# ---- 2. 刷新网页版（路径 A 用的就是它） -------------------------------------
WEB="$ROOT/app/build/web"
if [ -d "$WEB" ]; then
  echo "==> 刷新 web-preview"
  rsync -a --delete --exclude '.DS_Store' "$WEB/" "$KIT/web-preview/"
else
  echo "[!] 没有 app/build/web，web-preview 保持原样（先跑 flutter build web）" >&2
fi

# ---- 3. 版本信息 ------------------------------------------------------------
# 出问题时第一件事是确认对方跑的是哪一版，所以把它写成文件放进包里。
# 仓库可能还没有 commit（本仓库就是这样），别写成 no-git 让人以为没装 git
if GIT_REV="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null)"; then
  GIT_REV="commit $GIT_REV"
else
  GIT_REV="未提交（工作区快照）"
fi
BUILT_AT="$(date '+%Y-%m-%d %H:%M:%S')"
cat > "$KIT/BUILD-INFO.txt" <<INFO
RemoteDesk Windows kit
版本      : $VERSION
打包时间  : $BUILT_AT
git       : $GIT_REV
源码快照  : src/remotedesk（不含 build/、.dart_tool/、macos/Pods）
INFO

# ---- 4. 打包 ----------------------------------------------------------------
echo "==> 打包 → $ZIP"
rm -f "$ZIP"
( cd "$ROOT/dist" && zip -r -q -X "$ZIP" windows-kit \
    -x '*.DS_Store' -x '__MACOSX/*' )

# ---- 5. 自检：包里必须有这几样，否则发过去也装不起来 -----------------------
echo
echo "==> 自检"
FAIL=0
for probe in \
  "windows-kit/START-HERE.md" \
  "windows-kit/BUILD-INFO.txt" \
  "windows-kit/src/remotedesk/app/pubspec.yaml" \
  "windows-kit/src/remotedesk/app/windows/runner/input_injector.cpp" \
  "windows-kit/src/remotedesk/app/lib/src/input_injector.dart" \
  "windows-kit/tools/build-windows.ps1" \
  "windows-kit/web-preview/index.html"; do
  # 用 -Z1 精确列出条目名：只 -l 会匹配到子串，缺文件也能"通过"
  if [ -n "$(unzip -Z1 "$ZIP" "$probe" 2>/dev/null)" ]; then
    echo "  [ok] $probe"
  else
    echo "  [缺] $probe" >&2
    FAIL=1
  fi
done
# 这一条是本次改动的关键：Windows 注入器必须带上自检方法
if unzip -p "$ZIP" windows-kit/src/remotedesk/app/windows/runner/input_injector.cpp \
     | grep -q pointerSelfTest; then
  echo "  [ok] Windows 注入器含 pointerSelfTest"
else
  echo "  [缺] 快照里的 Windows 注入器没有 pointerSelfTest" >&2
  FAIL=1
fi

echo
echo "==> 体积：$(du -h "$ZIP" | cut -f1)，文件数：$(unzip -Z1 "$ZIP" | wc -l | tr -d ' ')"
if [ "$FAIL" -ne 0 ]; then
  echo "[x] 自检未通过，先别发这个包" >&2
  exit 1
fi
echo "==> OK：$ZIP"
