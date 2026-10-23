# Remove every saved mstsc login (TERMSRV/* in Credential Manager). Runs in
# the desktop session: an SSH key logon has no access to the user's vault.
$targets = cmdkey /list | Select-String 'Target:.*(TERMSRV/\S+)' | ForEach-Object { $_.Matches[0].Groups[1].Value }
foreach ($t in $targets) { cmdkey "/delete:$t" | Out-Null }
"removed: $($targets -join ', ')" | Out-File -Encoding ascii (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'cleanup.txt')
