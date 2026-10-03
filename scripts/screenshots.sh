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

shot() { # appearance scenario file [language]
  xcrun simctl ui "$UDID" appearance "$1"
  xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
  local lang="${4:-en}"
  xcrun simctl launch "$UDID" "$BUNDLE_ID" -demo "$2" -AppleLanguages "($lang)" -AppleLocale "$lang"
  sleep 4
  xcrun simctl io "$UDID" screenshot --type=png "$OUT/$3.png"
  echo "saved $OUT/$3.png"
}

rm -f "$OUT"/*.png
shot light active   1-backing-up
shot light idle     2-up-to-date
shot light settings 3-settings
shot light help     4-help
shot dark  active   5-dark
shot light setup    6-japanese ja
xcrun simctl ui "$UDID" appearance light
