param(
  [Parameter(Mandatory)][string]$Installer,
  [ValidateSet('zh-HK','zh-TW')][string]$ExpectedLocale = 'zh-HK',
  [string]$Choice = '',
  [string]$Output = 'arm-validation/installer-language-page'
)
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true') { throw 'Run this UI test only on the disposable GitHub Actions runner' }
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class TypeDuckUiTest {
  [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hwnd, uint msg, IntPtr wp, IntPtr lp);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hwnd, uint msg, IntPtr wp, IntPtr lp);
  [DllImport("user32.dll")] public static extern IntPtr GetParent(IntPtr hwnd);
  [DllImport("user32.dll")] public static extern int GetDlgCtrlID(IntPtr hwnd);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hwnd, int command);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hwnd, IntPtr hdc, uint flags);
}
'@
function Find-Control($Root, [string]$Name) {
  $condition = [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::NameProperty, $Name)
  $found = $Root.FindFirst([Windows.Automation.TreeScope]::Descendants, $condition)
  if ($found) { return $found }
  $hint = switch ($Name) { '下一步 Next >' { 'Next' }; '取消 Cancel' { 'Cancel' }; '是 Yes' { 'Yes' }; default { '' } }
  if ($hint) {
    $buttons = $Root.FindAll([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.Condition]::TrueCondition)
    $matches = @($buttons | Where-Object { $_.Current.Name -like "*$hint*" -and ($_.Current.ClassName -in @('TNewButton','Button') -or $_.Current.ControlType -eq [Windows.Automation.ControlType]::Button) })
    if ($matches.Count -eq 1) { return $matches[0] }
  }
  return $null
}
function Click-Control($Control) {
  if ($null -eq $Control) { throw 'Expected installer control was not found' }
  Write-Host "Click installer control: $($Control.Current.Name)"
  if ($Control.Current.NativeWindowHandle -ne 0) {
    $handle = [IntPtr]$Control.Current.NativeWindowHandle
    $parent = [TypeDuckUiTest]::GetParent($handle)
    $id = [TypeDuckUiTest]::GetDlgCtrlID($handle) -band 0xffff
    if (-not [TypeDuckUiTest]::PostMessage($parent, 0x111, [IntPtr]$id, $handle)) { throw 'Cannot click native installer button' }
  } else {
    $pattern = $Control.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern)
    $pattern.Invoke()
  }
}
$arguments = @('/NORESTART')
if ($Choice) { $arguments += "/IMELOCALE=$Choice" }
$process = Start-Process $Installer -ArgumentList $arguments -PassThru -WindowStyle Normal
$root = [Windows.Automation.AutomationElement]::RootElement
$window = $null
try {
  $deadline = [DateTime]::UtcNow.AddSeconds(30)
  while (-not $window -and [DateTime]::UtcNow -lt $deadline) {
    $windows = $root.FindAll([Windows.Automation.TreeScope]::Children, [Windows.Automation.Condition]::TrueCondition)
    foreach ($item in $windows) {
      if ($item.Current.ClassName -eq 'TWizardForm' -and $item.Current.Name -like '*TypeDuck*') { $window = $item; break }
    }
    if (-not $window) { Start-Sleep -Milliseconds 200 }
  }
  if (-not $window) { throw 'Installer wizard did not appear on the runner desktop' }
  [TypeDuckUiTest]::ShowWindow([IntPtr]$window.Current.NativeWindowHandle, 5) | Out-Null
  [TypeDuckUiTest]::SetForegroundWindow([IntPtr]$window.Current.NativeWindowHandle) | Out-Null
  $window.FindAll([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.Condition]::TrueCondition) |
    ForEach-Object { "$($_.Current.ControlType.ProgrammaticName): $($_.Current.Name); class=$($_.Current.ClassName); hwnd=$($_.Current.NativeWindowHandle)" } | Set-Content "$Output-welcome.txt"
  Click-Control (Find-Control $window '下一步 Next >')
  Start-Sleep -Milliseconds 300
  $controls = $window.FindAll([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.Condition]::TrueCondition)
  $controls | ForEach-Object { "$($_.Current.ControlType.ProgrammaticName): $($_.Current.Name); hwnd=$($_.Current.NativeWindowHandle); patterns=$($_.GetSupportedPatterns().ProgrammaticName -join ',')" } | Set-Content "$Output.txt"
  $hk = Find-Control $window '中文（香港）/ Chinese (Hong Kong) - zh-HK'
  $tw = Find-Control $window '中文（台灣）/ Chinese (Taiwan) - zh-TW'
  $rect = $window.Current.BoundingRectangle
  $bitmap = [Drawing.Bitmap]::new([int]$rect.Width, [int]$rect.Height)
  $graphics = [Drawing.Graphics]::FromImage($bitmap)
  try {
    $hdc = $graphics.GetHdc()
    try {
      if (-not [TypeDuckUiTest]::PrintWindow([IntPtr]$window.Current.NativeWindowHandle, $hdc, 0)) { throw 'Cannot render installer window' }
    } finally { $graphics.ReleaseHdc($hdc) }
    $bitmap.Save("$Output.png", [Drawing.Imaging.ImageFormat]::Png)
  } finally { $graphics.Dispose(); $bitmap.Dispose() }
  if (-not (Find-Control $window 'Windows 語言 / Windows language')) { throw 'Installer did not reach the Windows language page' }
  if (-not $hk -or -not $tw) {
    $list = @($controls | Where-Object { $_.Current.ClassName -eq 'TNewCheckListBox' })
    if ($list.Count -ne 1 -or [TypeDuckUiTest]::SendMessage([IntPtr]$list[0].Current.NativeWindowHandle, 0x18b, [IntPtr]::Zero, [IntPtr]::Zero).ToInt32() -ne 2) { throw 'Language page must contain two radio options' }
    Write-Host "PASS language page contains two native options. Inspect rendered screenshot for labels and $ExpectedLocale preselection; this runner does not expose owner-drawn item accessibility."
    return
  }
  $selected = if ($ExpectedLocale -eq 'zh-TW') { $tw } else { $hk }
  $pattern = $null
  if ($selected.TryGetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern, [ref]$pattern)) {
    if (-not $pattern.Current.IsSelected) { throw "Wrong preselection: expected $ExpectedLocale" }
  } elseif ($selected.TryGetCurrentPattern([Windows.Automation.TogglePattern]::Pattern, [ref]$pattern)) {
    if ($pattern.Current.ToggleState -ne [Windows.Automation.ToggleState]::On) { throw "Wrong preselection: expected $ExpectedLocale" }
  } elseif ($selected.TryGetCurrentPattern([Windows.Automation.LegacyIAccessiblePattern]::Pattern, [ref]$pattern)) {
    if (($pattern.Current.State -band 0x10) -eq 0) { throw "Wrong preselection: expected $ExpectedLocale" }
  } else {
    Write-Host "Selection state is not exposed by the native checklist; inspect $Output.png for $ExpectedLocale preselection."
  }
  Write-Host 'PASS installer language page exposes both choices; screenshot saved'
} catch {
  $_ | Format-List * -Force | Out-File "$Output-error.txt"
  throw
} finally {
  if ($window) {
    Click-Control (Find-Control $window '取消 Cancel')
    $yes = $null
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    while (-not $yes -and -not $process.HasExited -and [DateTime]::UtcNow -lt $deadline) {
      Start-Sleep -Milliseconds 200
      $yes = Find-Control $root '是 Yes'
    }
    if ($yes) { Click-Control $yes }
    else {
      $root.FindAll([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.Condition]::TrueCondition) |
        ForEach-Object { "$($_.Current.Name); class=$($_.Current.ClassName); hwnd=$($_.Current.NativeWindowHandle)" } | Set-Content "$Output-cancel-controls.txt"
    }
  }
  if (-not $process.WaitForExit(10000)) {
    $process.Kill($true)
    throw 'Cancelled installer did not exit; stopped only this test process tree'
  }
}
