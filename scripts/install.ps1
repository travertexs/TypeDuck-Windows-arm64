#Requires -Version 5.1
<#
.SYNOPSIS
  Stage TypeDuck Windows IME binaries and invoke the installer builder.

  Does not install files into Program Files directly. Instead it prepares an
  installer stage tree and calls installer\build-installer.ps1 to produce the
  setup executable.

.PARAMETER RepoRoot
  Root of the TypeDuck Windows IME scaffold checkout (defaults to the parent directory of this script).

.PARAMETER Win32BuildDir
  CMake Win32 build directory (default: RepoRoot\build-vs32).

.PARAMETER X64BuildDir
  CMake x64 build directory (default: RepoRoot\build-vs64).

.PARAMETER Arm64BuildDir
  CMake ARM64 build directory (default: RepoRoot\build-vsarm64).

.PARAMETER MoqiImeSource
  Legacy parameter compatibility: path to the TypeDuckRuntime tree to copy as backend.
  Default detection order:
    1. sibling ..\moqi-ime\scripts\build\TypeDuckRuntime
    2. sibling ..\moqi-ime

.PARAMETER Arm64MoqiImeSource
  Path to the native ARM64 TypeDuckRuntime tree. Defaults to the sibling backend
  scripts\build\TypeDuckRuntime-arm64 output.

.PARAMETER SkipMoqiImeCopy
  If set, do not include either TypeDuck runtime tree in the staged installer payload.

.PARAMETER StageDir
  Installer staging directory (default: RepoRoot\installer\stage).

.PARAMETER IssPath
  Optional path to the Inno Setup script (default: RepoRoot\installer\MoqiTsf.iss).
#>
param(
    [string] $RepoRoot = "",
    [string] $Win32BuildDir = "",
    [string] $X64BuildDir = "",
    [string] $Arm64BuildDir = "",
    [string] $MoqiImeSource = "",
    [string] $Arm64MoqiImeSource = "",
    [switch] $SkipMoqiImeCopy,
    [string] $StageDir = "",
    [string] $IssPath = ""
)

$ErrorActionPreference = "Stop"

function New-CleanDirectory {
    param([string] $Path)

    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
}

function Copy-IfExists {
    param(
        [string] $Source,
        [string] $Destination
    )

    if (-not (Test-Path -LiteralPath $Source)) {
        throw "Required file not found: $Source"
    }
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
}

function Resolve-ArtifactPath {
    param(
        [string[]] $Candidates,
        [string] $Label
    )

    $existingCandidates = foreach ($candidate in $Candidates) {
        if (Test-Path -LiteralPath $candidate) {
            Get-Item -LiteralPath $candidate
        }
    }

    if (-not $existingCandidates) {
        throw "$Label not found. Checked: $($Candidates -join ', ')"
    }

    $selected = $existingCandidates |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1

    Write-Host ("Using {0}: {1} ({2})" -f $Label, $selected.FullName, $selected.LastWriteTime)
    return $selected.FullName
}

function Initialize-ResourceUpdater {
    if ("TypeDuck.ResourceUpdater.NativeMethods" -as [type]) {
        return
    }

    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

namespace TypeDuck.ResourceUpdater {
  public static class NativeMethods {
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern IntPtr BeginUpdateResource(string pFileName, bool bDeleteExistingResources);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool UpdateResource(IntPtr hUpdate, IntPtr lpType, IntPtr lpName, ushort wLanguage, byte[] lpData, uint cbData);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool EndUpdateResource(IntPtr hUpdate, bool fDiscard);
  }
}
"@
}

function Get-ResourceIntPtr {
    param([int] $Value)
    return [IntPtr]::new($Value)
}

