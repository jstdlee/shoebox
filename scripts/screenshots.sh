#!/usr/bin/env bash
# Take the README gallery screenshots from the demo mode of the app.
# Usage: scripts/screenshots.sh <simulator-udid> <path/to/Shoebox.app> <output-dir>
set -euo pipefail
UDID="$1"; APP="$2"; OUT="$3"
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")
mkdir -p "$OUT"

xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b
xcrun simctl install "$UDID" "$APP"
xcrun simctl status_bar "$UDID" override --time "9:41" --dataNetwork wifi --wifiMode active --wifiBars 3 \
  --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100

shot() { # appearance scenario file
  xcrun simctl ui "$UDID" appearance "$1"
  xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
  xcrun simctl launch "$UDID" "$BUNDLE_ID" -demo "$2"
  sleep 4
  xcrun simctl io "$UDID" screenshot --type=png "$OUT/$3.png"
  echo "saved $OUT/$3.png"
}

shot light active   1-backing-up
shot light idle     2-idle
shot light settings 3-schedule
shot dark  active   4-dark
xcrun simctl ui "$UDID" appearance light
