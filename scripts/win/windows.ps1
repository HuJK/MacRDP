# List top-level windows with a title (process, pid, title) to windows.txt
# next to this script. Runs in the desktop session (through session-run.ps1).
Get-Process | Where-Object MainWindowTitle | Select-Object Id, ProcessName, MainWindowTitle |
  Format-Table -AutoSize | Out-String -Width 200 |
  Out-File -Encoding ascii (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'windows.txt')
