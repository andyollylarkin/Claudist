#!/bin/bash
# Builds dist/Claudist.app from the SwiftPM product (works with Command Line Tools only).
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=${1:-release}
swift build -c "$CONFIG" --product Claudist
BIN=$(swift build -c "$CONFIG" --show-bin-path)/Claudist

APP=dist/Claudist.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Claudist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>io.mindsw.claudist</string>
    <key>CFBundleName</key><string>Claudist</string>
    <key>CFBundleDisplayName</key><string>Claudist</string>
    <key>CFBundleExecutable</key><string>Claudist</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

# A stable local identity keeps the app's code identity across rebuilds, so Keychain
# "Always Allow" survives updates (scripts/make-signing-cert.sh creates it). Ad-hoc otherwise.
IDENTITY=${CLAUDIST_SIGN_IDENTITY:-Claudist Local Signing}
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
    codesign --force --sign "$IDENTITY" "$APP"
    echo "Signed with \"$IDENTITY\""
else
    codesign --force --sign - "$APP"
    echo "Signed ad-hoc (run scripts/make-signing-cert.sh for a stable signature)"
fi
echo "Built $APP"
