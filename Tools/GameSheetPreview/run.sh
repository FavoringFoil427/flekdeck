#!/bin/bash
#
# Preview harness for FlekGameWarningView (the "Recommended for games" sheet).
#
# Builds a tiny standalone SwiftUI app containing a copy of the sheet plus a
# picker for five different sheet-background treatments, then installs and
# launches it on a simulator. Deployment target is iOS 17.0, so the same binary
# runs on every runtime you have installed — which is the point: the sheet's
# appearance is decided by `#available` branches at runtime, not compile time.
#
# Usage:
#   ./run.sh              # first available runtime
#   ./run.sh 17           # first device on an iOS 17.x runtime
#   ./run.sh 26           # first device on an iOS 26.x runtime
#   ./run.sh <UDID>       # a specific device
#
# Once running, pick a background treatment in the wheel and tap "Show sheet".
# Or drive it by URL, which is handy for scripted screenshots:
#   xcrun simctl openurl booted gspreview://variant/0   # 0 = shipping code
#   xcrun simctl openurl booted gspreview://variant/1   # 1 = legacy .clear
#   xcrun simctl openurl booted gspreview://variant/2   # 2 = system default
#   xcrun simctl openurl booted gspreview://variant/3   # 3 = Flek glass
#   xcrun simctl openurl booted gspreview://variant/4   # 4 = .regularMaterial
#   xcrun simctl openurl booted gspreview://variant/5   # 5 = opaque
#
set -euo pipefail
cd "$(dirname "$0")"

BUNDLE_ID="com.flek.gamesheetpreview"
APP="build/GameSheetPreview.app"
SELECTOR="${1:-}"

# ---- pick a device -----------------------------------------------------------
if [[ "$SELECTOR" =~ ^[0-9A-F]{8}-[0-9A-F]{4} ]]; then
    UDID="$SELECTOR"
else
    UDID=$(xcrun simctl list devices available -j | python3 -c "
import json, sys, re
sel = ${SELECTOR:-0} if '${SELECTOR}'.isdigit() else 0
data = json.load(sys.stdin)['devices']
best = None
for runtime, devices in data.items():
    m = re.search(r'iOS-(\d+)-(\d+)', runtime)
    if not m: continue
    major = int(m.group(1))
    if sel and major != sel: continue
    for d in devices:
        if d.get('isAvailable') and 'iPhone' in d['name']:
            best = (d['udid'], d['name'], f\"{m.group(1)}.{m.group(2)}\")
            break
    if best: break
if not best:
    sys.exit('no matching iPhone simulator found')
print('\t'.join(best))
")
    IFS=$'\t' read -r UDID NAME VERSION <<< "$UDID"
    echo "device: $NAME (iOS $VERSION)"
fi

# ---- build -------------------------------------------------------------------
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
rm -rf build && mkdir -p "$APP"
cp Info.plist "$APP/Info.plist"
xcrun --sdk iphonesimulator swiftc \
    -sdk "$SDK" \
    -target arm64-apple-ios17.0-simulator \
    -parse-as-library \
    -o "$APP/GameSheetPreview" \
    Sources/*.swift
echo "built: $APP"

# ---- install + launch --------------------------------------------------------
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || true
open -a Simulator --args -CurrentDeviceUDID "$UDID" >/dev/null 2>&1 || true
xcrun simctl uninstall "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl install "$UDID" "$APP"
xcrun simctl launch "$UDID" "$BUNDLE_ID"
