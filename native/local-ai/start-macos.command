#!/usr/bin/env bash

set -euo pipefail

MODEL_REFERENCE="${ASSIGNMENT_AI_MODEL_REF:-Qwen/Qwen3-1.7B-GGUF:Q8_0}"
AI_PORT="${ASSIGNMENT_AI_PORT:-8080}"
SERVER_OVERRIDE="${LLAMA_SERVER_PATH:-}"
SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLED_SERVER="$SCRIPT_DIRECTORY/runtime/macos-arm64/llama-server"

if [[ -n "$SERVER_OVERRIDE" ]]; then
    SERVER_BINARY="$SERVER_OVERRIDE"
elif [[ -x "$BUNDLED_SERVER" ]]; then
    SERVER_BINARY="$BUNDLED_SERVER"
else
    SERVER_BINARY="$(command -v llama-server || true)"
fi

if [[ -z "$SERVER_BINARY" || ! -x "$SERVER_BINARY" ]]; then
    echo "llama-server was not found."
    echo
    echo "Restore the bundled runtime or install llama.cpp:"
    echo "  https://github.com/ggml-org/llama.cpp"
    echo
    echo "Or point directly to the binary:"
    echo "  LLAMA_SERVER_PATH=/absolute/path/to/llama-server \\"
    echo "    ./native/local-ai/start-macos.command"
    exit 1
fi

echo "Starting the private assignment parser on 127.0.0.1:${AI_PORT}"
echo "Model: ${MODEL_REFERENCE}"
echo "The first start may download the model into llama.cpp's local cache."
echo "Press Control-C to stop."

exec "$SERVER_BINARY" \
    --host 127.0.0.1 \
    --port "$AI_PORT" \
    --ctx-size 8192 \
    --jinja \
    -hf "$MODEL_REFERENCE"
