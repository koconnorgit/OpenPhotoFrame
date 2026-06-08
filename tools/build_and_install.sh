#!/usr/bin/env bash
#
# Build the OpenPhotoFrame release APK (arm64-v8a) and install it on a
# connected Android device over adb.
#
# This uses a self-contained Flutter/Android/JDK toolchain that lives outside
# the repo so nothing system-wide is required. Override any path via env vars.
#
# Usage:
#   tools/build_and_install.sh [adb-serial]
#
# If no serial is given and exactly one device is connected, that device is
# used. Pass a serial (see `adb devices`) to target a specific device.
#
# Env overrides:
#   TOOLCHAIN   root of the self-contained toolchain (default: ~/development/toolchain)
#   ABI         target ABI / flutter --target-platform (default: arm64-v8a / android-arm64)
#   BUILD_MODE  release | debug (default: release)
set -euo pipefail

TOOLCHAIN="${TOOLCHAIN:-$HOME/development/toolchain}"
BUILD_MODE="${BUILD_MODE:-release}"
ABI="${ABI:-arm64-v8a}"
SERIAL="${1:-}"

# --- Toolchain environment -------------------------------------------------
# Prefer an already-configured Flutter on PATH; otherwise fall back to the
# self-contained toolchain directory.
if ! command -v flutter >/dev/null 2>&1; then
  export JAVA_HOME="${JAVA_HOME:-$TOOLCHAIN/jdk}"
  export ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-$TOOLCHAIN/android-sdk}"
  export ANDROID_HOME="$ANDROID_SDK_ROOT"
  export PATH="$TOOLCHAIN/flutter/bin:$JAVA_HOME/bin:$ANDROID_SDK_ROOT/platform-tools:$PATH"
  export PUB_CACHE="${PUB_CACHE:-$TOOLCHAIN/.pub-cache}"
  export GRADLE_USER_HOME="${GRADLE_USER_HOME:-$TOOLCHAIN/.gradle}"
fi

# Run from the repo root (this script lives in <repo>/tools).
cd "$(dirname "$0")/.."

# Map ABI -> flutter --target-platform value.
case "$ABI" in
  arm64-v8a)   TARGET_PLATFORM="android-arm64" ;;
  armeabi-v7a) TARGET_PLATFORM="android-arm" ;;
  x86_64)      TARGET_PLATFORM="android-x64" ;;
  *) echo "Unsupported ABI: $ABI" >&2; exit 1 ;;
esac

echo "==> flutter pub get"
flutter pub get

echo "==> flutter build apk ($BUILD_MODE, $ABI)"
flutter build apk "--$BUILD_MODE" --target-platform "$TARGET_PLATFORM"

APK="build/app/outputs/flutter-apk/app-$BUILD_MODE.apk"
[ -f "$APK" ] || { echo "APK not found at $APK" >&2; exit 1; }
echo "==> built $APK ($(du -h "$APK" | cut -f1))"

# --- Install ---------------------------------------------------------------
ADB="${ANDROID_SDK_ROOT:-}/platform-tools/adb"
command -v adb >/dev/null 2>&1 && ADB="adb"

if [ -z "$SERIAL" ]; then
  mapfile -t DEVICES < <("$ADB" devices | awk 'NR>1 && $2=="device"{print $1}')
  if [ "${#DEVICES[@]}" -eq 0 ]; then
    echo "No connected device. Plug one in or pass a serial." >&2; exit 1
  elif [ "${#DEVICES[@]}" -gt 1 ]; then
    echo "Multiple devices connected; pass a serial:" >&2
    printf '  %s\n' "${DEVICES[@]}" >&2; exit 1
  fi
  SERIAL="${DEVICES[0]}"
fi

echo "==> installing on $SERIAL"
"$ADB" -s "$SERIAL" install -r "$APK"
echo "==> done"
