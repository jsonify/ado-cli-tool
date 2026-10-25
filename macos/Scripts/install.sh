#!/bin/bash
# Installs or updates ADO Desk from the latest GitHub release (macOS only):
#   curl -fsSL https://raw.githubusercontent.com/jsonify/ado-desk/main/macos/Scripts/install.sh | bash
# Releases may be signed with a self-signed certificate, so Gatekeeper calls a copy downloaded in a browser "damaged".
# curl doesn't mark what it downloads as quarantined, so a copy installed this way just opens; and every release
# carries the same certificate, so the Keychain keeps letting ADO Desk read your token across updates.
# Pass a version to install that one instead: ... | bash -s -- 0.3.2
set -euo pipefail

REPO=jsonify/ado-desk
APP_NAME="ADO Desk"
DEST="/Applications/$APP_NAME.app"

die() { echo "error: $*" >&2; exit 1; }
[ "$(uname -s)" = Darwin ] || die "ADO Desk runs on macOS only."

if [ -n "${1:-}" ]; then
  TAG="v${1#v}"
else
  # The latest release page redirects to .../releases/tag/vX.Y.Z.
  URL=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest") \
    || die "couldn't reach GitHub."
  TAG="${URL##*/}"
fi
[[ "$TAG" =~ ^v[0-9]+(\.[0-9]+)*$ ]] || die "no release found (got \"$TAG\")."
VERSION="${TAG#v}"
ZIP="ADO-Desk-$VERSION.zip"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
echo "Downloading ADO Desk $VERSION..."
curl -fsSL -o "$WORK/$ZIP" "https://github.com/$REPO/releases/download/$TAG/$ZIP" \
  || die "couldn't download $ZIP (the release may still be building; try again in a few minutes)."
curl -fsSL -o "$WORK/SHA256SUMS" "https://github.com/$REPO/releases/download/$TAG/SHA256SUMS" \
  || die "couldn't download SHA256SUMS."
(cd "$WORK" && grep " \*\{0,1\}$ZIP\$" SHA256SUMS | shasum -a 256 -c -s) \
  || die "$ZIP doesn't match its checksum; not installing it."
ditto -x -k "$WORK/$ZIP" "$WORK"
[ -d "$WORK/$APP_NAME.app" ] || die "$ZIP doesn't contain $APP_NAME.app."

# Quit a running copy so it isn't replaced under itself.
if pgrep -x ADODesk >/dev/null; then
  echo "Quitting ADO Desk..."
  osascript -e 'quit app "ADO Desk"' >/dev/null 2>&1 || pkill -x ADODesk || true
  for _ in $(seq 50); do pgrep -x ADODesk >/dev/null || break; sleep 0.1; done
fi

# /Applications is writable for admin users; otherwise ask for a password.
SUDO=""
[ -w /Applications ] || SUDO=sudo
echo "Installing to $DEST..."
$SUDO rm -rf "$DEST"
$SUDO ditto "$WORK/$APP_NAME.app" "$DEST"
# Nothing here is quarantined, but a copy dragged in from a browser download before would have been.
$SUDO xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

open "$DEST"
echo "ADO Desk $VERSION is installed and running."
