#!/usr/bin/env bash
#
# Connect to the photo-frame tablet over the network for wireless adb
# (deploying releases, logcat, screenshots, etc.).
#
# Usage:
#   tools/adb_connect.sh [ip] [port]
#
# Defaults: ip=$TABLET_IP or 10.254.1.210, port=5555
#
# Notes:
# - Android resets adb to USB-only mode on every reboot. If a USB cable is
#   plugged in, this script re-enables TCP mode automatically. If the tablet
#   has rebooted and no USB is attached, you must plug it in once and re-run
#   this (a non-rooted device can't re-enable wireless adb purely remotely).
# - Give the tablet a static IP / DHCP reservation so the address is stable.
set -euo pipefail

IP="${1:-${TABLET_IP:-10.254.1.210}}"
PORT="${2:-5555}"

ADB="${ANDROID_SDK_ROOT:-$HOME/development/toolchain/android-sdk}/platform-tools/adb"
command -v adb >/dev/null 2>&1 && ADB="adb"

# If a USB device is attached, (re)enable TCP mode on it first. This makes the
# script work after a reboot as long as the cable is plugged in.
usb_serial="$("$ADB" devices | awk '$2=="device" && $1 !~ /:/ {print $1; exit}')"
if [ -n "$usb_serial" ]; then
  echo "==> USB device $usb_serial found; enabling TCP mode on :$PORT"
  "$ADB" -s "$usb_serial" tcpip "$PORT" >/dev/null
  sleep 2
fi

echo "==> connecting to $IP:$PORT"
"$ADB" connect "$IP:$PORT"
echo "==> connected devices:"
"$ADB" devices -l

cat <<EOF

Wireless adb ready. Examples (pass the network serial explicitly when USB is
also attached):

  tools/build_and_install.sh $IP:$PORT          # build + deploy a release
  adb -s $IP:$PORT logcat flutter:I '*:S'       # app logs
  adb -s $IP:$PORT exec-out screencap -p > /tmp/frame.png
EOF
