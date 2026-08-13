param(
    [switch]$SkipSmokeTest,
    [switch]$RequireCleanTree,
    [string]$ArtifactRoot
)

$ErrorActionPreference = "Stop"
if (Test-Path variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$WindowsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepositoryRoot = (Resolve-Path (Join-Path $WindowsRoot "..\..")).Path
$ProjectPath = Join-Path $WindowsRoot "AssignmentNative.Windows.csproj"
$CoreTestsPath = Join-Path $WindowsRoot "AssignmentNative.Core.Tests\AssignmentNative.Core.Tests.csproj"
$Version = (Get-Content (Join-Path $RepositoryRoot "VERSION") -Raw).Trim()
$RunStamp = if ($env:ASSIGNMENT_RUN_STAMP) {
    $env:ASSIGNMENT_RUN_STAMP
}
else {
    [DateTime]::UtcNow.ToString("yyyyMMdd-HHmmss'Z'")
}
if ($RunStamp -notmatch '^[A-Za-z0-9._-]+$') {
    throw "ASSIGNMENT_RUN_STAMP contains unsupported path characters: $RunStamp"
}

if (-not $ArtifactRoot) {
    $ArtifactRoot = Join-Path $RepositoryRoot "artifacts\windows"
}
$ArtifactRoot = [System.IO.Path]::GetFullPath($ArtifactRoot)
$OutputPath = [System.IO.Path]::GetFullPath(
    (Join-Path $ArtifactRoot "x64-$RunStamp")
)
$ArtifactRootPrefix = $ArtifactRoot.TrimEnd(
    [System.IO.Path]::DirectorySeparatorChar,
    [System.IO.Path]::AltDirectorySeparatorChar
) + [System.IO.Path]::DirectorySeparatorChar
if (-not $OutputPath.StartsWith(
    $ArtifactRootPrefix,
    [StringComparison]::OrdinalIgnoreCase
)) {
    throw "Artifact output escaped its configured root: $OutputPath"
}
$PublishPath = Join-Path $OutputPath "publish"
$LogsPath = Join-Path $OutputPath "logs"
$ExecutablePath = Join-Path $PublishPath "AssignmentNative.exe"

$SourceRevision = (& git -C $RepositoryRoot rev-parse --verify HEAD).Trim()
if ($LASTEXITCODE -ne 0) {
    throw "Unable to resolve the source Git revision."
}
$SourceStatus = @(& git -C $RepositoryRoot status --porcelain --untracked-files=all)
if ($LASTEXITCODE -ne 0) {
    throw "Unable to inspect the source Git status."
}
$SourceTreeDirty = $SourceStatus.Count -gt 0
if ($RequireCleanTree -and $SourceTreeDirty) {
    throw "Refusing a release-baseline package from a dirty source tree."
}

if (Test-Path -LiteralPath $OutputPath) {
    throw "Refusing to overwrite existing artifact directory: $OutputPath"
}
New-Item -ItemType Directory -Path $PublishPath -Force | Out-Null
New-Item -ItemType Directory -Path $LogsPath -Force | Out-Null

& dotnet restore $ProjectPath -r win-x64 -p:Platform=x64 2>&1 |
    Tee-Object -FilePath (Join-Path $LogsPath "restore.log")
if ($LASTEXITCODE -ne 0) {
    throw "dotnet restore failed with exit code $LASTEXITCODE"
}

& dotnet run --project $CoreTestsPath -c Release 2>&1 |
    Tee-Object -FilePath (Join-Path $LogsPath "core-tests.log")
if ($LASTEXITCODE -ne 0) {
    throw "Core test harness failed with exit code $LASTEXITCODE"
}

& dotnet publish $ProjectPath `
    -c Release `
    -r win-x64 `
    -p:Platform=x64 `
    --self-contained true `
    -p:WindowsAppSDKSelfContained=true `
    --no-restore `
    -o $PublishPath 2>&1 |
    Tee-Object -FilePath (Join-Path $LogsPath "publish.log")
if ($LASTEXITCODE -ne 0) {
    throw "dotnet publish failed with exit code $LASTEXITCODE"
}

if (-not (Test-Path -LiteralPath $ExecutablePath)) {
    throw "Publish completed without producing $ExecutablePath"
}
$ExecutableVersionInfo = (Get-Item -LiteralPath $ExecutablePath).VersionInfo
$ExpectedBinaryVersion = "$Version.0"
if ($ExecutableVersionInfo.FileVersion -ne $ExpectedBinaryVersion) {
    throw "Published executable FileVersion $($ExecutableVersionInfo.FileVersion) does not match $ExpectedBinaryVersion"
}
if (-not $ExecutableVersionInfo.ProductVersion.StartsWith(
    $Version,
    [StringComparison]::Ordinal
)) {
    throw "Published executable ProductVersion $($ExecutableVersionInfo.ProductVersion) does not start with $Version"
}

$SmokeResult = "skipped"
if (-not $SkipSmokeTest) {
    $SystemTemp = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    $SmokeRoot = Join-Path `
        $SystemTemp `
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
        $SmokeLogPath = Join-Path $LogsPath "launch-smoke.log"
        $SmokeStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $SmokeDeadline = [DateTime]::UtcNow.AddSeconds(30)
        $SmokeVerified = $false
        $Attempt = 0
        while ([DateTime]::UtcNow -lt $SmokeDeadline) {
            $SmokeProcess.Refresh()
            if ($SmokeProcess.HasExited) {
                throw "AssignmentNative.exe exited during the isolated launch smoke test. Exit code: $($SmokeProcess.ExitCode)"
            }

            if (Test-Path -LiteralPath $SmokeDatabasePath) {
                $Attempt += 1
                $VerificationOutput = @(
                    & dotnet run --project $CoreTestsPath -c Release --no-build -- `
                        --verify-database $SmokeDatabasePath 2>&1
                )
                $VerificationExitCode = $LASTEXITCODE
                Add-Content -LiteralPath $SmokeLogPath -Value `
                    "verification_attempt=$Attempt elapsed_ms=$($SmokeStopwatch.ElapsedMilliseconds) exit_code=$VerificationExitCode"
                $VerificationOutput | Out-File `
                    -LiteralPath $SmokeLogPath `
                    -Append `
                    -Encoding utf8
                if ($VerificationExitCode -eq 0) {
                    $SmokeVerified = $true
                    break
                }
            }
            Start-Sleep -Milliseconds 250
        }
        $SmokeStopwatch.Stop()
        if (-not $SmokeVerified) {
            throw "Launch database verification did not pass within 30 seconds. See $SmokeLogPath"
        }
        $SmokeProcess.Refresh()
        if ($SmokeProcess.HasExited) {
            throw "AssignmentNative.exe exited after database verification. Exit code: $($SmokeProcess.ExitCode)"
        }
        $SmokeResult = "passed (process alive; isolated database verified; readiness_ms=$($SmokeStopwatch.ElapsedMilliseconds))"
    }
    finally {
        try {
            if ($null -ne $SmokeProcess) {
                $SmokeProcess.Refresh()
                if (-not $SmokeProcess.HasExited) {
                    Stop-Process -Id $SmokeProcess.Id -ErrorAction SilentlyContinue
                    try {
                        $null = $SmokeProcess.WaitForExit(5000)
                    }
                    catch {
                        Write-Warning "Unable to wait for smoke process exit: $_"
                    }
                }
            }
        }
        finally {
            try {
                if ($null -eq $PreviousDatabasePath) {
                    Remove-Item Env:ASSIGNMENT_DB_PATH -ErrorAction SilentlyContinue
                }
                else {
                    $env:ASSIGNMENT_DB_PATH = $PreviousDatabasePath
                }
            }
            finally {
                $ResolvedSmokeRoot = [System.IO.Path]::GetFullPath($SmokeRoot)
                $SystemTempPrefix = $SystemTemp.TrimEnd(
                    [System.IO.Path]::DirectorySeparatorChar,
                    [System.IO.Path]::AltDirectorySeparatorChar
                ) + [System.IO.Path]::DirectorySeparatorChar
                if (-not $ResolvedSmokeRoot.StartsWith(
                    $SystemTempPrefix,
                    [StringComparison]::OrdinalIgnoreCase
                ) -or -not (Split-Path -Leaf $ResolvedSmokeRoot).StartsWith(
                    "AssignmentNative-smoke-",
                    [StringComparison]::Ordinal
                )) {
                    throw "Refusing to clean unexpected smoke directory: $ResolvedSmokeRoot"
                }
                if (Test-Path -LiteralPath $ResolvedSmokeRoot) {
                    Remove-Item -LiteralPath $ResolvedSmokeRoot -Recurse -Force
                }
            }
        }
    }
}

