#!/usr/bin/env bash
set -euo pipefail

# large-v3-turbo q5_0: near-large accuracy, fast on Apple Silicon, ~547MB.
# Much better than base for code-switched (中英混講) and imperfect-audio speech.
MODEL_DIR="$HOME/.saykey/models"
MODEL_PATH="$MODEL_DIR/ggml-large-v3-turbo-q5_0.bin"
MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin"

# Silero VAD (~1MB): strips silence/noise before the encoder so quiet or empty
# clips stop producing hallucinated captions (config key enableVAD, default on).
VAD_PATH="$MODEL_DIR/ggml-silero-v6.2.0.bin"
VAD_URL="https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v6.2.0.bin"

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

if [[ ! -f "$MODEL_PATH" ]]; then
  curl -L --fail --progress-bar -o "$MODEL_PATH" "$MODEL_URL"
fi

if [[ ! -f "$VAD_PATH" ]]; then
  curl -L --fail --progress-bar -o "$VAD_PATH" "$VAD_URL"
fi

echo "whisper-cli: $(command -v whisper-cli)"
echo "opencc: $(command -v opencc)"
echo "model: $MODEL_PATH"
echo "vad model: $VAD_PATH"
