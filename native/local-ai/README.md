# Local assignment parser

The native apps speak to an OpenAI-compatible `llama-server` on loopback. The
project includes the official llama.cpp b10142 CPU/Metal runtimes for macOS
ARM64, Windows x64, and Windows ARM64. The default model is the official Qwen3
1.7B GGUF. It is small enough for ordinary student laptops while still
supporting schema-constrained extraction.

## macOS

Double-click `start-macos.command` or:

```bash
cd /path/to/assignment-app
./native/local-ai/start-macos.command
```

To override the bundled binary:

```bash
LLAMA_SERVER_PATH=/absolute/path/to/llama-server \
  ./native/local-ai/start-macos.command
```

## Windows

Run:

```powershell
cd C:\path\to\assignment-app
.\native\local-ai\start-windows.ps1
```

## Model and port overrides

macOS:

```bash
ASSIGNMENT_AI_MODEL_REF="Qwen/Qwen3-1.7B-GGUF:Q8_0" \
ASSIGNMENT_AI_PORT=8080 \
./native/local-ai/start-macos.command
```

Windows:

```powershell
.\native\local-ai\start-windows.ps1 `
  -ModelReference "Qwen/Qwen3-1.7B-GGUF:Q8_0" `
  -Port 8080
```

The server is always bound to `127.0.0.1`; do not change it to `0.0.0.0`.
Passwords, cookies, and tokens are never included in model requests.

The first start downloads the selected model from Hugging Face into llama.cpp's
local cache. Runtime provenance and archive hashes are recorded in
`THIRD_PARTY_NOTICES.md`.
