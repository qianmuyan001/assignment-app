param(
    [string]$ModelReference = "Qwen/Qwen3-1.7B-GGUF:Q8_0",
    [int]$Port = 8080,
    [string]$ServerPath = $env:LLAMA_SERVER_PATH
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($ServerPath)) {
    $architecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
    $runtimeName = if ($architecture -eq
        [System.Runtime.InteropServices.Architecture]::Arm64) {
        "windows-arm64"
    } else {
        "windows-x64"
    }
    $bundledServer = Join-Path $PSScriptRoot `
        "runtime\$runtimeName\llama-server.exe"
    if (Test-Path -LiteralPath $bundledServer -PathType Leaf) {
        $ServerPath = $bundledServer
    } else {
        $command = Get-Command "llama-server.exe" -ErrorAction SilentlyContinue
        if ($null -ne $command) {
            $ServerPath = $command.Source
        }
    }
}

if ([string]::IsNullOrWhiteSpace($ServerPath) -or
    -not (Test-Path -LiteralPath $ServerPath -PathType Leaf)) {
    Write-Error @"
llama-server.exe was not found.

Restore the bundled runtime or download a Windows llama.cpp release from:
https://github.com/ggml-org/llama.cpp/releases

Then run:
.\native\local-ai\start-windows.ps1 -ServerPath "C:\absolute\path\llama-server.exe"
"@
}

Write-Host "Starting the private assignment parser on 127.0.0.1:$Port"
Write-Host "Model: $ModelReference"
Write-Host "The first start may download the model into llama.cpp's local cache."
Write-Host "Press Control-C to stop."

& $ServerPath `
    --host 127.0.0.1 `
    --port $Port `
    --ctx-size 8192 `
    --jinja `
    -hf $ModelReference
