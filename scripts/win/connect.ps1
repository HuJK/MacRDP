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

# Session size: full screen at the console's real pixel size, the way a user
# connects; connect.json may ask for {"mode": "window", "width", "height"}.
# Dynamic resolution on, so window and full-screen switches resize the
# session (DISP). authentication level 0: MacRDP's certificate is self-signed.
# audiocapturemode 1 ("Record from this computer") redirects the default
# recording device; without it mstsc refuses MacRDP's AUDIN channel.
Add-Type -AssemblyName System.Windows.Forms
Add-Type -TypeDefinition 'using System.Runtime.InteropServices; public static class Dpi { [DllImport("user32.dll")] public static extern bool SetProcessDPIAware(); }'
[Dpi]::SetProcessDPIAware() | Out-Null
$screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$full = $cfg.mode -ne 'window'
$width = if ($cfg.width) { $cfg.width } else { $screen.Width }
$height = if ($cfg.height) { $cfg.height } else { $screen.Height }
@(
  "username:s:$($cfg.user)",
  "prompt for credentials:i:0",
  "authentication level:i:0",
  "screen mode id:i:$(if ($full) { 2 } else { 1 })",
  "desktopwidth:i:$width",
  "desktopheight:i:$height",
  "dynamic resolution:i:1",
  "smart sizing:i:0",
  "session bpp:i:32",
  "audiomode:i:0",
  "audiocapturemode:i:1",
  "redirectclipboard:i:1",
  "connection type:i:7",
  "networkautodetect:i:1",
  "bandwidthautodetect:i:1"
) | Out-File -Encoding ascii $default
Start-Process mstsc.exe -ArgumentList "/v:$($cfg.host)"
