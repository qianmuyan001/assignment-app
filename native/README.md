# Native Assignment App

This directory contains the platform-native replacements for the original
CustomTkinter interface.

## 2.0 implementation status

- `windows/` contains the WinUI 3 2.0 preview task workflow and its separate,
  cross-platform-testable Core project.
- `apple/` contains the approved SwiftUI iPadOS 2.0 alternative. The same real
  Xcode application target builds for iPadOS and Apple Silicon Mac Catalyst.
- `../legacy/macos/` contains the retired pure macOS SwiftPM 1.0 baseline for
  historical reference; it is not an active 2.0 deliverable.
- `../shared/` is the canonical 2.0 task/schema/rule/fixture directory. The
  older `native/shared/assignment-candidates.schema.json` remains the secure
  source-import contract.

## Architecture

```text
┌──────────────────────────┐      ┌──────────────────────────┐
│ Apple 2.0                │      │ Windows 2.0              │
│ SwiftUI iPad + Catalyst  │      │ WinUI 3                  │
│ SQLite repository        │      │ SQLite service           │
└────────────┬─────────────┘      └────────────┬─────────────┘
             │                                 │
             ├──────── assignment schema ──────┤
```

The archived macOS 1.0 and active Windows source-connector foundations can use the
loopback `llama.cpp` endpoint described below. Local AI and source login are not
part of the Apple 2.0 task-management preview.

The Apple and Windows 2.0 clients and FastAPI backend can safely migrate the
existing SQLite database. They create a recoverable SQLite online backup before
schema changes, validate the result, and stop writes if migration fails. The
archived macOS 1.0 client does not initiate v2 migration or expose priority,
but the additive priority column and retained physical status values let it
continue reading and writing a database already upgraded by a 2.0 client. None
of the native clients send task data to a cloud service.

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

- `apple/`: SwiftUI iPadOS and Mac Catalyst 2.0 Xcode project.
- `../legacy/macos/`: retired SwiftUI macOS 1.0 client.
- `windows/`: WinUI 3 Windows client source.
- `local-ai/`: loopback-only llama.cpp start scripts.
- `shared/`: shared JSON contracts and test fixtures.

The 2.0 shared contracts live at repository-level `shared/`; see
`shared/README.md`.
