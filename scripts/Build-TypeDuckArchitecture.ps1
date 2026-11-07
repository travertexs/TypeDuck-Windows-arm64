param(
  [Parameter(Mandatory)][ValidateSet('Win32','x64','ARM64X')][string]$Architecture,
  [Parameter(Mandatory)][string]$Protoc
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
Set-Location $repo
& "$PSScriptRoot/Apply-TypeDuckSubmodulePatches.ps1" -RepoRoot $repo
$common = @('-S', $repo, '-G', 'Visual Studio 17 2022', "-DMOQI_PROTOC_EXECUTABLE=$Protoc")
if ($Architecture -eq 'ARM64X') {
  $response = Join-Path $repo 'arm64-link.rsp'
  cmake @common -B build-ARM64 -A ARM64 -DTYPEDUCK_ARM64X_MODE=ARM64 "-DTYPEDUCK_ARM64X_INPUTS=$response"
  cmake --build build-ARM64 --config Release --parallel 4 --target MoqiTextService TypeDuckLoadProbe TypeDuckCandidateInfo_test CandidatePlacement_test TypeDuckPreferences_test ProtoFraming_test ProtocolRecovery_test TouchKeyboard_test
  cmake @common -B build-ARM64X -A ARM64EC -DTYPEDUCK_ARM64X_MODE=ARM64EC "-DTYPEDUCK_ARM64X_INPUTS=$response"
  cmake --build build-ARM64X --config Release --parallel 4 --target MoqiTextService
  $image = [IO.File]::ReadAllBytes("$repo/build-ARM64X/MoqiTextService/Release/TypeDuckTextService.dll")
  $pe = [BitConverter]::ToInt32($image, 60)
  if ([BitConverter]::ToUInt16($image, $pe + 4) -ne 0xaa64) {
    throw 'The combined DLL is not ARM64X; check linker machine option ordering'
  }
  New-Item payload/ARM64-tests -ItemType Directory -Force | Out-Null
  Get-ChildItem build-ARM64 -Filter '*_test.exe' -Recurse | Copy-Item -Destination payload/ARM64-tests
  Copy-Item build-ARM64/Release/TypeDuckLoadProbe.exe payload/ARM64-tests
} else {
  cmake @common -B "build-$Architecture" -A $Architecture
  cmake --build "build-$Architecture" --config Release --parallel 4
  ctest --test-dir "build-$Architecture" -C Release --output-on-failure --no-tests=error
}
$build = Join-Path $repo "build-$Architecture"
New-Item payload/MoqiTextService/Release -ItemType Directory -Force | Out-Null
Copy-Item "$build/MoqiTextService/Release/TypeDuckTextService.dll" payload/MoqiTextService/Release
if ($Architecture -ne 'ARM64X') {
  Copy-Item "$build/Release/TypeDuckLoadProbe.exe" payload
}
if ($Architecture -eq 'Win32') {
  Copy-Item "$build/Tools/TypeduckBackendProbe/Release/TypeduckBackendProbe.exe" payload
  foreach ($name in 'TypeDuckLauncher.exe','TypeDuckSetupHelper.exe','TypeDuckSettings.exe','TypeDuckAbout.exe') {
    $file = @(Get-ChildItem $build -Recurse -Filter $name | Where-Object { $_.Directory.Name -eq 'Release' })
    if ($file.Count -ne 1) { throw "Expected one Release binary: $name" }
    Copy-Item -LiteralPath $file[0].FullName -Destination payload
  }
}
