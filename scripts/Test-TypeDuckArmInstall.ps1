param([Parameter(Mandatory)][string]$Artifacts)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne 'Arm64') {
  throw 'This test requires Windows on ARM64'
}
New-Item arm-validation -ItemType Directory -Force | Out-Null
Start-Transcript arm-validation/results.txt
try {
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
    foreach ($probe in @('frontend-ARM64X/ARM64-tests/TypeDuckLoadProbe.exe','frontend-x64/TypeDuckLoadProbe.exe','frontend-Win32/TypeDuckLoadProbe.exe')) {
      & (Join-Path $Artifacts $probe)
      if ($LASTEXITCODE) { throw "COM activation failed: $probe" }
    }
  }
  $uninstallLog = Join-Path $PWD 'arm-validation/uninstall.log'
  $process = Start-Process -FilePath "$installDir/unins000.exe" -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART',"/LOG=`"$uninstallLog`"") -Wait -PassThru -WindowStyle Hidden
  if ($process.ExitCode -ne 0) { throw "Uninstall returned $($process.ExitCode)" }
  $key = 'Registry::HKEY_LOCAL_MACHINE/SOFTWARE/Classes/CLSID/{7D92985A-BC53-47B5-A5CC-6E47F86B9D18}/InprocServer32'
  if (Test-Path -LiteralPath $key) { throw '64-bit COM registration remained after uninstall' }
} finally {
  Stop-Transcript
}