$Signature = Get-AuthenticodeSignature -FilePath $ExecutablePath
$ExecutableHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $ExecutablePath).Hash.ToLowerInvariant()
$DotnetInfo = (& dotnet --info | Out-String).TrimEnd()
$SourceStatusText = if ($SourceTreeDirty) {
    $SourceStatus -join [Environment]::NewLine
}
else {
    "clean"
}

@"
Assignment App $Version Windows x64 test package
created_utc=$RunStamp
source_revision=$SourceRevision
source_tree_dirty=$($SourceTreeDirty.ToString().ToLowerInvariant())
source_status=$SourceStatusText
architecture=x64
configuration=Release
target_framework=net8.0-windows10.0.19041.0
runtime_identifier=win-x64
self_contained=true
core_tests=passed
launch_smoke=$SmokeResult
authenticode_status=$($Signature.Status)
executable_sha256=$ExecutableHash
file_version=$($ExecutableVersionInfo.FileVersion)
product_version=$($ExecutableVersionInfo.ProductVersion)
runner_os=$([System.Environment]::OSVersion.VersionString)
github_run_id=$env:GITHUB_RUN_ID

$DotnetInfo
"@ | Set-Content -LiteralPath (Join-Path $OutputPath "build-info.txt") -Encoding UTF8

Write-Host "Windows x64 artifact directory: $OutputPath"
