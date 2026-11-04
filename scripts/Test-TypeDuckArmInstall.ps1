param([Parameter(Mandatory)][string]$Artifacts)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne 'Arm64') {
  throw 'This test requires Windows on ARM64'
}
New-Item arm-validation -ItemType Directory -Force | Out-Null
Start-Transcript arm-validation/results.txt
try {
  Write-Host "OS architecture: $([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture)"
  Write-Host "Test shell architecture: $([System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture)"
  foreach ($test in Get-ChildItem "$Artifacts/frontend-ARM64X/ARM64-tests" -Filter '*_test.exe') {
    & $test.FullName
    if ($LASTEXITCODE) { throw "Native ARM64 test failed: $($test.Name)" }
  }
  $installer = Join-Path $Artifacts 'TypeDuck-Windows-ARM64-installer/typeduck-windows-arm64-setup.exe'
  $installDir = Join-Path ${env:ProgramFiles(x86)} 'TypeDuckIME'
  foreach ($pass in 'install','upgrade') {
    $log = Join-Path $PWD "arm-validation/$pass.log"
    $process = Start-Process -FilePath $installer -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART',"/LOG=`"$log`"") -Wait -PassThru -WindowStyle Hidden
    if ($process.ExitCode -ne 0) { throw "$pass returned $($process.ExitCode); reboot path needs separate validation" }
    $expectedHash = (Get-FileHash -LiteralPath "$Artifacts/frontend-ARM64X/MoqiTextService/Release/TypeDuckTextService.dll" -Algorithm SHA256).Hash
    $installedHash = (Get-FileHash -LiteralPath "$env:WINDIR/System32/TypeDuckTextService.dll" -Algorithm SHA256).Hash
    if ($installedHash -ne $expectedHash) { throw 'Setup did not install the ARM64X system DLL' }
    foreach ($probe in @('frontend-ARM64X/ARM64-tests/TypeDuckLoadProbe.exe','frontend-x64/TypeDuckLoadProbe.exe','frontend-Win32/TypeDuckLoadProbe.exe')) {
      & (Join-Path $Artifacts $probe)
      if ($LASTEXITCODE) { throw "COM activation failed: $probe" }
    }
    if ($pass -eq 'install') {
      $runtime = Join-Path $installDir 'TypeDuckRuntime'
      $server = Join-Path $runtime 'server.exe'
      $manifest = Join-Path $PWD 'arm-validation/runtime-manifest.json'
      $serverHash = (Get-FileHash -LiteralPath $server -Algorithm SHA256).Hash
      @{
        backend_commit = '9c7283b35cfe93e962b808df3a24e894f5be94e4'
        server_sha256 = $serverHash
        rime_sha256 = (Get-FileHash -LiteralPath "$runtime/input_methods/rime/rime.dll" -Algorithm SHA256).Hash
        schema_commit = '4751662c19556b6ea32fd4a0c55b830cb9ea3045'
      } | ConvertTo-Json | Set-Content -LiteralPath $manifest
      $manifestHash = (Get-FileHash -LiteralPath $manifest -Algorithm SHA256).Hash
      & "$Artifacts/frontend-Win32/TypeduckBackendProbe.exe" --server-exe $server --working-dir $runtime --runtime-manifest $manifest --runtime-manifest-sha256 $manifestHash --adapter-root $runtime --adapter-commit 9c7283b35cfe93e962b808df3a24e894f5be94e4 --adapter-server-sha256 $serverHash --output "$PWD/arm-validation/typing-proof.json" --frames "$PWD/arm-validation/synthetic-typing-frames.ndjson" --timeout-ms 60000
      if ($LASTEXITCODE) { throw 'Packaged engine composition/candidate/commit probe failed on ARM64' }
    }
  }
  $uninstallLog = Join-Path $PWD 'arm-validation/uninstall.log'
  $process = Start-Process -FilePath "$installDir/unins000.exe" -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART',"/LOG=`"$uninstallLog`"") -Wait -PassThru -WindowStyle Hidden
  if ($process.ExitCode -ne 0) { throw "Uninstall returned $($process.ExitCode)" }
  $key = 'Registry::HKEY_LOCAL_MACHINE/SOFTWARE/Classes/CLSID/{7D92985A-BC53-47B5-A5CC-6E47F86B9D18}/InprocServer32'
  if (Test-Path -LiteralPath $key) { throw '64-bit COM registration remained after uninstall' }
  $key32 = 'Registry::HKEY_LOCAL_MACHINE/SOFTWARE/Classes/WOW6432Node/CLSID/{7D92985A-BC53-47B5-A5CC-6E47F86B9D18}/InprocServer32'
  if (Test-Path -LiteralPath $key32) { throw '32-bit COM registration remained after uninstall' }
} finally {
  Stop-Transcript
}
