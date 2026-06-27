#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="SayKey"
APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"

cd "$ROOT_DIR"

swift "$ROOT_DIR/scripts/make_icon.swift" "$ROOT_DIR/Resources/$APP_NAME.icns"
swift build -c release

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$ROOT_DIR/.build/release/$APP_NAME" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$ROOT_DIR/Resources/$APP_NAME.icns" "$APP_DIR/Contents/Resources/$APP_NAME.icns"
chmod +x "$APP_DIR/Contents/MacOS/$APP_NAME"

# Sign with the stable self-signed identity if it exists, so the Accessibility /
# Microphone grant survives rebuilds (the designated requirement stays pinned to
# this certificate instead of the per-build ad-hoc cdhash). Falls back to ad-hoc.
#
# NOTE: no --deep / --options runtime. The bundle has a single executable and no
# nested code; those flags are unnecessary here and can produce an inconsistent
# signature ("code has no resources but signature indicates they must be present")
# that silently degrades the designated requirement back to a cdhash.
SIGN_IDENTITY="SayKey Local Signing"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
  echo "Signing with stable identity: $SIGN_IDENTITY"
  codesign --force --sign "$SIGN_IDENTITY" "$APP_DIR"

  # Fail loudly if the identity signing did not produce a cert-pinned
  # designated requirement — otherwise the Accessibility grant would silently
  # reset on the next rebuild and we would be back to the original bug.
  if codesign -d -r- "$APP_DIR" 2>&1 | grep -q "certificate leaf"; then
    echo "Verified: designated requirement is pinned to the signing certificate."
  else
    echo "ERROR: signing did not pin to the certificate (got a cdhash requirement)." >&2
    echo "       The Accessibility grant would reset on rebuild. Aborting." >&2
    exit 1
  fi
elif command -v codesign >/dev/null 2>&1; then
  echo "WARNING: stable identity not found; falling back to ad-hoc (Accessibility grant will reset on each rebuild)."
  echo "         Run ./scripts/setup_signing.sh once to fix this permanently."
  codesign --force --sign - "$APP_DIR" >/dev/null
fi

touch "$APP_DIR"

echo "Built $APP_DIR"
echo "Run with: open '$APP_DIR'"
