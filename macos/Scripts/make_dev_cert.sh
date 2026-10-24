#!/bin/bash
# Creates a self-signed "ADO Desk Dev" code-signing certificate in your login keychain (macOS only).
# Signing every build with the same certificate keeps the app's identity stable, so macOS keeps
# letting it read the token it stored in the Keychain. Usage: Scripts/make_dev_cert.sh [name]
set -euo pipefail
NAME="${1:-ADO Desk Dev}"
if [[ "$NAME" == *=* || "$NAME" == -* ]]; then
  echo "error: \"$NAME\" doesn't look like a certificate name. Run with no arguments to create \"ADO Desk Dev\"." >&2
  exit 1
fi
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
  echo "\"$NAME\" already exists and is valid."; exit 0
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$NAME" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning"
# Legacy PBE algorithms so `security import` accepts the bundle from both LibreSSL and OpenSSL 3.
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" -passout pass:adodesk \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1
security import "$TMP/id.p12" -k "$KEYCHAIN" -P adodesk -T /usr/bin/codesign
# Trust it for code signing (asks for your login password / Touch ID once).
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

echo
security find-identity -v -p codesigning | grep "$NAME" || { echo "Certificate not valid yet; check Keychain Access."; exit 1; }
if [ "$NAME" = "ADO Desk Dev" ]; then
  echo "Done. Scripts/build_app.sh will now sign with it automatically."
else
  echo "Done. Build with:  ADODESK_SIGN_IDENTITY=\"$NAME\" Scripts/build_app.sh"
fi
echo "The first build may ask to let codesign use the key: click Always Allow."
