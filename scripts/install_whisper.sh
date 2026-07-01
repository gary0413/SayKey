#!/usr/bin/env bash
set -euo pipefail

# large-v3-turbo q5_0: near-large accuracy, fast on Apple Silicon, ~547MB.
# Much better than base for code-switched (中英混講) and imperfect-audio speech.
MODEL_DIR="$HOME/.saykey/models"
MODEL_PATH="$MODEL_DIR/ggml-large-v3-turbo-q5_0.bin"
MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin"
MODEL_SHA256="394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2"

# Silero VAD (~1MB): strips silence/noise before the encoder so quiet or empty
# clips stop producing hallucinated captions (config key enableVAD, default on).
VAD_PATH="$MODEL_DIR/ggml-silero-v6.2.0.bin"
VAD_URL="https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v6.2.0.bin"
VAD_SHA256="2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987"

# Download to a temp file, verify the SHA-256, then atomically rename. Guards
# against a corrupted/partial download or a tampered upstream (the HuggingFace
# resolve/main URLs are mutable) feeding untrusted model data to whisper.cpp.
fetch_verified() {
  local url="$1" dest="$2" want="$3" tmp
  [[ -f "$dest" ]] && return 0
  tmp="$dest.download"
  curl -L --fail --progress-bar -o "$tmp" "$url"
  local got
  got="$(shasum -a 256 "$tmp" | awk '{print $1}')"
  if [[ "$got" != "$want" ]]; then
    rm -f "$tmp"
    echo "ERROR: checksum mismatch for $(basename "$dest")" >&2
    echo "  expected $want" >&2
    echo "  got      $got" >&2
    exit 1
  fi
  mv "$tmp" "$dest"
}

if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew is required: https://brew.sh" >&2
  exit 1
fi

if ! command -v whisper-cli >/dev/null 2>&1; then
  brew install whisper-cpp
fi

# OpenCC converts whisper's occasionally-Simplified zh output to Taiwan
# Traditional (config key convertToTraditional, default on).
if ! command -v opencc >/dev/null 2>&1; then
  brew install opencc
fi

mkdir -p "$MODEL_DIR"

fetch_verified "$MODEL_URL" "$MODEL_PATH" "$MODEL_SHA256"
fetch_verified "$VAD_URL" "$VAD_PATH" "$VAD_SHA256"

echo "whisper-cli: $(command -v whisper-cli)"
echo "opencc: $(command -v opencc)"
echo "model: $MODEL_PATH"
echo "vad model: $VAD_PATH"
