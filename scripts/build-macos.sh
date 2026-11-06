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

# 以前这里无条件把 PUB_HOSTED_URL 默认成国内镜像。代价是会被写进 pubspec.lock：
# 每个包的 description.url 从 https://pub.dev 变成 https://pub.flutter-io.cn，
# 于是 65 个依赖全部"changed"——版本一个没变，只是 host 变了。这一改动会顺带
# 把 Pods 判成过期，逼 Flutter 去跑 pod install，而本机没装 CocoaPods，构建直接
# 以「CocoaPods not installed or not in valid state.」失败。所以只在外部显式要求
# 时才用镜像，不要替用户改 lock。
if [ -n "${PUB_HOSTED_URL:-}" ]; then
  export FLUTTER_STORAGE_BASE_URL="${FLUTTER_STORAGE_BASE_URL:-https://storage.flutter-io.cn}"
  echo "==> 使用镜像源：$PUB_HOSTED_URL"
fi

MODE="${1:-release}"   # release | debug | run

cd "$APP_DIR"

# Flutter 用 Podfile.lock 与 Pods/Manifest.lock 是否逐字节相同来决定要不要跑
# pod install。这台机器没装 CocoaPods，一旦它决定要跑，构建就必然失败。Pods 目录
# 本身是按这份 lock 装好的，所以补一份同样的 Manifest.lock 即可——这不是掩盖问题，
# 而是把 CocoaPods 自己会写的那份文件补回去。
if [ -f macos/Podfile.lock ] && [ ! -f macos/Pods/Manifest.lock ]; then
  echo "==> 补 macos/Pods/Manifest.lock（本机无 CocoaPods，Pods 已按 Podfile.lock 装好）"
  cp macos/Podfile.lock macos/Pods/Manifest.lock
fi

# 依赖没动就别跑 pub get：它会把 lock 里的 host 改写一遍，白改还可能踩上面那个坑。
# 判据用内容指纹而不是 mtime——`git checkout` 会把文件时间刷成当前时间，
# 按时间比会误判成"依赖变了"。
PACKAGE_CONFIG=".dart_tool/package_config.json"
STAMP=".dart_tool/pub-inputs.sha"
CURRENT="$(shasum -a 256 pubspec.yaml pubspec.lock | shasum -a 256 | cut -d' ' -f1)"
PUB_FLAG=()
if [ -f "$PACKAGE_CONFIG" ] && [ "$(cat "$STAMP" 2>/dev/null)" = "$CURRENT" ]; then
  PUB_FLAG+=(--no-pub)
  echo "==> 依赖未变动（指纹 ${CURRENT}），跳过 pub get"
else
  echo "==> flutter pub get"
  flutter pub get
  printf '%s\n' "$CURRENT" > "$STAMP"
fi

if [ "$MODE" = "run" ]; then
  echo "==> flutter run -d macos（热重载模式，Ctrl+C 退出）"
  exec flutter run -d macos "${PUB_FLAG[@]}"
fi

echo "==> flutter build macos --$MODE"
flutter build macos "--$MODE" "${PUB_FLAG[@]}"

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
