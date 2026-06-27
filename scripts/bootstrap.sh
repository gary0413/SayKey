#!/usr/bin/env bash
# One-shot setup for a FRESH Mac. Idempotent: safe to run again.
#
# Does everything needed to get SayKey running on a new machine:
#   1. install whisper.cpp + download the GGML model   (install_whisper.sh)
#   2. create a stable per-machine code-signing cert    (setup_signing.sh)
#   3. build dist/SayKey.app signed with that cert     (build_app.sh)
#
# After this finishes you still grant macOS Accessibility ONCE on this machine
# (see the printed instructions below). That grant then survives every
# future rebuild, because the app keeps the same signing identity.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "==> [1/3] whisper.cpp + model"
./scripts/install_whisper.sh

echo
echo "==> [2/3] stable code-signing identity (per-machine, never committed)"
./scripts/setup_signing.sh

echo
echo "==> [3/3] build the app"
./scripts/build_app.sh

cat <<'EOF'

============================================================
 SayKey is built. Last manual step on THIS machine only:
============================================================
 1. open dist/SayKey.app   (look for the mic menu-bar icon)
 2. Put the cursor in any text field.
 3. Press Control-Option-Space, speak, press it again to stop.
 4. If autoPaste is on, macOS asks for Accessibility the first
    time -> click "Open Settings" and tick SayKey.
    (If an OLD grey "SayKey" is already listed, remove it with
     the - button first, then let the app re-add itself.)

 You only grant Accessibility ONCE per machine. Because the app
 is signed with a stable self-signed cert, every later
 `swift build` / rebuild keeps the same grant.
============================================================
EOF
