# Paste the clipboard into a folder the way a user does: open it in
# Explorer and press Ctrl+V. Runs in the desktop session (through
# session-run.ps1). Reads explorer-paste.json ({"dir", "timeout"}) next to
# this script, waits until the folder stops changing, closes the window and
# writes "relative\path|size|sha256" lines to explorer-paste.txt.
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$req = Get-Content (Join-Path $dir 'explorer-paste.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$dest = $req.dir
New-Item -ItemType Directory -Force $dest | Out-Null
Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class K {
  [StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT { public ushort vk, scan; public uint flags, time; public IntPtr extra; }
  [StructLayout(LayoutKind.Explicit)] public struct INPUT { [FieldOffset(0)] public uint type; [FieldOffset(8)] public KEYBDINPUT ki; }
  [DllImport("user32.dll")] static extern uint SendInput(uint n, INPUT[] i, int size);
  public static void Scan(ushort s, bool up) {
    INPUT i = new INPUT { type = 1 }; i.ki.scan = s; i.ki.flags = 0x8u | (up ? 0x2u : 0u);
    SendInput(1, new[] { i }, Marshal.SizeOf(typeof(INPUT)));
  }
}
'@
$shell = New-Object -ComObject Shell.Application
Start-Process explorer.exe $dest
$window = $null
for ($i = 0; $i -lt 20 -and -not $window; $i++) {
  Start-Sleep -Milliseconds 500
  $window = $shell.Windows() | Where-Object { $_.Document.Folder.Self.Path -eq $dest } | Select-Object -First 1
}
Start-Sleep -Milliseconds 800
[K]::Scan(0x1D, $false); [K]::Scan(0x2F, $false); [K]::Scan(0x2F, $true); [K]::Scan(0x1D, $true)   # Ctrl+V

$deadline = (Get-Date).AddSeconds($(if ($req.timeout) { $req.timeout } else { 60 }))
$last = ''; $stable = 0
while ((Get-Date) -lt $deadline -and $stable -lt 6) {
  Start-Sleep -Milliseconds 500
  $now = (Get-ChildItem $dest -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object { "$($_.FullName)|$($_.Length)" }) -join ';'
  if ($now -and $now -eq $last) { $stable++ } else { $stable = 0 }
  $last = $now
}
if ($window) { $window.Quit() }
(Get-ChildItem $dest -Recurse -File | ForEach-Object {
  "$($_.FullName.Substring($dest.Length + 1))|$($_.Length)|$((Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLower())"
}) -join "`n" | Out-File -Encoding utf8 (Join-Path $dir 'explorer-paste.txt')
