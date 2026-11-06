#!/bin/bash
# 一次性收尾脚本：Xcode 装完之后跑这个。
# 这一步里有三条命令必须要管理员权限，而调用方（WorkBuddy）被系统禁止执行 sudo，
# 所以只能由你在终端里手动跑一次。跑完就能编译 macOS 版了。
#
# 用法：bash scripts/mac-setup-after-xcode.sh

set -u

XCODE_APP="/Applications/Xcode.app"
DEV_DIR="$XCODE_APP/Contents/Developer"

echo "=============================================="
echo " RemoteDesk macOS 构建环境收尾"
echo "=============================================="

# ---------- 1. Xcode 在不在 ----------
if [ ! -d "$XCODE_APP" ]; then
    echo "[x] 没找到 $XCODE_APP"
    echo "    Xcode 还没装完，或者正在 App Store 里下载。"
    echo "    打开 App Store 搜索 Xcode，点「获取」，等它下载完（约 7~8 GB）。"
    exit 1
fi

echo "[✓] Xcode 已存在"
/usr/bin/defaults read "$XCODE_APP/Contents/Info" CFBundleShortVersionString 2>/dev/null \
    | sed 's/^/    Xcode 版本: /'

if [ ! -d "$DEV_DIR" ]; then
    echo "[x] Xcode.app 里没有 Contents/Developer，安装可能不完整。"
    echo "    建议删掉 Xcode.app 重新从 App Store 下载。"
    exit 1
fi

# ---------- 2. 三条需要管理员权限的命令 ----------
echo
echo "接下来需要输入一次管理员密码（sudo），会做三件事："
echo "  1) 把 xcode-select 指向 Xcode.app（而不是命令行工具）"
echo "  2) 接受 Xcode 许可协议"
echo "  3) 安装 Xcode 的附加组件（首次启动准备）"
echo
sudo -v || { echo "[x] 密码没通过，已退出。"; exit 1; }

echo
echo "--- 1/3 xcode-select --switch ---"
sudo xcode-select --switch "$DEV_DIR" || echo "[!] 切换失败（可能已经指向 Xcode）"

echo "--- 2/3 接受许可协议 ---"
sudo xcodebuild -license accept 2>&1 | tail -3 || echo "[!] 协议这一步返回非零（通常表示已经接受过）"

echo "--- 3/3 安装附加组件 ---"
sudo xcodebuild -runFirstLaunch 2>&1 | tail -5 || echo "[!] runFirstLaunch 返回非零，先往下走，编译时会暴露真实问题"

# ---------- 3. 自检 ----------
echo
echo "=============================================="
echo " 自检"
echo "=============================================="

echo -n "xcode-select 指向: "; /usr/bin/xcode-select -p

if /usr/bin/xcodebuild -version >/tmp/rd-xcodever.txt 2>/tmp/rd-xcodeerr.txt; then
    sed 's/^/    /' /tmp/rd-xcodever.txt
else
    echo "[x] xcodebuild -version 仍然失败："
    sed 's/^/    /' /tmp/rd-xcodeerr.txt
    exit 1
fi

echo -n "macOS SDK: "
/usr/bin/xcodebuild -showsdks 2>/dev/null | grep -i macosx | head -1 | sed 's/^ *//'

echo -n "CocoaPods: "
if command -v pod >/dev/null 2>&1; then
    pod --version
else
    echo "不在 PATH 里（新开一个终端窗口即可，~/.zshrc 已经配好）"
fi

echo
echo "全部就绪。回到 WorkBuddy 说一声，我接着编译 macOS 版并做端到端验证。"
