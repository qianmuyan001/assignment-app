# Windows native app

This is the Windows-specific WinUI 3 implementation. It uses:

- WinUI 3 + Windows App SDK for native rendering, Mica, accessibility, DPI, and list virtualization.
- WebView2 with a dedicated `%LOCALAPPDATA%\AssignmentNative\WebView2` data folder for the signed-in browser session.
- Windows Credential Locker (`PasswordVault`) for optional exact-HTTPS-host credential storage.
- `Microsoft.Data.Sqlite` for direct access to the existing assignment schema.
- A loopback-only OpenAI-compatible `llama-server` endpoint for local extraction.

## Build on Windows

Install Visual Studio 2022 or newer with **Desktop development with C++**, **.NET desktop development**, and the Windows App SDK components. Then:

```powershell
cd native\windows
dotnet restore
dotnet build -c Release -p:Platform=x64
dotnet publish -c Release -r win-x64 -p:Platform=x64
```

Use `-r win-arm64 -p:Platform=ARM64` for Windows on ARM.

This source tree is intentionally independent from the macOS SwiftUI build. Both
versions use the same SQLite schema and the same strict AI JSON schema, but each
uses its platform-native UI, browser, and credential store.
