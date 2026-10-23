# Start mstsc against a MacRDP host. Runs in the desktop session (through
# session-run.ps1). Reads connect.json ({"host", "user", "password"}) next to
# this script and deletes it right away, saves the login for mstsc with
# cmdkey (cleanup.ps1 removes it) and launches mstsc.
#
# mstsc /v rather than opening a .rdp file: mstsc shows an "Unknown remote
# connection" warning before every unsigned .rdp file, and that dialog
# ignores UI Automation clicks. /v takes its settings from the user's
# Documents\Default.rdp instead, so ours go there (the original is backed up
# once to Default.rdp.orig next to this script).
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$cfgPath = Join-Path $dir 'connect.json'
$cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
Remove-Item $cfgPath
cmdkey "/generic:TERMSRV/$($cfg.host)" "/user:$($cfg.user)" "/pass:$($cfg.password)" | Out-Null

$default = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Default.rdp'
$backup = Join-Path $dir 'Default.rdp.orig'
if (Test-Path $default) {
  if (-not (Test-Path $backup)) { Copy-Item $default $backup -Force }
  (Get-Item $default -Force).Attributes = 'Normal'   # mstsc keeps it hidden
}

# authentication level 0: MacRDP's certificate is self-signed. 1200x700 keeps
# the whole mstsc window on a 1280x800 console for screenshots.
@(
  "username:s:$($cfg.user)",
  "prompt for credentials:i:0",
  "authentication level:i:0",
  "screen mode id:i:1",
  "desktopwidth:i:1200",
  "desktopheight:i:700",
  "session bpp:i:32",
  "audiomode:i:0",
  "redirectclipboard:i:1",
  "connection type:i:7",
  "networkautodetect:i:1",
  "bandwidthautodetect:i:1"
) | Out-File -Encoding ascii $default
Start-Process mstsc.exe -ArgumentList "/v:$($cfg.host)"
