# Press a button in a top-level window via UI Automation. Reads press.json
# ({"window": "<title substring>" or "process": "<name>", "button": "<name>"})
# next to this script; logs to press.txt.
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$req = Get-Content (Join-Path $dir 'press.json') -Raw | ConvertFrom-Json
$out = Join-Path $dir 'press.txt'
$AE = [System.Windows.Automation.AutomationElement]
$wins = $AE::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)
$hit = $false
foreach ($w in $wins) {
  if ($req.process) {
    if ((Get-Process -Id $w.Current.ProcessId -ErrorAction SilentlyContinue).ProcessName -ne $req.process) { continue }
  } elseif ($w.Current.Name -notlike "*$($req.window)*") { continue }
  $cond = New-Object System.Windows.Automation.PropertyCondition($AE::NameProperty, $req.button)
  $btn = $w.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $cond)
  if ($btn) {
    $btn.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    "pressed '$($req.button)' in '$($w.Current.Name)'" | Out-File -Encoding ascii $out
    $hit = $true; break
  }
}
if (-not $hit) { "no '$($req.button)' found; windows: " + (($wins | ForEach-Object { "$($_.Current.Name) [pid $($_.Current.ProcessId)]" }) -join ' | ') | Out-File -Encoding ascii $out }
