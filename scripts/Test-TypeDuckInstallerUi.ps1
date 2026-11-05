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
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hwnd, int command);
}
'@
function Find-Control($Root, [string]$Name) {
  $condition = [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::NameProperty, $Name)
  return $Root.FindFirst([Windows.Automation.TreeScope]::Descendants, $condition)
}
function Click-Control($Control) {
  if ($null -eq $Control) { throw 'Expected installer control was not found' }
  $pattern = $Control.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern)
  $pattern.Invoke()
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
  Click-Control (Find-Control $window '下一步 Next >')
  Start-Sleep -Milliseconds 300
  $hk = Find-Control $window '中文（香港）/ Chinese (Hong Kong) - zh-HK'
  $tw = Find-Control $window '中文（台灣）/ Chinese (Taiwan) - zh-TW'
  if (-not $hk -or -not $tw) { throw 'Language page must show both radio options' }
  $selected = if ($ExpectedLocale -eq 'zh-TW') { $tw } else { $hk }
  $legacy = $selected.GetCurrentPattern([Windows.Automation.LegacyIAccessiblePattern]::Pattern)
  if (($legacy.Current.State -band 0x10) -eq 0) { throw "Wrong preselection: expected $ExpectedLocale" }
  $controls = $window.FindAll([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.Condition]::TrueCondition)
  $controls | ForEach-Object { "$($_.Current.ControlType.ProgrammaticName): $($_.Current.Name)" } | Set-Content "$Output.txt"
  $rect = $window.Current.BoundingRectangle
  $bitmap = [Drawing.Bitmap]::new([int]$rect.Width, [int]$rect.Height)
  $graphics = [Drawing.Graphics]::FromImage($bitmap)
  try {
    $graphics.CopyFromScreen([int]$rect.X, [int]$rect.Y, 0, 0, $bitmap.Size)
    $bitmap.Save("$Output.png", [Drawing.Imaging.ImageFormat]::Png)
  } finally { $graphics.Dispose(); $bitmap.Dispose() }
  Write-Host "PASS installer language page rendered; preselected $ExpectedLocale"
} finally {
  if ($window) {
    Click-Control (Find-Control $window '取消 Cancel')
    Start-Sleep -Milliseconds 300
    $yes = Find-Control $root '是 Yes'
    if ($yes) { Click-Control $yes }
  }
  if (-not $process.WaitForExit(10000)) { throw 'Cancelled installer did not exit' }
}
