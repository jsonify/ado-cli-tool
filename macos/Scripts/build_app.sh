#!/bin/bash
# Builds "ADO Desk.app" with ado_cli.py bundled as the engine (macOS only).
# Usage: Scripts/build_app.sh [--run]      (CONFIG=debug for a debug build)
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
APP_NAME="ADO Desk"
EXECUTABLE="ADODesk"
BUNDLE_ID="${ADODESK_BUNDLE_ID:-com.jsonify.adodesk}"
# Marketing version (About, Finder, the updater): ADODESK_VERSION (Scripts/release.sh sets it from --version or the
# git tag), else the newest v* tag, else ../version.txt, which release-please keeps current when its release PR is
# merged (.github/workflows/release-please.yml).
TAG=$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)
VERSION="${ADODESK_VERSION:-${TAG#v}}"
VERSION="${VERSION:-$(tr -d '[:space:]' < ../version.txt)}"
# Build number: the count of commits up to this one, so it goes up with every commit (CI needs the full history).
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 0)
# Shown in Settings -> Updates next to the version, so you can tell which commit is actually running. "+" marks a
# build with uncommitted changes.
COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo dev)
if [ -n "$(git status --porcelain --untracked-files=no 2>/dev/null)" ]; then COMMIT="$COMMIT+"; fi
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

# App icon: Resources/AppIcon.png (1024x1024, artwork inside Apple's icon grid) becomes AppIcon.icns with every size
# Finder and the Dock ask for.
ICON_SRC="Resources/AppIcon.png"
ICON_TMP="$(mktemp -d)"
ICONSET="$ICON_TMP/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$ICON_SRC" --out "$ICONSET/icon_${size}x${size}.png" > /dev/null
  sips -z "$((size * 2))" "$((size * 2))" "$ICON_SRC" --out "$ICONSET/icon_${size}x${size}@2x.png" > /dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICON_TMP"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
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
    <key>ADODeskCommit</key>
    <string>${COMMIT}</string>
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
echo "Built $(pwd)/$APP $VERSION ($BUILD, $COMMIT) (signed with $SIGNED)"
# Pass --run to launch it right away.
if [ "${1:-}" = "--run" ]; then open "$APP"; fi
