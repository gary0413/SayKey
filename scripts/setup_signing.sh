#!/usr/bin/env bash
# Creates a stable, self-signed code-signing identity in the login keychain so
# that SayKey keeps the same code-signing "identity" across rebuilds. This is
# what lets the macOS Accessibility / Microphone grant survive `swift build`
# instead of being reset on every rebuild (which is what ad-hoc signing does).
#
# Safe to re-run: if the identity already exists, it does nothing.
set -euo pipefail

IDENTITY_NAME="SayKey Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$IDENTITY_NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "Signing identity '$IDENTITY_NAME' already exists. Nothing to do."
  exit 0
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

cat > "$WORK_DIR/cert.cnf" <<'EOF'
[ req ]
distinguished_name = dn
x509_extensions    = v3
prompt             = no
[ dn ]
CN = SayKey Local Signing
[ v3 ]
basicConstraints   = critical,CA:false
keyUsage           = critical,digitalSignature
extendedKeyUsage   = critical,codeSigning
EOF

echo "Generating self-signed code-signing certificate..."
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$WORK_DIR/key.pem" \
  -out    "$WORK_DIR/cert.pem" \
  -days 3650 \
  -config "$WORK_DIR/cert.cnf" >/dev/null 2>&1

openssl pkcs12 -export \
  -inkey "$WORK_DIR/key.pem" \
  -in    "$WORK_DIR/cert.pem" \
  -name  "$IDENTITY_NAME" \
  -out   "$WORK_DIR/identity.p12" \
  -passout pass:saykey >/dev/null 2>&1

echo "Importing identity into login keychain..."
# -T /usr/bin/codesign lets ONLY codesign use the key without a keychain prompt.
# We intentionally do NOT pass -A (which would let *any* app use the signing
# key silently). The first build may show a one-time keychain prompt — click
# "Always Allow".
security import "$WORK_DIR/identity.p12" \
  -k "$KEYCHAIN" \
  -P saykey \
  -T /usr/bin/codesign >/dev/null 2>&1

echo "Trusting certificate for code signing (user domain, no admin needed)..."
# User-domain trust only; does NOT touch the system trust store.
security add-trusted-cert \
  -p codeSign \
  -k "$KEYCHAIN" \
  "$WORK_DIR/cert.pem" >/dev/null 2>&1 || \
  echo "  (trust step was skipped/declined; codesign can still use the identity)"

echo
echo "Done. Verify with:"
echo "  security find-identity -v -p codesigning"
