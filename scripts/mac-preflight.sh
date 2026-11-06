#!/usr/bin/env bash
# macOS 构建预检：只检查、不修改。缺什么、怎么补，直接打印出来。
set -uo pipefail

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; DIM=$'\033[2m'; NC=$'\033[0m'
ok=0; bad=0

# 中文按显示宽度对齐：UTF-8 里 1 个 CJK 字符占 3 字节，宽度算 2 列
pad() {
  local t="$1" w="$2" bytes chars vis n
  bytes=$(printf '%s' "$t" | wc -c | tr -d ' ')
  chars=$(printf '%s' "$t" | wc -m | tr -d ' ')
  vis=$(( chars + (bytes - chars) / 2 ))
  n=$(( w - vis ))
  [ "$n" -lt 0 ] && n=0
  printf '%s%*s' "$t" "$n" ''
}

item() { # item <状态> <名称> <详情>
  local mark="$1" name="$2" detail="${3:-}"
  case "$mark" in
    OK) printf "  %s[OK]%s  %s %s\n" "$GRN" "$NC" "$(pad "$name" 24)" "$detail" ;;
    WARN) printf "  %s[!!]%s  %s %s\n" "$YEL" "$NC" "$(pad "$name" 24)" "$detail" ;;
    *) printf "  %s[--]%s  %s %s\n" "$RED" "$NC" "$(pad "$name" 24)" "$detail" ;;
  esac
}

echo
echo "======== RemoteDesk · macOS 构建预检 ========"
echo

# ---------- 1. Xcode ----------
XCODE_APP="/Applications/Xcode.app"
if [ -d "$XCODE_APP" ]; then
  ver=$(defaults read "$XCODE_APP/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "?")
  item OK "Xcode" "$ver  ($XCODE_APP)"
  xcode_ok=1
else
  item "--" "Xcode" "未安装 —— flutter build macos 会直接失败"
  xcode_ok=0
  bad=$((bad+1))
fi

# ---------- 2. xcode-select 指向 ----------
sel=$(xcode-select -p 2>/dev/null || echo "")
if [ "$sel" = "$XCODE_APP/Contents/Developer" ]; then
  item OK "xcode-select" "$sel"
elif [ -n "$sel" ]; then
  item WARN "xcode-select" "${sel}（应为 Xcode.app/Contents/Developer）"
  [ "$xcode_ok" = 0 ] && bad=$((bad+1))
else
  item "--" "xcode-select" "未设置"
  bad=$((bad+1))
fi

# ---------- 3. xcodebuild ----------
if xcodebuild -version >/dev/null 2>&1; then
  item OK "xcodebuild" "$(xcodebuild -version 2>/dev/null | head -1)"
else
  item "--" "xcodebuild" "不可用（需完整 Xcode，只装 Command Line Tools 不够）"
  bad=$((bad+1))
fi

# ---------- 4. CocoaPods ----------
if command -v pod >/dev/null 2>&1; then
  item OK "CocoaPods" "$(pod --version 2>/dev/null)"
  pod_ok=1
else
  item "--" "CocoaPods" "未安装 —— flutter_webrtc 等插件编译依赖它"
  pod_ok=0
  bad=$((bad+1))
fi

# ---------- 5. Flutter ----------
if command -v flutter >/dev/null 2>&1; then
  item OK "Flutter" "$(flutter --version 2>/dev/null | head -1)"
else
  item "--" "Flutter" "不在 PATH（本机在 /Users/\$USER/Applications/flutter/bin）"
fi

# ---------- 6. 磁盘 ----------
avail_gb=$(df -g / | awk 'NR==2 {print $4}')
if [ "${avail_gb:-0}" -ge 50 ]; then
  item OK "磁盘可用" "${avail_gb} GB"
else
  item WARN "磁盘可用" "${avail_gb} GB —— Xcode 约需 50 GB（下载 12 + 展开 38）"
fi

# ---------- 结论 ----------
echo
echo "---------------- 结论 ----------------"
if [ "$xcode_ok" = 1 ] && [ "$pod_ok" = 1 ]; then
  echo "  ${GRN}环境就绪${NC}，直接跑："
  echo "     ./scripts/build-macos.sh"
else
  echo "  ${YEL}还不能编译 macOS 原生版。${NC}按下面顺序补："
  echo
  if [ "$xcode_ok" = 0 ]; then
    echo "  1) 装完整 Xcode（App Store 搜 Xcode，约 12 GB 下载 / 38 GB 展开）"
    echo "     ${DIM}也可以用 Apple ID 从 https://developer.apple.com/download/all/ 下 .xip${NC}"
    echo "     装完执行："
    echo "       sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
    echo "       sudo xcodebuild -license accept"
    echo "       sudo xcodebuild -runFirstLaunch"
    echo
    echo "     ${YEL}注意：本机当前只剩 ${avail_gb} GB，先腾空间。${NC}"
    echo "     ${DIM}大头在 ~/Library/Application Support 和 ~/Library/Containers，${NC}"
    echo "     ${DIM}先看看到底是谁占的：du -sh ~/Library/* | sort -rh | head${NC}"
    echo
  fi
  if [ "$pod_ok" = 0 ]; then
    echo "  2) 装 CocoaPods（系统 ruby 2.6 太老，建议走 Homebrew）："
    echo "       /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
    echo "       brew install cocoapods"
    echo "     ${DIM}或者：sudo gem install cocoapods（部分版本对 ruby 2.6 不兼容）${NC}"
    echo
  fi
  echo "  补完再跑一次本脚本复核。"
  echo
  echo "  ${DIM}只想立刻看到画面？网页版不需要 Xcode：${NC}"
  echo "     cd app/build/web && python3 -m http.server 8080 --bind 127.0.0.1"
  echo "     浏览器打开 http://localhost:8080/?id=mac"
  echo
fi
exit 0
