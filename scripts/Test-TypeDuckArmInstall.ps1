param([Parameter(Mandatory)][string]$Artifacts)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne 'Arm64') {
  throw 'This test requires Windows on ARM64'
}
New-Item arm-validation -ItemType Directory -Force | Out-Null
function Invoke-SetupProcess([string]$FilePath, [string]$Log, [string]$Locale = '') {
  Write-Host "Running setup: $FilePath; log: $Log"
  # Start-Process -Wait waits for descendants, including the persistent launcher.
  $setupArguments = @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/RESTARTEXITCODE=3010',"/LOG=`"$Log`"")
  if ($Locale) { $setupArguments += "/IMELOCALE=$Locale" }
  $process = Start-Process -FilePath $FilePath -ArgumentList $setupArguments -PassThru -WindowStyle Hidden
  if (-not $process.WaitForExit(180000)) {
    if (Test-Path -LiteralPath $Log) { Get-Content -LiteralPath $Log -Tail 100 | Write-Host }
    throw "Setup process $($process.Id) exceeded three minutes"
  }
  Write-Host "Setup exited: $($process.ExitCode)"
  return $process.ExitCode
}
function Invoke-LoadProbe([string]$Probe, [string]$Locale, [switch]$TouchPackets) {
  $PSNativeCommandUseErrorActionPreference = $false
  for ($attempt = 1; $attempt -le 3; $attempt++) {
    $arguments = @($Locale)
    if ($TouchPackets) { $arguments += '--touch-packets' }
    & $Probe @arguments
    if ($LASTEXITCODE -eq 0) { return }
    if ($LASTEXITCODE -ne 75) { throw "Runtime probe failed with exit ${LASTEXITCODE}: $Probe" }
    # TSF can snapshot the old profile in the first process after migration,
    # even after its registry registration is removed. Require a fresh process
    # to pass every API assertion; a registry-only result is never a pass.
    Write-Host "Retrying TSF cache snapshot in a fresh process ($attempt/3)"
    Start-Sleep -Milliseconds 250
  }
  throw "TSF profile cache did not settle in three processes: $Probe"
}
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
  $probeFailures = [System.Collections.Generic.List[string]]::new()
  try {
    & "$PSScriptRoot/Test-TypeDuckInstallerUi.ps1" -Installer $installer -Output "$PWD/arm-validation/installer-language-hk"
  } catch { $probeFailures.Add("Installer UI (HK): $_"); Write-Warning $probeFailures[$probeFailures.Count - 1] }
  $invalidExit = Invoke-SetupProcess -FilePath $installer -Log "$PWD/arm-validation/invalid-locale.log" -Locale 'zh-CN'
  if ($invalidExit -eq 0) { throw 'Unsupported locale was accepted' }
  if (Test-Path "$installDir/TypeDuckSetupHelper.exe") { throw 'Invalid locale modified the installation' }
  $passes = @(
    @{ Name = 'install'; Choice = ''; Expected = 'zh-HK' },
    @{ Name = 'upgrade-hk'; Choice = ''; Expected = 'zh-HK' },
    @{ Name = 'migrate-tw'; Choice = 'zh-TW'; Expected = 'zh-TW' },
    @{ Name = 'upgrade-tw'; Choice = ''; Expected = 'zh-TW' },
    @{ Name = 'migrate-hk'; Choice = 'zh-HK'; Expected = 'zh-HK' }
  )
  foreach ($case in $passes) {
    $pass = $case.Name
    $log = Join-Path $PWD "arm-validation/$pass.log"
    $setupExitCode = Invoke-SetupProcess -FilePath $installer -Log $log -Locale $case.Choice
    if ($setupExitCode -ne 0) { throw "$pass returned $setupExitCode; reboot path needs separate validation" }
    foreach ($view in @([Microsoft.Win32.RegistryView]::Registry32, [Microsoft.Win32.RegistryView]::Registry64)) {
      $hive = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $view)
      try {
        $key = $hive.OpenSubKey('Software\TypeDuckIME')
        try {
          if ($key.GetValue('RegistrationLocale') -ne $case.Expected) { throw "Wrong persisted locale in $view" }
          if ($key.GetValue('PendingRegistrationLocale')) { throw "Unexpected pending locale in $view" }
        } finally { if ($key) { $key.Dispose() } }
        $selectedLanguage = if ($case.Expected -eq 'zh-TW') { '0x00000404' } else { '0x00000c04' }
        $oldLanguage = if ($case.Expected -eq 'zh-TW') { '0x00000c04' } else { '0x00000404' }
        $profileRoot = 'SOFTWARE\Microsoft\CTF\TIP\{7D92985A-BC53-47B5-A5CC-6E47F86B9D18}\LanguageProfile'
        $profileGuid = '{C6E8F5DF-6504-44F9-B7CF-17A195373A83}'
        $selectedKey = $hive.OpenSubKey("$profileRoot\$selectedLanguage\$profileGuid")
        $oldKey = $hive.OpenSubKey("$profileRoot\$oldLanguage\$profileGuid")
        try {
          if (-not $selectedKey -or $oldKey) { throw "Expected exactly the selected TSF language profile in $view" }
        } finally {
          if ($selectedKey) { $selectedKey.Dispose() }
          if ($oldKey) { $oldKey.Dispose() }
        }
      } finally { $hive.Dispose() }
    }
    $expectedHash = (Get-FileHash -LiteralPath "$Artifacts/frontend-ARM64X/MoqiTextService/Release/TypeDuckTextService.dll" -Algorithm SHA256).Hash
    $installedHash = (Get-FileHash -LiteralPath "$env:WINDIR/System32/TypeDuckTextService.dll" -Algorithm SHA256).Hash
    if ($installedHash -ne $expectedHash) { throw 'Setup did not install the ARM64X system DLL' }
    foreach ($probe in @('frontend-ARM64X/ARM64-tests/TypeDuckLoadProbe.exe','frontend-x64/TypeDuckLoadProbe.exe','frontend-Win32/TypeDuckLoadProbe.exe')) {
      Write-Host "Testing COM activation: $probe"
      try {
        Invoke-LoadProbe (Join-Path $Artifacts $probe) $case.Expected -TouchPackets
      } catch {
        $probeFailures.Add("${pass}: ${probe}: $_")
        Write-Warning $probeFailures[$probeFailures.Count - 1]
      }
    }
    if ($pass -eq 'install' -or $pass -eq 'migrate-tw') {
      if ($pass -eq 'install') {
        $sentinel = Join-Path $env:LOCALAPPDATA 'TypeDuckIME/locale-upgrade-preservation.txt'
        'Preserve existing user files through locale migration.' | Set-Content -LiteralPath $sentinel
        $sentinelHash = (Get-FileHash -LiteralPath $sentinel).Hash
      }
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
      try {
        & "$Artifacts/frontend-Win32/TypeduckBackendProbe.exe" --server-exe $server --working-dir $runtime --runtime-manifest $manifest --runtime-manifest-sha256 $manifestHash --adapter-root $runtime --adapter-commit 9c7283b35cfe93e962b808df3a24e894f5be94e4 --adapter-server-sha256 $serverHash --output "$PWD/arm-validation/typing-proof-$($case.Expected).json" --frames "$PWD/arm-validation/synthetic-typing-frames-$($case.Expected).ndjson" --timeout-ms 60000
        if ($LASTEXITCODE) { throw 'Packaged engine composition/candidate/commit probe failed on ARM64' }
      } catch {
        $probeFailures.Add("Installed engine: $_")
        Write-Warning $probeFailures[$probeFailures.Count - 1]
      }
    }
    if ($pass -eq 'upgrade-tw') {
      try {
        & "$PSScriptRoot/Test-TypeDuckInstallerUi.ps1" -Installer $installer -ExpectedLocale 'zh-TW' -Output "$PWD/arm-validation/installer-language-tw"
      } catch { $probeFailures.Add("Installer UI (TW): $_"); Write-Warning $probeFailures[$probeFailures.Count - 1] }
    }
    if ((Get-FileHash -LiteralPath $sentinel).Hash -ne $sentinelHash) { throw 'An update changed the existing user data sentinel' }
  }

  # Exercise the actual sharing-violation/deferred-registration path. This
  # validates staging, task arguments and the post-restart callback, without
  # claiming that a hosted runner was rebooted. Both DLL copies are this build.
  $lockedDll = [IO.File]::Open("$env:WINDIR/System32/TypeDuckTextService.dll", [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
  $lockedDll32 = [IO.File]::Open("$env:WINDIR/SysWOW64/TypeDuckTextService.dll", [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
  try {
    $deferredExit = Invoke-SetupProcess -FilePath $installer -Log "$PWD/arm-validation/deferred-tw.log" -Locale 'zh-TW'
    $saved = Get-ItemProperty 'HKLM:\Software\TypeDuckIME'
    $saved | Format-List | Out-File "$PWD/arm-validation/deferred-registry.txt"
    if ($deferredExit -ne 3010) {
      $probeFailures.Add("Locked DLL update should request restart, returned $deferredExit")
      Write-Warning $probeFailures[$probeFailures.Count - 1]
    }
    if ($saved.RegistrationLocale -ne 'zh-HK' -or $saved.PendingRegistrationLocale -ne 'zh-TW') { throw 'Pending locale changed the active locale prematurely' }
    $task = Get-ScheduledTask -TaskName 'TypeDuckIME-ReRegisterTSF'
    if ($task.Actions.Arguments -notmatch '--locale zh-TW') { throw 'Restart task lost the selected language' }
    $task | Export-Clixml "$PWD/arm-validation/deferred-task.xml"
  } finally { $lockedDll.Dispose(); $lockedDll32.Dispose() }
  $reregister = Start-Process "$installDir/TypeDuckSetupHelper.exe" -ArgumentList @('/r','/s','--appdir',"`"$installDir`"") -PassThru -WindowStyle Hidden
  if (-not $reregister.WaitForExit(60000) -or $reregister.ExitCode -ne 0) { throw 'Deferred registration callback failed' }
  & reg.exe query 'HKLM\SOFTWARE\Microsoft\CTF\TIP\{7D92985A-BC53-47B5-A5CC-6E47F86B9D18}\LanguageProfile' /s /reg:64 | Out-File "$PWD/arm-validation/deferred-final-profiles.txt"
  Get-ItemProperty 'HKLM:\Software\TypeDuckIME' | Format-List | Out-File "$PWD/arm-validation/deferred-final-locale.txt"
  Invoke-LoadProbe "$Artifacts/frontend-ARM64X/ARM64-tests/TypeDuckLoadProbe.exe" 'zh-TW'
  $saved = Get-ItemProperty 'HKLM:\Software\TypeDuckIME'
  if ($saved.RegistrationLocale -ne 'zh-TW' -or $saved.PendingRegistrationLocale) { throw 'Deferred registration state was not finalized' }
  if (Get-ScheduledTask -TaskName 'TypeDuckIME-ReRegisterTSF' -ErrorAction SilentlyContinue) { throw 'Completed restart task remained' }
  $uninstallLog = Join-Path $PWD 'arm-validation/uninstall.log'
  $setupExitCode = Invoke-SetupProcess -FilePath "$installDir/unins000.exe" -Log $uninstallLog
  if ($setupExitCode -ne 0) { throw "Uninstall returned $setupExitCode" }
  $key = 'Registry::HKEY_LOCAL_MACHINE/SOFTWARE/Classes/CLSID/{7D92985A-BC53-47B5-A5CC-6E47F86B9D18}/InprocServer32'
  if (Test-Path -LiteralPath $key) { throw '64-bit COM registration remained after uninstall' }
  $key32 = 'Registry::HKEY_LOCAL_MACHINE/SOFTWARE/Classes/WOW6432Node/CLSID/{7D92985A-BC53-47B5-A5CC-6E47F86B9D18}/InprocServer32'
  if (Test-Path -LiteralPath $key32) { throw '32-bit COM registration remained after uninstall' }

  $freshTw = Invoke-SetupProcess -FilePath $installer -Log "$PWD/arm-validation/fresh-tw.log" -Locale 'zh-TW'
  if ($freshTw -ne 0) { throw "Fresh Taiwan installation returned $freshTw" }
  foreach ($probe in @('frontend-ARM64X/ARM64-tests/TypeDuckLoadProbe.exe','frontend-x64/TypeDuckLoadProbe.exe','frontend-Win32/TypeDuckLoadProbe.exe')) {
    Invoke-LoadProbe (Join-Path $Artifacts $probe) 'zh-TW'
  }
  $invalid = Start-Process "$installDir/TypeDuckSetupHelper.exe" -ArgumentList @('/r','--locale','zh-CN','/s') -PassThru -WindowStyle Hidden
  if (-not $invalid.WaitForExit(10000) -or $invalid.ExitCode -ne 3) { throw 'Helper did not reject invalid locale silently' }
  $setupExitCode = Invoke-SetupProcess -FilePath "$installDir/unins000.exe" -Log "$PWD/arm-validation/uninstall-tw.log"
  if ($setupExitCode -ne 0) { throw "Taiwan uninstall returned $setupExitCode" }
  if ((Test-Path -LiteralPath $key) -or (Test-Path -LiteralPath $key32)) { throw 'COM registration remained after Taiwan uninstall' }
  if ($probeFailures.Count) { throw ($probeFailures -join "`n") }
} finally {
  Stop-Transcript
}
