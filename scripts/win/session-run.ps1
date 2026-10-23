# Run a .ps1 inside the logged-on user's desktop session (SSH lands in a
# session without a desktop) via an interactive scheduled task, and wait.
param([Parameter(Mandatory)][string]$Script, [int]$TimeoutSec = 60)
$name = "MacRDPTest-" + [IO.Path]::GetFileNameWithoutExtension($Script)
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$Script`""
$principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName $name -Action $action -Principal $principal -Force | Out-Null
Start-ScheduledTask -TaskName $name
$deadline = (Get-Date).AddSeconds($TimeoutSec)
do { Start-Sleep -Milliseconds 500; $t = Get-ScheduledTask -TaskName $name } while ($t.State -eq 'Running' -and (Get-Date) -lt $deadline)
"$name state=$($t.State) result=$((Get-ScheduledTaskInfo -TaskName $name).LastTaskResult)"