function Convert-IcoToResourcePayloads {
    param([string] $IconPath)

    $bytes = [System.IO.File]::ReadAllBytes($IconPath)
    $stream = [System.IO.MemoryStream]::new($bytes)
    $reader = [System.IO.BinaryReader]::new($stream)
    try {
        $reserved = $reader.ReadUInt16()
        $type = $reader.ReadUInt16()
        $count = $reader.ReadUInt16()
        if ($reserved -ne 0 -or $type -ne 1 -or $count -le 0) {
            throw "Invalid .ico file: $IconPath"
        }

        $entries = @()
        for ($i = 0; $i -lt $count; $i++) {
            $entry = [ordered]@{
                Width = $reader.ReadByte()
                Height = $reader.ReadByte()
                ColorCount = $reader.ReadByte()
                Reserved = $reader.ReadByte()
                Planes = $reader.ReadUInt16()
                BitCount = $reader.ReadUInt16()
                BytesInResource = $reader.ReadUInt32()
                ImageOffset = $reader.ReadUInt32()
                ResourceId = $i + 1
            }
            $entries += [pscustomobject]$entry
        }

        $images = @()
        foreach ($entry in $entries) {
            $image = New-Object byte[] ([int] $entry.BytesInResource)
            [Array]::Copy($bytes, [int] $entry.ImageOffset, $image, 0, [int] $entry.BytesInResource)
            $images += [pscustomobject]@{
                Id = [int] $entry.ResourceId
                Data = $image
            }
        }

        $groupStream = [System.IO.MemoryStream]::new()
        $writer = [System.IO.BinaryWriter]::new($groupStream)
        try {
            $writer.Write([UInt16]0)
            $writer.Write([UInt16]1)
            $writer.Write([UInt16]$count)
            foreach ($entry in $entries) {
                $writer.Write([byte] $entry.Width)
                $writer.Write([byte] $entry.Height)
                $writer.Write([byte] $entry.ColorCount)
                $writer.Write([byte] 0)
                $writer.Write([UInt16] $entry.Planes)
                $writer.Write([UInt16] $entry.BitCount)
                $writer.Write([UInt32] $entry.BytesInResource)
                $writer.Write([UInt16] $entry.ResourceId)
            }
            $writer.Flush()
            return [pscustomobject]@{
                Group = $groupStream.ToArray()
                Images = $images
            }
        }
        finally {
            $writer.Dispose()
            $groupStream.Dispose()
        }
    }
    finally {
        $reader.Dispose()
        $stream.Dispose()
    }
}

function Set-WindowsExecutableIcon {
    param(
        [string] $ExecutablePath,
        [string] $IconPath
    )

    if (-not (Test-Path -LiteralPath $ExecutablePath)) {
        throw "Executable not found for icon update: $ExecutablePath"
    }
    if (-not (Test-Path -LiteralPath $IconPath)) {
        throw "Icon file not found for icon update: $IconPath"
    }

    Initialize-ResourceUpdater
    $payload = Convert-IcoToResourcePayloads -IconPath $IconPath
    $handle = [TypeDuck.ResourceUpdater.NativeMethods]::BeginUpdateResource($ExecutablePath, $false)
    if ($handle -eq [IntPtr]::Zero) {
        throw "BeginUpdateResource failed for $ExecutablePath (Win32 $([Runtime.InteropServices.Marshal]::GetLastWin32Error()))"
    }

    $committed = $false
    try {
        foreach ($image in $payload.Images) {
            $ok = [TypeDuck.ResourceUpdater.NativeMethods]::UpdateResource(
                $handle,
                (Get-ResourceIntPtr 3),
                (Get-ResourceIntPtr $image.Id),
                0,
                $image.Data,
                [uint32] $image.Data.Length)
            if (-not $ok) {
                throw "UpdateResource RT_ICON failed for $ExecutablePath (Win32 $([Runtime.InteropServices.Marshal]::GetLastWin32Error()))"
            }
        }

        $groupOk = [TypeDuck.ResourceUpdater.NativeMethods]::UpdateResource(
            $handle,
            (Get-ResourceIntPtr 14),
            (Get-ResourceIntPtr 1),
            0,
            $payload.Group,
            [uint32] $payload.Group.Length)
        if (-not $groupOk) {
            throw "UpdateResource RT_GROUP_ICON failed for $ExecutablePath (Win32 $([Runtime.InteropServices.Marshal]::GetLastWin32Error()))"
        }

        if (-not [TypeDuck.ResourceUpdater.NativeMethods]::EndUpdateResource($handle, $false)) {
            throw "EndUpdateResource failed for $ExecutablePath (Win32 $([Runtime.InteropServices.Marshal]::GetLastWin32Error()))"
        }
        $committed = $true
        Write-Host "Applied icon: $IconPath -> $ExecutablePath"
    }
    finally {
        if (-not $committed -and $handle -ne [IntPtr]::Zero) {
            [void] [TypeDuck.ResourceUpdater.NativeMethods]::EndUpdateResource($handle, $true)
        }
    }
}

