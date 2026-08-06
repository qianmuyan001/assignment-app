param(
    [switch]$SkipSmokeTest
)

$ErrorActionPreference = "Stop"

$WindowsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepositoryRoot = (Resolve-Path (Join-Path $WindowsRoot "..\..")).Path
$ProjectPath = Join-Path $WindowsRoot "AssignmentNative.Windows.csproj"
$CoreTestsPath = Join-Path $WindowsRoot "AssignmentNative.Core.Tests\AssignmentNative.Core.Tests.csproj"
$OutputPath = Join-Path $RepositoryRoot "artifacts\windows-x64"
$ExecutablePath = Join-Path $OutputPath "AssignmentNative.exe"

dotnet restore $ProjectPath -r win-x64 -p:Platform=x64
if ($LASTEXITCODE -ne 0) {
    throw "dotnet restore failed with exit code $LASTEXITCODE"
}

dotnet run --project $CoreTestsPath -c Release
if ($LASTEXITCODE -ne 0) {
    throw "Core test harness failed with exit code $LASTEXITCODE"
}

dotnet publish $ProjectPath `
    -c Release `
    -r win-x64 `
    -p:Platform=x64 `
    --self-contained true `
    -p:WindowsAppSDKSelfContained=true `
    --no-restore `
    -o $OutputPath
if ($LASTEXITCODE -ne 0) {
    throw "dotnet publish failed with exit code $LASTEXITCODE"
}

if (-not (Test-Path $ExecutablePath)) {
    throw "Publish completed without producing $ExecutablePath"
}

if (-not $SkipSmokeTest) {
    $SmokeRoot = Join-Path `
        ([System.IO.Path]::GetTempPath()) `
        ("AssignmentNative-smoke-" + [Guid]::NewGuid().ToString("N"))
    $SmokeDatabasePath = Join-Path $SmokeRoot "assignments.db"
    $PreviousDatabasePath = [Environment]::GetEnvironmentVariable(
        "ASSIGNMENT_DB_PATH",
        "Process"
    )
    $SmokeProcess = $null

    try {
        New-Item -ItemType Directory -Path $SmokeRoot | Out-Null
        $env:ASSIGNMENT_DB_PATH = $SmokeDatabasePath
        $SmokeProcess = Start-Process -FilePath $ExecutablePath -PassThru
        Start-Sleep -Seconds 5
        if ($SmokeProcess.HasExited) {
            throw "AssignmentNative.exe exited during the isolated launch smoke test. Exit code: $($SmokeProcess.ExitCode)"
        }
    }
    finally {
        if ($null -ne $SmokeProcess -and -not $SmokeProcess.HasExited) {
            Stop-Process -Id $SmokeProcess.Id
            $null = $SmokeProcess.WaitForExit(5000)
        }
        if ($null -eq $PreviousDatabasePath) {
            Remove-Item Env:ASSIGNMENT_DB_PATH -ErrorAction SilentlyContinue
        }
        else {
            $env:ASSIGNMENT_DB_PATH = $PreviousDatabasePath
        }
        if (Test-Path $SmokeRoot) {
            Remove-Item -Recurse -Force $SmokeRoot
        }
    }
}

Write-Host "Windows x64 publish directory: $OutputPath"
