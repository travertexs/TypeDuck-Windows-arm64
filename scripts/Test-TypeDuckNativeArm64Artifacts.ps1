#Requires -Version 5.1
<#
.SYNOPSIS
  Verifies that installer staging contains real architecture-matched PE binaries.
#>
param(
  [string] $RepoRoot = ".",
  [string] $StageDir = "installer\stage"
)

$ErrorActionPreference = "Stop"

function Get-PeMachine {
  param([string] $Path)

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "Required staged binary not found: $Path"
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

$root = [System.IO.Path]::GetFullPath($RepoRoot)
if (-not [System.IO.Path]::IsPathRooted($StageDir)) {
  $StageDir = Join-Path $root $StageDir
}
$StageDir = [System.IO.Path]::GetFullPath($StageDir)

$i386 = 0x014C
$amd64 = 0x8664
$arm64 = 0xAA64
$expectations = @(
  @{ Path = "win32\TypeDuckIME\TypeDuckLauncher.exe"; Machine = $i386 },
  @{ Path = "win32\TypeDuckIME\TypeDuckSetupHelper.exe"; Machine = $i386 },
  @{ Path = "win32\TypeDuckIME\TypeDuckSettings.exe"; Machine = $i386 },
  @{ Path = "win32\TypeDuckIME\TypeDuckAbout.exe"; Machine = $i386 },
  @{ Path = "win32\TypeDuckIME\TypeDuckTextService.dll"; Machine = $i386 },
  @{ Path = "win32\TypeDuckIME\x64\TypeDuckTextService.dll"; Machine = $amd64 },
  @{ Path = "win32\TypeDuckIME\TypeDuckRuntime\server.exe"; Machine = $amd64 },
  @{ Path = "win32\TypeDuckIME\TypeDuckRuntime\input_methods\rime\rime.dll"; Machine = $amd64 },
  @{ Path = "x64\TypeDuckIME\TypeDuckTextService.dll"; Machine = $amd64 },
  @{ Path = "arm64\TypeDuckIME\TypeDuckLauncher.exe"; Machine = $arm64 },
  @{ Path = "arm64\TypeDuckIME\TypeDuckSetupHelper.exe"; Machine = $arm64 },
  @{ Path = "arm64\TypeDuckIME\TypeDuckSettings.exe"; Machine = $arm64 },
  @{ Path = "arm64\TypeDuckIME\TypeDuckAbout.exe"; Machine = $arm64 },
  @{ Path = "arm64\TypeDuckIME\TypeDuckTextService.dll"; Machine = $i386 },
  @{ Path = "arm64\TypeDuckIME\x64\TypeDuckTextService.dll"; Machine = $amd64 },
  @{ Path = "arm64\TypeDuckIME\arm64\TypeDuckTextService.dll"; Machine = $arm64 },
  @{ Path = "arm64\TypeDuckIME\TypeDuckRuntime\server.exe"; Machine = $arm64 },
  @{ Path = "arm64\TypeDuckIME\TypeDuckRuntime\input_methods\rime\rime.dll"; Machine = $arm64 }
)

foreach ($expectation in $expectations) {
  $path = Join-Path $StageDir $expectation.Path
  $actual = Get-PeMachine -Path $path
  if ($actual -ne $expectation.Machine) {
    throw "Wrong PE machine for $($expectation.Path): expected 0x$($expectation.Machine.ToString('X4')), got 0x$($actual.ToString('X4'))."
  }
  Write-Host ("[OK] 0x{0:X4} {1}" -f $actual, $expectation.Path)
}

# Do not let an unlisted executable or runtime dependency silently fall back to
# emulation. The two TSF DLLs below must match the architecture of the process
# that loads them; every other PE in the Windows on Arm application payload is
# required to be native ARM64.
$arm64PayloadRoot = Join-Path $StageDir "arm64\TypeDuckIME"
$hostArchitectureDlls = @{
  "TypeDuckTextService.dll" = $i386
  "x64\TypeDuckTextService.dll" = $amd64
}

$arm64PayloadPeFiles = Get-ChildItem -LiteralPath $arm64PayloadRoot -Recurse -File |
  Where-Object { $_.Extension -in @(".exe", ".dll") }

foreach ($file in $arm64PayloadPeFiles) {
  $relativePath = $file.FullName.Substring($arm64PayloadRoot.Length).TrimStart("\", "/")
  $expectedMachine = if ($hostArchitectureDlls.ContainsKey($relativePath)) {
    $hostArchitectureDlls[$relativePath]
  }
  else {
    $arm64
  }

  $actualMachine = Get-PeMachine -Path $file.FullName
  if ($actualMachine -ne $expectedMachine) {
    throw "Non-native or unexpected PE in ARM64 payload: $relativePath expected 0x$($expectedMachine.ToString('X4')), got 0x$($actualMachine.ToString('X4'))."
  }
}

Write-Host "All TypeDuck installer binaries match their declared architectures."
