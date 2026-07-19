#Requires -Version 5.1
<#
.SYNOPSIS
  Build a native ARM64 TypeDuck runtime, including server.exe and rime.dll.

.PARAMETER BackendRoot
  Root of the TypeDuck-Windows-backend checkout.

.PARAMETER BaseRuntimeDir
  Existing x64 TypeDuckRuntime package used as the architecture-neutral data source.

.PARAMETER RimeSourceRoot
  Recursive checkout of TypeDuck-HK/librime.

.PARAMETER OutputDir
  Destination for the native ARM64 TypeDuckRuntime package.
#>
param(
  [Parameter(Mandatory = $true)]
  [string] $BackendRoot,
  [Parameter(Mandatory = $true)]
  [string] $BaseRuntimeDir,
  [Parameter(Mandatory = $true)]
  [string] $RimeSourceRoot,
  [Parameter(Mandatory = $true)]
  [string] $OutputDir
)

$ErrorActionPreference = "Stop"

function Invoke-NativeCommand {
  param(
    [string] $FilePath,
    [string[]] $ArgumentList,
    [string] $WorkingDirectory = ""
  )

  Write-Host ">> $FilePath $($ArgumentList -join ' ')"
  if ($WorkingDirectory) {
    Push-Location $WorkingDirectory
  }
  try {
    & $FilePath @ArgumentList
    if ($LASTEXITCODE -ne 0) {
      throw "Command failed with exit code $LASTEXITCODE`: $FilePath"
    }
  }
  finally {
    if ($WorkingDirectory) {
      Pop-Location
    }
  }
}

function Get-PeMachine {
  param([string] $Path)

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "PE file not found: $Path"
  }

  $stream = [System.IO.File]::OpenRead($Path)
  $reader = [System.IO.BinaryReader]::new($stream)
  try {
    if ($reader.ReadUInt16() -ne 0x5A4D) {
      throw "Not a PE file: $Path"
    }
    $stream.Position = 0x3C
    $peOffset = $reader.ReadInt32()
    $stream.Position = $peOffset
    if ($reader.ReadUInt32() -ne 0x00004550) {
      throw "Invalid PE signature: $Path"
    }
    return $reader.ReadUInt16()
  }
  finally {
    $reader.Dispose()
    $stream.Dispose()
  }
}

function Assert-Arm64Pe {
  param(
    [string] $Path,
    [string] $Label
  )

  $machine = Get-PeMachine -Path $Path
  if ($machine -ne 0xAA64) {
    throw "$Label is not native ARM64 (PE machine 0x$($machine.ToString('X4'))): $Path"
  }
  Write-Host "[ARM64] $Label`: $Path"
}

$BackendRoot = [System.IO.Path]::GetFullPath($BackendRoot)
$BaseRuntimeDir = [System.IO.Path]::GetFullPath($BaseRuntimeDir)
$RimeSourceRoot = [System.IO.Path]::GetFullPath($RimeSourceRoot)
$OutputDir = [System.IO.Path]::GetFullPath($OutputDir)

foreach ($required in @(
    (Join-Path $BackendRoot "go.mod"),
    (Join-Path $BaseRuntimeDir "server.exe"),
    (Join-Path $RimeSourceRoot "build.bat")
  )) {
  if (-not (Test-Path -LiteralPath $required)) {
    throw "Required native ARM64 build input not found: $required"
  }
}

$boostRoot = Join-Path $RimeSourceRoot "deps\boost-1.84.0"
$envBat = Join-Path $RimeSourceRoot "env.bat"
$hadEnvBat = Test-Path -LiteralPath $envBat -PathType Leaf
$previousEnvBat = if ($hadEnvBat) { [System.IO.File]::ReadAllBytes($envBat) } else { $null }
$disabledResources = [System.Collections.Generic.List[object]]::new()

