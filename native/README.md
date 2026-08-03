# Native Assignment App

This directory contains the platform-native replacements for the original
CustomTkinter interface.

## Architecture

```text
┌──────────────────────────┐      ┌──────────────────────────┐
│ macOS                    │      │ Windows                  │
│ SwiftUI + WKWebView      │      │ WinUI 3 + WebView2      │
│ Keychain Services        │      │ Credential Locker       │
└────────────┬─────────────┘      └────────────┬─────────────┘
             │                                 │
             ├──────── assignment schema ──────┤
             │                                 │
             └──── local llama.cpp endpoint ───┘
                         127.0.0.1 only
```

Both clients use the existing assignment fields and can migrate the existing
SQLite database. They do not send credentials or course content to a cloud
service.

## Authentication modes

1. **Interactive login (recommended):** The user signs in inside a dedicated
   browser surface. The app never reads the password. SSO and MFA remain under
   the identity provider's control.
2. **Keychain / Credential Locker fill:** The user explicitly saves a
   credential for one exact HTTPS origin. The native client can fill the
   matching username and password fields, but never submits the form
   automatically.
3. **OAuth connector:** Platforms that expose a supported API should use the
   system browser, authorization code flow, and PKCE instead of collecting a
   password.

The local model is deliberately excluded from all three authentication paths.

## Local AI

The first provider is a local `llama.cpp` server bound to
`http://127.0.0.1:8080`. The request uses a JSON schema so the response can only
contain assignment candidates. A small GGUF model such as Qwen3 1.7B is
appropriate for the default parser; larger local models can be selected later.

Start the runtime before opening the source scanner:

```bash
./native/local-ai/start-macos.command
```

On Windows, use `native\local-ai\start-windows.ps1`. Both scripts bind the
server to `127.0.0.1` and default to the official Qwen3 1.7B GGUF.

The AI receives:

- cleaned visible page text;
- the current URL and page title;
- a source/course hint supplied by the user.

The AI never receives:

- passwords, password fields, cookies, tokens, or authorization headers;
- hidden form values;
- local files unrelated to the selected source.

## Project layout

- `macos/`: buildable SwiftUI macOS client.
- `windows/`: WinUI 3 Windows client source.
- `local-ai/`: loopback-only llama.cpp start scripts.
- `shared/`: shared JSON contracts and test fixtures.
