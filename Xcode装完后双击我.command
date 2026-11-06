#!/bin/bash
# 双击即可运行。会打开终端窗口，让你输一次密码。
cd "$(dirname "$0")" || exit 1
bash scripts/mac-setup-after-xcode.sh
echo
read -n 1 -s -r -p "按任意键关闭窗口…"
echo
