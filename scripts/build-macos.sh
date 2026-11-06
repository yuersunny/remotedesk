#!/usr/bin/env bash
# 一条命令：编译并启动 macOS 原生版。
# 前置：完整 Xcode + CocoaPods（先跑 ./scripts/mac-preflight.sh 确认）
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT/app"

# Flutter 可能不在 PATH（本机装在 ~/Applications/flutter）
if ! command -v flutter >/dev/null 2>&1; then
  for candidate in "$HOME/Applications/flutter/bin" /opt/homebrew/bin "$HOME/flutter/bin"; do
    if [ -x "$candidate/flutter" ]; then
      export PATH="$candidate:$PATH"
      break
    fi
  done
fi
if ! command -v flutter >/dev/null 2>&1; then
  echo "[x] 找不到 flutter。先跑 ./scripts/mac-preflight.sh 看看问题在哪。" >&2
  exit 1
fi

if [ ! -x /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild ]; then
  echo "[x] 没有完整 Xcode（只装 Command Line Tools 不够）。" >&2
  echo "    先跑 ./scripts/mac-preflight.sh 看具体缺什么。" >&2
  exit 1
fi

export PUB_HOSTED_URL="${PUB_HOSTED_URL:-https://pub.flutter-io.cn}"
export FLUTTER_STORAGE_BASE_URL="${FLUTTER_STORAGE_BASE_URL:-https://storage.flutter-io.cn}"

MODE="${1:-release}"   # release | debug | run

cd "$APP_DIR"

echo "==> flutter pub get"
flutter pub get

if [ "$MODE" = "run" ]; then
  echo "==> flutter run -d macos（热重载模式，Ctrl+C 退出）"
  exec flutter run -d macos
fi

echo "==> flutter build macos --$MODE"
flutter build macos "--$MODE"

BUNDLE="$APP_DIR/build/macos/Build/Products/$([ "$MODE" = "debug" ] && echo Debug || echo Release)/remotedesk.app"
if [ ! -d "$BUNDLE" ]; then
  echo "[x] 构建结束但没找到产物：$BUNDLE" >&2
  exit 1
fi

echo
echo "==> 用本机开发证书重签"
# adhoc 签名的指定要求是 cdhash，重建即变，系统里的辅助功能授权会显示"已开"
# 却对新二进制无效。换成证书签名后授权只需给一次。详见 scripts/mac-sign.sh。
if ! "$ROOT/scripts/mac-sign.sh" "$MODE"; then
  echo "[!] 重签失败：包仍可运行，但下次重建后辅助功能授权会再次失效" >&2
fi

echo
echo "==> 产物：$BUNDLE"
echo "==> 首次运行会被要求授权【屏幕录制】，授予后必须退出重开才生效"
open "$BUNDLE"
