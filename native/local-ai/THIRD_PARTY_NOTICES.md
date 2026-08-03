# Third-party runtime notices

## llama.cpp

- Project: https://github.com/ggml-org/llama.cpp
- Release: `b10142`
- License: MIT; a copy is included at `runtime/LICENSE.llama.cpp`.
- macOS ARM64 archive SHA-256:
  `496696a75da480b80c4cc26c112e00f55e99567c386bd6cf51a8d914ae68373f`
- Windows ARM64 archive SHA-256:
  `98f8abea82ade00aa16adb3cd1442b2feb6a969051497682efb2208356c975b4`
- Windows x64 archive SHA-256:
  `6fa98eff21e990ab40672f162e419ee744143d727d9b05bfb3f2b2c01c8557f8`

The runtime is invoked as a child process bound to `127.0.0.1`. Its executable
and required dynamic libraries are stored under `runtime/<platform>/`.

## Default model

- Model: Qwen3 1.7B GGUF
- Repository: https://huggingface.co/Qwen/Qwen3-1.7B-GGUF
- The weights are not redistributed in this project. `llama-server` downloads
  the selected quantization into its local cache on first use.
