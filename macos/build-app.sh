#!/usr/bin/env bash
# Build "ADO Desk.app" with ado_cli.py bundled as the engine.
#
#   ./build-app.sh              # release build into macos/build/
#   CONFIG=debug ./build-app.sh
set -euo pipefail

cd "$(dirname "$0")"

CONFIG="${CONFIG:-release}"
APP_NAME="ADO Desk"
EXECUTABLE="ADODesk"
BUNDLE_ID="${BUNDLE_ID:-com.jsonify.adodesk}"
VERSION="${VERSION:-0.1.0}"
ENGINE="../ado_cli.py"

if [[ ! -f "$ENGINE" ]]; then
    echo "error: engine not found at $ENGINE" >&2
    exit 1
fi

swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

APP="build/${APP_NAME}.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/$EXECUTABLE" "$APP/Contents/MacOS/$EXECUTABLE"
cp "$ENGINE" "$APP/Contents/Resources/ado_cli.py"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleExecutable</key>
    <string>${EXECUTABLE}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

# Ad-hoc signature so Gatekeeper and the Keychain treat the bundle consistently on this Mac.
if ! codesign --force --sign - "$APP" >/dev/null 2>&1; then
    echo "warning: ad-hoc codesign failed; the app will still run locally" >&2
fi

echo "Built $(pwd)/$APP"
