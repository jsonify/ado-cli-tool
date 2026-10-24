#!/bin/bash
# Builds "ADO Desk.app" with ado_cli.py bundled as the engine (macOS only).
# Usage: Scripts/build_app.sh [--run]      (CONFIG=debug for a debug build)
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
APP_NAME="ADO Desk"
EXECUTABLE="ADODesk"
BUNDLE_ID="${ADODESK_BUNDLE_ID:-com.jsonify.adodesk}"
# Marketing version (About, Finder). Scripts/release.sh sets it from --version or the git tag.
VERSION="${ADODESK_VERSION:-0.1.0}"
# Build number: the commit, so you can tell which one is actually running.
BUILD=$(git rev-parse --short HEAD 2>/dev/null || echo dev)
ENGINE="../ado_cli.py"

if [[ ! -f "$ENGINE" ]]; then
    echo "error: engine not found at $ENGINE" >&2
    exit 1
fi

# ADODESK_STRICT=1 (set in CI) turns compiler warnings into errors so none slip through.
if [ "${ADODESK_STRICT:-}" = "1" ]; then
  swift build -c "$CONFIG" -Xswiftc -warnings-as-errors
else
  swift build -c "$CONFIG"
fi
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

APP="build/${APP_NAME}.app"
# A running copy keeps the old code, so quit it before replacing the bundle.
pkill -x "$EXECUTABLE" 2>/dev/null && sleep 0.5 || true
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
    <string>${BUILD}</string>
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

# Ad-hoc signing ("-") changes the app's identity on every build, so macOS asks again for access
# to the token in the Keychain. Sign with a stable certificate instead: ADODESK_SIGN_IDENTITY if set,
# otherwise "ADO Desk Dev" when it exists (create it once with Scripts/make_dev_cert.sh).
has_identity() { security find-identity -v -p codesigning | grep -q "\"$1\""; }
if [ -n "${ADODESK_SIGN_IDENTITY:-}" ]; then
  IDENTITY="$ADODESK_SIGN_IDENTITY"
  if [ "$IDENTITY" != "-" ] && ! has_identity "$IDENTITY"; then
    echo "warning: signing identity \"$IDENTITY\" not found; falling back to ad-hoc (Keychain access will be re-requested)." >&2
    echo "         Create it once with Scripts/make_dev_cert.sh" >&2
    IDENTITY="-"
  fi
elif has_identity "ADO Desk Dev"; then
  IDENTITY="ADO Desk Dev"
else
  echo "note: no \"ADO Desk Dev\" certificate; signing ad-hoc (Keychain access will be re-requested)." >&2
  echo "      Run Scripts/make_dev_cert.sh once to keep it across builds." >&2
  IDENTITY="-"
fi
codesign --force --sign "$IDENTITY" "$APP"
[ "$IDENTITY" = "-" ] && SIGNED="ad-hoc" || SIGNED="\"$IDENTITY\""
echo "Built $(pwd)/$APP $VERSION at $BUILD (signed with $SIGNED)"
# Pass --run to launch it right away.
if [ "${1:-}" = "--run" ]; then open "$APP"; fi
