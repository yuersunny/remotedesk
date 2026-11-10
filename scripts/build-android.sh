#!/usr/bin/env bash
# 一条命令：出安卓安装包（APK），放到 dist/ 下。
#
#   ./scripts/build-android.sh              # 只出 arm64（现在几乎所有手机）
#   ./scripts/build-android.sh --universal  # 出一个什么手机都能装的（大 30MB）
#
# 前置：Android SDK（本机在 ~/android-sdk）+ JDK 17 以上。脚本会自己找，
# 找不到就把缺什么说清楚，而不是让 Gradle 抛一屏 Java 堆栈。
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP_DIR="$ROOT/app"
DIST="$ROOT/dist"

UNIVERSAL=0
[ "${1:-}" = "--universal" ] && UNIVERSAL=1

# Flutter 可能不在 PATH（本机装在 ~/Applications/flutter）
if ! command -v flutter >/dev/null 2>&1; then
  for candidate in "$HOME/Applications/flutter/bin" "$HOME/flutter/bin" /opt/homebrew/bin; do
    if [ -x "$candidate/flutter" ]; then
      export PATH="$candidate:$PATH"
      break
    fi
  done
fi
command -v flutter >/dev/null 2>&1 || { echo "[x] 找不到 flutter" >&2; exit 1; }

# Android SDK：flutter 的配置里可能已经指好了，这里只兜底
export ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-$HOME/android-sdk}"
[ -d "$ANDROID_SDK_ROOT/platforms" ] || { echo "[x] 没有 Android SDK：$ANDROID_SDK_ROOT" >&2; exit 1; }
flutter config --android-sdk "$ANDROID_SDK_ROOT" >/dev/null 2>&1 || true

# JDK：Gradle 9 要 17+
if [ -z "${JAVA_HOME:-}" ] || [ ! -x "${JAVA_HOME}/bin/javac" ]; then
  for candidate in \
    "$HOME/Applications/jdk-21.0.13+9/Contents/Home" \
    "$HOME/android-build/jdk-17.0.2.jdk/Contents/Home" \
    "/Library/Java/JavaVirtualMachines/temurin-21.jdk/Contents/Home"; do
    if [ -x "$candidate/bin/javac" ]; then
      export JAVA_HOME="$candidate"
      break
    fi
  done
fi
[ -n "${JAVA_HOME:-}" ] || { echo "[x] 找不到 JDK 17+，装一个或设 JAVA_HOME" >&2; exit 1; }
flutter config --jdk-dir "$JAVA_HOME" >/dev/null 2>&1 || true

VERSION="$(awk '/^version:/{print $2}' "$APP_DIR/pubspec.yaml")"
VERSION="${VERSION%%+*}"
[ -n "$VERSION" ] || { echo "[x] pubspec.yaml 里读不到 version" >&2; exit 1; }

BUILD_ARGS=(build apk --release)
if [ "$UNIVERSAL" -eq 1 ]; then
  OUT_NAME="RemoteDesk-${VERSION}-android-universal.apk"
else
  BUILD_ARGS+=(--target-platform android-arm64)
  OUT_NAME="RemoteDesk-${VERSION}-android-arm64.apk"
fi

echo "[1/3] 编译（首次会下载 Gradle 与依赖，几分钟）…"
(cd "$APP_DIR" && flutter "${BUILD_ARGS[@]}")

mkdir -p "$DIST"
cp "$APP_DIR/build/app/outputs/flutter-apk/app-release.apk" "$DIST/$OUT_NAME"
echo "[2/3] 产物：dist/$OUT_NAME"

BT="$(ls -d "$ANDROID_SDK_ROOT"/build-tools/* 2>/dev/null | sort -V | tail -1 || true)"
if [ -n "$BT" ] && [ -x "$BT/apksigner" ]; then
  echo "[3/3] 验签："
  "$BT/apksigner" verify --print-certs "$DIST/$OUT_NAME" | head -2
else
  echo "[3/3] 跳过验签（没找到 apksigner）"
fi

echo
echo "装到手机：把这个 apk 传到手机（微信文件传输助手/数据线/局域网都行），"
echo "点开安装。第一次会提示「未知来源」，允许一次即可。"
