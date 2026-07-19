#Requires -Version 5.1
<#
.SYNOPSIS
  One-click build for the TypeDuck runtime, TypeDuck Windows IME binaries, and installer package.

  Legacy parameter names are preserved for callers that still pass the sibling
  backend checkout path.

.PARAMETER RepoRoot
  Root of this TypeDuck Windows IME scaffold checkout (defaults to the parent directory of this script).

.PARAMETER MoqiImeRoot
  Root of sibling backend repository (defaults to RepoRoot\..\moqi-ime).

.PARAMETER Configuration
  Build configuration for moqi-im-windows (default: Release).

.PARAMETER Generator
  CMake generator for moqi-im-windows (default: Visual Studio 17 2022).

.PARAMETER ProtobufRoot
  Optional local protobuf/protoc install root forwarded to scripts\build.ps1.

.PARAMETER ProtobufSourceDir
  Optional local protobuf source tree forwarded to scripts\build.ps1.

.PARAMETER RimeDataSource
  Optional TypeDuck schema checkout forwarded to the sibling backend build.

.PARAMETER Arm64RimeSourceRoot
  Recursive checkout of TypeDuck-HK/librime used to build native ARM64 rime.dll.
#>
param(
    [string] $RepoRoot = "",
    [string] $MoqiImeRoot = "",
    [string] $Configuration = "Release",
    [string] $Generator = "Visual Studio 17 2022",
    [string] $ProtobufRoot = "",
    [string] $ProtobufSourceDir = "",
    [string] $RimeDataSource = "",
    [string] $Arm64RimeSourceRoot = ""
)

$ErrorActionPreference = "Stop"

function Invoke-Step {
    param(
        [string] $FilePath,
        [string[]] $ArgumentList,
        [string] $WorkingDirectory
    )

    Write-Host ">> $FilePath $($ArgumentList -join ' ')"
    if ([string]::IsNullOrWhiteSpace($WorkingDirectory)) {
        & $FilePath @ArgumentList
    } else {
        Push-Location $WorkingDirectory
        try {
            & $FilePath @ArgumentList
        }
        finally {
            Pop-Location
        }
    }
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code ${LASTEXITCODE}: $FilePath"
    }
}

$scriptRepoRoot = Join-Path $PSScriptRoot ".."
if (-not $RepoRoot) { $RepoRoot = $scriptRepoRoot }
$RepoRoot = [System.IO.Path]::GetFullPath($RepoRoot)

if (-not $MoqiImeRoot) { $MoqiImeRoot = Join-Path $RepoRoot "..\moqi-ime" }
if (-not $Arm64RimeSourceRoot) { $Arm64RimeSourceRoot = Join-Path $RepoRoot "..\librime" }
$MoqiImeRoot = [System.IO.Path]::GetFullPath($MoqiImeRoot)
$Arm64RimeSourceRoot = [System.IO.Path]::GetFullPath($Arm64RimeSourceRoot)

$moqiImeBuildScript = Join-Path $MoqiImeRoot "scripts\build.ps1"
$arm64RuntimeBuildScript = Join-Path $RepoRoot "scripts\Build-TypeDuckArm64Runtime.ps1"
$windowsBuildScript = Join-Path $RepoRoot "scripts\build.ps1"
$windowsInstallScript = Join-Path $RepoRoot "scripts\install.ps1"
$moqiImeRuntimeDir = Join-Path $MoqiImeRoot "scripts\build\TypeDuckRuntime"
$arm64RuntimeDir = Join-Path $MoqiImeRoot "scripts\build\TypeDuckRuntime-arm64"

if (-not $ProtobufRoot) {
    $candidatePaths = @()
    $defaultRoot = "D:\a_dev\protoc-33.5-win64"
    if (Test-Path -LiteralPath $defaultRoot) {
        $candidatePaths += $defaultRoot
    }
    if (-not [string]::IsNullOrWhiteSpace($env:MOQI_PROTOBUF_ROOT)) {
        $candidatePaths += $env:MOQI_PROTOBUF_ROOT
    }

    foreach ($candidate in $candidatePaths) {
        if (Test-Path -LiteralPath (Join-Path $candidate "bin\protoc.exe")) {
            $ProtobufRoot = [System.IO.Path]::GetFullPath($candidate)
            break
        }
    }
}