function Resolve-MoqiImeSource {
    param(
        [string] $RepoRoot,
        [string] $RequestedSource
    )

    if (-not [string]::IsNullOrWhiteSpace($RequestedSource)) {
        return [System.IO.Path]::GetFullPath($RequestedSource)
    }

    $candidates = @(
        (Join-Path $RepoRoot "..\moqi-ime\scripts\build\TypeDuckRuntime"),
        (Join-Path $RepoRoot "..\moqi-ime")
    )

    foreach ($candidate in $candidates) {
        $fullPath = [System.IO.Path]::GetFullPath($candidate)
        if (Test-Path -LiteralPath (Join-Path $fullPath "server.exe")) {
            return $fullPath
        }
    }

    return [System.IO.Path]::GetFullPath((Join-Path $RepoRoot "..\moqi-ime\scripts\build\TypeDuckRuntime"))
}

function Test-BannedRuntimePath {
    param(
        [string] $RelativePath,
        [bool] $IsDirectory
    )

    $normalized = ($RelativePath -replace '/', '\').TrimStart('\')
    $lower = $normalized.ToLowerInvariant()

    if ($lower -match '(^|\\)\.git(\\|$)') { return $true }
    if ($lower -match '^input_methods\\(fcitx5|moqi)(\\|$)') { return $true }
    if ($lower -match '^input_methods\\rime\\(android|cloudclipboard|templates|test|icons)(\\|$)') { return $true }
    if ($lower -match '^icons(\\|$)') { return $true }
    if (-not $IsDirectory) {
        if ($lower.EndsWith('.go')) { return $true }
        if ($lower -match '^input_methods\\rime\\(icon\.ico|ai_config\.json|ime\.json)$') { return $true }
        if ($lower -match '^input_methods\\rime\\data\\appearance_themes\.json$') { return $true }
        if ($lower -match '^backends(\.|$).*\.json$') { return $true }
    }

    return $false
}

function Copy-TypeDuckRuntime {
    param(
        [string] $SourceRoot,
        [string] $DestinationRoot
    )

    $serverExe = Join-Path $SourceRoot "server.exe"
    if (-not (Test-Path -LiteralPath $serverExe)) {
        throw "TypeDuckRuntime server.exe not found: $serverExe"
    }

    New-Item -ItemType Directory -Path $DestinationRoot -Force | Out-Null

    $directories = Get-ChildItem -Path $SourceRoot -Recurse -Force -Directory |
    Where-Object {
        $relativePath = $_.FullName.Substring($SourceRoot.Length).TrimStart('\', '/')
        -not (Test-BannedRuntimePath -RelativePath $relativePath -IsDirectory $true)
    }
    foreach ($directory in $directories) {
        $relativePath = $directory.FullName.Substring($SourceRoot.Length).TrimStart('\', '/')
        $targetDir = Join-Path $DestinationRoot $relativePath
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    }

    $bannedLegacyIconNames = @(
        "moqi.png",
        "mo.ico",
        "mo.png",
        "moqi.ico",
        "About_Banner.bmp",
        "Credit_Logos.bmp",
        "Installer.bmp"
    )
    $files = Get-ChildItem -Path $SourceRoot -Recurse -Force -File | Where-Object {
        $relativePath = $_.FullName.Substring($SourceRoot.Length).TrimStart('\', '/')
        (-not (Test-BannedRuntimePath -RelativePath $relativePath -IsDirectory $false)) -and
        ($bannedLegacyIconNames -notcontains $_.Name.ToLowerInvariant())
    }
    foreach ($file in $files) {
        $relativePath = $file.FullName.Substring($SourceRoot.Length).TrimStart('\', '/')
        $targetPath = Join-Path $DestinationRoot $relativePath
        $targetDir = Split-Path -Parent $targetPath
        if (-not (Test-Path -LiteralPath $targetDir)) {
            New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
        }
        Copy-Item -LiteralPath $file.FullName -Destination $targetPath -Force
    }
}

$scriptRepoRoot = Join-Path $PSScriptRoot ".."
if (-not $RepoRoot) { $RepoRoot = $scriptRepoRoot }
$RepoRoot = [System.IO.Path]::GetFullPath($RepoRoot)

if (-not $Win32BuildDir) { $Win32BuildDir = Join-Path $RepoRoot "build-vs32" }
if (-not $X64BuildDir) { $X64BuildDir = Join-Path $RepoRoot "build-vs64" }
if (-not $Arm64BuildDir) { $Arm64BuildDir = Join-Path $RepoRoot "build-vsarm64" }
$MoqiImeSource = Resolve-MoqiImeSource -RepoRoot $RepoRoot -RequestedSource $MoqiImeSource
if (-not $Arm64MoqiImeSource) {
    $Arm64MoqiImeSource = Join-Path $RepoRoot "..\moqi-ime\scripts\build\TypeDuckRuntime-arm64"
}
$Arm64MoqiImeSource = [System.IO.Path]::GetFullPath($Arm64MoqiImeSource)
if (-not $StageDir) { $StageDir = Join-Path $RepoRoot "installer\stage" }
if (-not $IssPath) { $IssPath = Join-Path $RepoRoot "installer\MoqiTsf.iss" }
$Win32BuildDir = [System.IO.Path]::GetFullPath($Win32BuildDir)
$X64BuildDir = [System.IO.Path]::GetFullPath($X64BuildDir)
$Arm64BuildDir = [System.IO.Path]::GetFullPath($Arm64BuildDir)
$StageDir = [System.IO.Path]::GetFullPath($StageDir)
$IssPath = [System.IO.Path]::GetFullPath($IssPath)

$stageWin32Root = Join-Path $StageDir "win32\TypeDuckIME"
$stageX64Root = Join-Path $StageDir "x64\TypeDuckIME"
$stageArm64Root = Join-Path $StageDir "arm64\TypeDuckIME"
$stageWin32X64Root = Join-Path $stageWin32Root "x64"
$stageWin32Arm64Root = Join-Path $stageWin32Root "arm64"
$stageArm64X64Root = Join-Path $stageArm64Root "x64"
$stageArm64NativeRoot = Join-Path $stageArm64Root "arm64"
$iconSourceRoot = Join-Path $RepoRoot "TypeDuckSettings\assets"
$resourceSourceRoot = Join-Path $RepoRoot "TypeDuckSettings\resources"
$transparentIcon = Join-Path $iconSourceRoot "TypeDuck_Transparent.ico"
$smallIcon = Join-Path $iconSourceRoot "TypeDuck_Small.ico"
$aboutBanner = Join-Path $resourceSourceRoot "About_Banner.bmp"
$creditLogos = Join-Path $resourceSourceRoot "Credit_Logos.bmp"
$installerBitmap = Join-Path $resourceSourceRoot "Installer.bmp"
$licenseNotice = Join-Path $RepoRoot "THIRD_PARTY_NOTICES.txt"

New-CleanDirectory -Path $StageDir
foreach ($directory in @(
    $stageWin32Root,
    $stageX64Root,
    $stageArm64Root,
    $stageWin32X64Root,
    $stageWin32Arm64Root,
    $stageArm64X64Root,
    $stageArm64NativeRoot
  )) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
}

foreach ($payloadRoot in @($stageWin32Root, $stageArm64Root)) {
    $stageResourceRoot = Join-Path $payloadRoot "resources"
    New-Item -ItemType Directory -Path $stageResourceRoot -Force | Out-Null
    Copy-IfExists -Source $aboutBanner -Destination (Join-Path $stageResourceRoot "About_Banner.bmp")
    Copy-IfExists -Source $creditLogos -Destination (Join-Path $stageResourceRoot "Credit_Logos.bmp")
    Copy-IfExists -Source $installerBitmap -Destination (Join-Path $stageResourceRoot "Installer.bmp")
    Copy-IfExists -Source $smallIcon -Destination (Join-Path $stageResourceRoot "TypeDuck_Small.ico")
    Copy-IfExists -Source $licenseNotice -Destination (Join-Path $payloadRoot "THIRD_PARTY_NOTICES.txt")
}

$win32Launcher = Resolve-ArtifactPath -Label "Win32 TypeDuckLauncher.exe" -Candidates @(
    (Join-Path $Win32BuildDir "Release\TypeDuckLauncher.exe"),
    (Join-Path $Win32BuildDir "MoqLauncher\Release\TypeDuckLauncher.exe"),
    (Join-Path $Win32BuildDir "Debug\TypeDuckLauncher.exe"),
    (Join-Path $Win32BuildDir "MoqLauncher\Debug\TypeDuckLauncher.exe")
)
$arm64Launcher = Resolve-ArtifactPath -Label "ARM64 TypeDuckLauncher.exe" -Candidates @(
    (Join-Path $Arm64BuildDir "Release\TypeDuckLauncher.exe"),
    (Join-Path $Arm64BuildDir "MoqLauncher\Release\TypeDuckLauncher.exe"),
    (Join-Path $Arm64BuildDir "Debug\TypeDuckLauncher.exe"),
    (Join-Path $Arm64BuildDir "MoqLauncher\Debug\TypeDuckLauncher.exe")
)

$win32SetupHelper = Resolve-ArtifactPath -Label "Win32 TypeDuckSetupHelper.exe" -Candidates @(
    (Join-Path $Win32BuildDir "Release\TypeDuckSetupHelper.exe"),
    (Join-Path $Win32BuildDir "SetupHelper\Release\TypeDuckSetupHelper.exe"),
    (Join-Path $Win32BuildDir "Debug\TypeDuckSetupHelper.exe"),
    (Join-Path $Win32BuildDir "SetupHelper\Debug\TypeDuckSetupHelper.exe")
)
$arm64SetupHelper = Resolve-ArtifactPath -Label "ARM64 TypeDuckSetupHelper.exe" -Candidates @(
    (Join-Path $Arm64BuildDir "Release\TypeDuckSetupHelper.exe"),
    (Join-Path $Arm64BuildDir "SetupHelper\Release\TypeDuckSetupHelper.exe"),
    (Join-Path $Arm64BuildDir "Debug\TypeDuckSetupHelper.exe"),
    (Join-Path $Arm64BuildDir "SetupHelper\Debug\TypeDuckSetupHelper.exe")
)

$win32Settings = Resolve-ArtifactPath -Label "Win32 TypeDuckSettings.exe" -Candidates @(
    (Join-Path $Win32BuildDir "Release\TypeDuckSettings.exe"),
    (Join-Path $Win32BuildDir "TypeDuckSettings\Release\TypeDuckSettings.exe"),
    (Join-Path $Win32BuildDir "Debug\TypeDuckSettings.exe"),
    (Join-Path $Win32BuildDir "TypeDuckSettings\Debug\TypeDuckSettings.exe")
)
$arm64Settings = Resolve-ArtifactPath -Label "ARM64 TypeDuckSettings.exe" -Candidates @(
    (Join-Path $Arm64BuildDir "Release\TypeDuckSettings.exe"),
    (Join-Path $Arm64BuildDir "TypeDuckSettings\Release\TypeDuckSettings.exe"),
    (Join-Path $Arm64BuildDir "Debug\TypeDuckSettings.exe"),
    (Join-Path $Arm64BuildDir "TypeDuckSettings\Debug\TypeDuckSettings.exe")
)

$win32About = Resolve-ArtifactPath -Label "Win32 TypeDuckAbout.exe" -Candidates @(
    (Join-Path $Win32BuildDir "Release\TypeDuckAbout.exe"),
    (Join-Path $Win32BuildDir "TypeDuckSettings\Release\TypeDuckAbout.exe"),
    (Join-Path $Win32BuildDir "Debug\TypeDuckAbout.exe"),
    (Join-Path $Win32BuildDir "TypeDuckSettings\Debug\TypeDuckAbout.exe")
)
$arm64About = Resolve-ArtifactPath -Label "ARM64 TypeDuckAbout.exe" -Candidates @(
    (Join-Path $Arm64BuildDir "Release\TypeDuckAbout.exe"),
    (Join-Path $Arm64BuildDir "TypeDuckSettings\Release\TypeDuckAbout.exe"),
    (Join-Path $Arm64BuildDir "Debug\TypeDuckAbout.exe"),
    (Join-Path $Arm64BuildDir "TypeDuckSettings\Debug\TypeDuckAbout.exe")
)

foreach ($executable in @(
    @{ Source = $win32Launcher; Destination = (Join-Path $stageWin32Root "TypeDuckLauncher.exe") },
    @{ Source = $win32SetupHelper; Destination = (Join-Path $stageWin32Root "TypeDuckSetupHelper.exe") },
    @{ Source = $win32Settings; Destination = (Join-Path $stageWin32Root "TypeDuckSettings.exe") },
    @{ Source = $win32About; Destination = (Join-Path $stageWin32Root "TypeDuckAbout.exe") },
    @{ Source = $arm64Launcher; Destination = (Join-Path $stageArm64Root "TypeDuckLauncher.exe") },
    @{ Source = $arm64SetupHelper; Destination = (Join-Path $stageArm64Root "TypeDuckSetupHelper.exe") },
    @{ Source = $arm64Settings; Destination = (Join-Path $stageArm64Root "TypeDuckSettings.exe") },
    @{ Source = $arm64About; Destination = (Join-Path $stageArm64Root "TypeDuckAbout.exe") }
  )) {
    Copy-IfExists -Source $executable.Source -Destination $executable.Destination
    Set-WindowsExecutableIcon -ExecutablePath $executable.Destination -IconPath $transparentIcon
}

$dll32 = Resolve-ArtifactPath -Label "Win32 TypeDuckTextService.dll" -Candidates @(
    (Join-Path $Win32BuildDir "Release\TypeDuckTextService.dll"),
    (Join-Path $Win32BuildDir "MoqiTextService\Release\TypeDuckTextService.dll"),
    (Join-Path $Win32BuildDir "Debug\TypeDuckTextService.dll"),
    (Join-Path $Win32BuildDir "MoqiTextService\Debug\TypeDuckTextService.dll")
)
Copy-IfExists -Source $dll32 -Destination (Join-Path $stageWin32Root "TypeDuckTextService.dll")
Copy-IfExists -Source $dll32 -Destination (Join-Path $stageArm64Root "TypeDuckTextService.dll")

$dll64 = Resolve-ArtifactPath -Label "x64 TypeDuckTextService.dll" -Candidates @(
    (Join-Path $X64BuildDir "Release\TypeDuckTextService.dll"),
    (Join-Path $X64BuildDir "MoqiTextService\Release\TypeDuckTextService.dll")
)
Copy-IfExists -Source $dll64 -Destination (Join-Path $stageX64Root "TypeDuckTextService.dll")
Copy-IfExists -Source $dll64 -Destination (Join-Path $stageWin32X64Root "TypeDuckTextService.dll")
Copy-IfExists -Source $dll64 -Destination (Join-Path $stageArm64X64Root "TypeDuckTextService.dll")

$dllArm64 = Resolve-ArtifactPath -Label "ARM64 TypeDuckTextService.dll" -Candidates @(
    (Join-Path $Arm64BuildDir "Release\TypeDuckTextService.dll"),
    (Join-Path $Arm64BuildDir "MoqiTextService\Release\TypeDuckTextService.dll")
)
Copy-IfExists -Source $dllArm64 -Destination (Join-Path $stageWin32Arm64Root "TypeDuckTextService.dll")
Copy-IfExists -Source $dllArm64 -Destination (Join-Path $stageArm64NativeRoot "TypeDuckTextService.dll")

if (-not $SkipMoqiImeCopy) {
    foreach ($runtime in @(
        @{ Source = $MoqiImeSource; Destination = (Join-Path $stageWin32Root "TypeDuckRuntime"); Label = "x64" },
        @{ Source = $Arm64MoqiImeSource; Destination = (Join-Path $stageArm64Root "TypeDuckRuntime"); Label = "ARM64" }
      )) {
        if (-not (Test-Path -LiteralPath $runtime.Source)) {
            throw "$($runtime.Label) TypeDuck runtime source not found: $($runtime.Source)"
        }
        Copy-TypeDuckRuntime -SourceRoot $runtime.Source -DestinationRoot $runtime.Destination
        Set-WindowsExecutableIcon -ExecutablePath (Join-Path $runtime.Destination "server.exe") -IconPath $transparentIcon
    }
}
else {
    Write-Warning "Skipped copying TypeDuckRuntime payloads."
}

$installerScript = Join-Path $RepoRoot "installer\build-installer.ps1"
if (-not (Test-Path -LiteralPath $installerScript)) {
    throw "Installer builder script not found: $installerScript"
}
if (-not (Test-Path -LiteralPath $IssPath)) {
    throw "Installer ISS file not found: $IssPath"
}

Write-Host "Stage prepared at: $StageDir"
Write-Host "x64-Windows application payload: $stageWin32Root"
Write-Host "ARM64-Windows application payload: $stageArm64Root"

& $installerScript -StageDir $StageDir -IssPath $IssPath

Write-Host "Installer build finished."

