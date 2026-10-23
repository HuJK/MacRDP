# Paste the clipboard into a folder the way a user does: open it in
# Explorer and paste (the file view's own Paste command, which Ctrl+V and
# the context menu run; posted to it, as a full-screen mstsc keeps the
# keyboard focus). Runs in the desktop session (through
# session-run.ps1). Reads explorer-paste.json ({"dir", "timeout"}) next to
# this script, waits until the folder stops changing, closes the window and
# writes "relative\path|size|sha256" lines to explorer-paste.txt.
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$req = Get-Content (Join-Path $dir 'explorer-paste.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$dest = $req.dir
New-Item -ItemType Directory -Force $dest | Out-Null
Add-Type -TypeDefinition @'
using System; using System.Text; using System.Runtime.InteropServices;
public static class V {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr p, EnumProc f, IntPtr l);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  public static IntPtr Find(IntPtr top, string cls) {
    IntPtr found = IntPtr.Zero;
    EnumChildWindows(top, (h, l) => {
      var sb = new StringBuilder(256); GetClassName(h, sb, 256);
      if (sb.ToString() == cls) { found = h; return false; }
      return true;
    }, IntPtr.Zero);
    return found;
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
$view = if ($window) { [V]::Find([IntPtr]$window.HWND, 'SHELLDLL_DefView') } else { [IntPtr]::Zero }
if ($view -eq [IntPtr]::Zero) {
  "no explorer file view" | Out-File -Encoding utf8 (Join-Path $dir 'explorer-paste.txt'); exit 1
}
[V]::PostMessage($view, 0x0111, [IntPtr]0x7012, [IntPtr]::Zero) | Out-Null   # WM_COMMAND FCIDM_SHVIEW_PASTE

$deadline = (Get-Date).AddSeconds($(if ($req.timeout) { $req.timeout } else { 60 }))
$last = ''; $stable = 0; $idleUntil = (Get-Date).AddSeconds(30)
while ((Get-Date) -lt $deadline -and $stable -lt 6) {
  Start-Sleep -Milliseconds 500
  $now = (Get-ChildItem $dest -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object { "$($_.FullName)|$($_.Length)" }) -join ';'
  if (-not $now -and (Get-Date) -gt $idleUntil) { break }   # the paste never started
  if ($now -and $now -eq $last) { $stable++ } else { $stable = 0 }
  $last = $now
}
if ($window) { $window.Quit() }
(Get-ChildItem $dest -Recurse -File | ForEach-Object {
  "$($_.FullName.Substring($dest.Length + 1))|$($_.Length)|$((Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLower())"
}) -join "`n" | Out-File -Encoding utf8 (Join-Path $dir 'explorer-paste.txt')