if (-not $ProtobufSourceDir) {
    $candidatePaths = @()
    if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        $cacheRoot = Join-Path $env:USERPROFILE ".cache\moqi-protobuf"
        $candidatePaths += @(
            (Join-Path $cacheRoot "protobuf-33.5"),
            (Join-Path $cacheRoot "protobuf-34.1"),
            (Join-Path $cacheRoot "protobuf-29.5")
        )
    }

    foreach ($candidate in $candidatePaths) {
        if (Test-Path -LiteralPath (Join-Path $candidate "CMakeLists.txt")) {
            $ProtobufSourceDir = [System.IO.Path]::GetFullPath($candidate)
            break
        }
    }
}

if ($ProtobufSourceDir) {
    Write-Host "[INFO] Using local protobuf source: $ProtobufSourceDir"
}
if ($ProtobufRoot) {
    Write-Host "[INFO] Using local protobuf root: $ProtobufRoot"
}

foreach ($path in @(
    $moqiImeBuildScript,
    $arm64RuntimeBuildScript,
    $windowsBuildScript,
    $windowsInstallScript,
    (Join-Path $Arm64RimeSourceRoot "build.bat")
  )) {
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Required script not found: $path"
    }
}

Write-Host "== Step 1/4: Build x64 TypeDuck runtime package =="
$moqiImeBuildArgs = @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", $moqiImeBuildScript,
    "-RepoRoot", $MoqiImeRoot
)
if ($RimeDataSource) {
    $moqiImeBuildArgs += @("-RimeDataSource", $RimeDataSource)
}
Invoke-Step -FilePath "pwsh" -ArgumentList $moqiImeBuildArgs -WorkingDirectory $MoqiImeRoot

if (-not (Test-Path -LiteralPath (Join-Path $moqiImeRuntimeDir "server.exe"))) {
    throw "TypeDuckRuntime was not produced: $moqiImeRuntimeDir"
}

Write-Host "== Step 2/4: Build native ARM64 TypeDuck runtime package =="
Invoke-Step -FilePath "pwsh" -ArgumentList @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", $arm64RuntimeBuildScript,
    "-BackendRoot", $MoqiImeRoot,
    "-BaseRuntimeDir", $moqiImeRuntimeDir,
    "-RimeSourceRoot", $Arm64RimeSourceRoot,
    "-OutputDir", $arm64RuntimeDir
) -WorkingDirectory $RepoRoot

Write-Host "== Step 3/4: Build TypeDuck Windows IME binaries =="
$windowsBuildArgs = @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", $windowsBuildScript,
    "-RepoRoot", $RepoRoot,
    "-Configuration", $Configuration,
    "-Generator", $Generator
)
if ($ProtobufSourceDir) {
    $windowsBuildArgs += @("-ProtobufSourceDir", $ProtobufSourceDir)
}
if ($ProtobufRoot) {
    $windowsBuildArgs += @("-ProtobufRoot", $ProtobufRoot)
}
Invoke-Step -FilePath "pwsh" -ArgumentList $windowsBuildArgs -WorkingDirectory $RepoRoot

Write-Host "== Step 4/4: Build TypeDuck installer package =="
Invoke-Step -FilePath "pwsh" -ArgumentList @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-File", $windowsInstallScript,
    "-RepoRoot", $RepoRoot,
    "-MoqiImeSource", $moqiImeRuntimeDir,
    "-Arm64MoqiImeSource", $arm64RuntimeDir
) -WorkingDirectory $RepoRoot

$installerPath = Join-Path $RepoRoot "installer\dist\typeduck-windows-ime-setup.exe"
if (Test-Path -LiteralPath $installerPath) {
    Write-Host "OK: $installerPath"
} else {
    throw "Installer was not produced: $installerPath"
}

