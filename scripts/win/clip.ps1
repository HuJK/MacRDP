# Read or write the Windows clipboard. Runs in the desktop session (through
# session-run.ps1; PowerShell 5.1 is STA there, as WinForms' Clipboard needs).
# Reads clip.json next to this script; logs to clip.txt:
#   {"op": "types"}                          formats on the clipboard
#   {"op": "get-text"} / {"op": "set-text", "text": "..."}   (get-text's first
#     line is the text's UTF-8 SHA-256, as SSH output may mangle non-ASCII)
#   {"op": "get-image", "path": "x.png"} / {"op": "set-image", "path": "x.png"}
#   {"op": "set-files", "paths": ["C:\\a.txt", "C:\\dir"]}
#   {"op": "paste-files", "dir": "C:\\dest", "timeout": 60}
#   {"op": "first-content"}                  size and SHA-256 of FileContents[0]
# paste-files pastes into a folder through the Shell, the way Explorer's
# Paste does, which is what pulls the RDP server's (virtual) files over;
# it then waits until the folder's contents stop changing. It pumps window
# messages while waiting: mstsc's data object is asynchronous, and the
# Shell's background copy calls back into this STA thread.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$req = Get-Content (Join-Path $dir 'clip.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$out = Join-Path $dir 'clip.txt'
$C = [System.Windows.Forms.Clipboard]

function Snapshot($path) {
  (Get-ChildItem $path -Recurse -Force -ErrorAction SilentlyContinue |
    ForEach-Object { "$($_.FullName)|$($_.Length)" }) -join ';'
}

try {
  switch ($req.op) {
    'types'     { $result = $C::GetDataObject().GetFormats() -join "`n" }
    'get-text'  {
      $t = $C::GetText()
      $sha = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($t))).Replace('-', '').ToLower()
      $result = "utf8-sha256=$sha`n$t"
    }
    'set-text'  { $C::SetText([string]$req.text); $result = 'ok' }
    'get-image' {
      $img = $C::GetImage()
      if (-not $img) { throw 'no image on the clipboard' }
      $img.Save($req.path, [System.Drawing.Imaging.ImageFormat]::Png)
      $result = "$($img.Width)x$($img.Height)"
    }
    'set-image' { $C::SetImage([System.Drawing.Image]::FromFile($req.path)); $result = 'ok' }
    'set-files' {
      $list = New-Object System.Collections.Specialized.StringCollection
      foreach ($p in $req.paths) { [void]$list.Add($p) }
      $C::SetFileDropList($list); $result = 'ok'
    }
    'paste-files' {
      New-Item -ItemType Directory -Force $req.dir | Out-Null
      (New-Object -ComObject Shell.Application).NameSpace($req.dir).Self.InvokeVerb('paste')
      $deadline = (Get-Date).AddSeconds($(if ($req.timeout) { $req.timeout } else { 60 }))
      $last = ''; $stable = 0
      while ((Get-Date) -lt $deadline -and $stable -lt 6) {
        for ($i = 0; $i -lt 10; $i++) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 50 }
        $now = Snapshot $req.dir
        if ($now -and $now -eq $last) { $stable++ } else { $stable = 0 }
        $last = $now
      }
      $result = (Get-ChildItem $req.dir -Recurse -File | ForEach-Object {
        "$($_.FullName.Substring($req.dir.Length + 1))|$($_.Length)|$((Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLower())"
      }) -join "`n"
    }
    'first-content' {
      $ms = $C::GetData('FileContents')
      if (-not $ms) { throw 'no FileContents on the clipboard' }
      $bytes = $ms.ToArray()
      $sha = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($bytes)).Replace('-', '').ToLower()
      $result = "$($bytes.Length)|$sha"
    }
    default { throw "unknown op $($req.op)" }
  }
  $result | Out-File -Encoding utf8 $out
} catch {
  "error: $($_.Exception.Message)" | Out-File -Encoding utf8 $out
}