try {
  if (-not (Test-Path -LiteralPath (Join-Path $boostRoot "boost"))) {
    $boostArchive = Join-Path $RimeSourceRoot "deps\boost-1.84.0.zip"
    if (-not (Test-Path -LiteralPath $boostArchive -PathType Leaf)) {
      Invoke-WebRequest `
        -Uri "https://github.com/boostorg/boost/releases/download/boost-1.84.0/boost-1.84.0.zip" `
        -OutFile $boostArchive
    }
    Expand-Archive -LiteralPath $boostArchive `
      -DestinationPath (Split-Path -Parent $boostRoot) -Force
  }

  $b2 = Join-Path $boostRoot "b2.exe"
  if (-not (Test-Path -LiteralPath $b2 -PathType Leaf)) {
    Invoke-NativeCommand -FilePath (Join-Path $boostRoot "bootstrap.bat") `
      -ArgumentList @() -WorkingDirectory $boostRoot
  }

  Invoke-NativeCommand -FilePath $b2 -ArgumentList @(
    "-j2",
    "--with-regex",
    "toolset=msvc-14.3",
    "architecture=arm",
    "address-model=64",
    "variant=release",
    "link=static",
    "runtime-link=static",
    "threading=multi",
    "define=BOOST_USE_WINAPI_VERSION=0x0A00",
    "stage"
  ) -WorkingDirectory $boostRoot

  $envLines = @(
    "set `"RIME_ROOT=$RimeSourceRoot`"",
    "set `"BOOST_ROOT=$boostRoot`"",
    "set ARCH=ARM64",
    "set BJAM_TOOLSET=msvc-14.3",
    "set CMAKE_GENERATOR=`"Visual Studio 17 2022`"",
    "set PLATFORM_TOOLSET=v143"
  )
  [System.IO.File]::WriteAllLines(
    $envBat,
    $envLines,
    [System.Text.UTF8Encoding]::new($false)
  )

  Invoke-NativeCommand -FilePath "cmd.exe" -ArgumentList @(
    "/d", "/c", "call build.bat deps nologging release"
  ) -WorkingDirectory $RimeSourceRoot
  Invoke-NativeCommand -FilePath "cmd.exe" -ArgumentList @(
    "/d", "/c", "call build.bat librime nologging release"
  ) -WorkingDirectory $RimeSourceRoot

  $arm64RimeDll = Join-Path $RimeSourceRoot "dist\lib\rime.dll"
  Assert-Arm64Pe -Path $arm64RimeDll -Label "TypeDuck rime.dll"

  if (Test-Path -LiteralPath $OutputDir) {
    Remove-Item -LiteralPath $OutputDir -Recurse -Force
  }
  New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
  Copy-Item -Path (Join-Path $BaseRuntimeDir "*") -Destination $OutputDir -Recurse -Force

  foreach ($resource in (Get-ChildItem -Path $BackendRoot -Filter "resource_windows_*.syso" -File)) {
    $disabledPath = $resource.FullName + ".disabled-for-arm64"
    Move-Item -LiteralPath $resource.FullName -Destination $disabledPath
    $disabledResources.Add([pscustomobject]@{
      Original = $resource.FullName
      Disabled = $disabledPath
    })
  }

  $oldGoos = $env:GOOS
  $oldGoarch = $env:GOARCH
  $oldCgoEnabled = $env:CGO_ENABLED
  try {
    $env:GOOS = "windows"
    $env:GOARCH = "arm64"
    $env:CGO_ENABLED = "0"
    Invoke-NativeCommand -FilePath "go" -ArgumentList @(
      "build",
      "-trimpath",
      "-ldflags", "-s -w",
      "-o", (Join-Path $OutputDir "server.exe"),
      "."
    ) -WorkingDirectory $BackendRoot
  }
  finally {
    $env:GOOS = $oldGoos
    $env:GOARCH = $oldGoarch
    $env:CGO_ENABLED = $oldCgoEnabled
  }

  $packageRimeDir = Join-Path $OutputDir "input_methods\rime"
  New-Item -ItemType Directory -Path $packageRimeDir -Force | Out-Null
  Copy-Item -LiteralPath $arm64RimeDll `
    -Destination (Join-Path $packageRimeDir "rime.dll") -Force

  Assert-Arm64Pe -Path (Join-Path $OutputDir "server.exe") `
    -Label "TypeDuckRuntime server.exe"
  Assert-Arm64Pe -Path (Join-Path $packageRimeDir "rime.dll") `
    -Label "Packaged TypeDuck rime.dll"
}
finally {
  foreach ($resource in $disabledResources) {
    if (Test-Path -LiteralPath $resource.Disabled) {
      Move-Item -LiteralPath $resource.Disabled -Destination $resource.Original
    }
  }
  if ($hadEnvBat) {
    [System.IO.File]::WriteAllBytes($envBat, $previousEnvBat)
  }
  elseif (Test-Path -LiteralPath $envBat) {
    Remove-Item -LiteralPath $envBat -Force
  }
}

Write-Host "Native ARM64 TypeDuck runtime: $OutputDir"
