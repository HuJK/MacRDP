# Send real input into the mstsc window. Runs in the desktop session
# (through session-run.ps1). Reads input.json next to this script; every
# field is optional and applied in this order:
#   {"toggleFullscreen": true,          Ctrl+Alt+Break (mstsc's own shortcut)
#    "maximize": true,                  maximize the (windowed) mstsc window
#    "resizeClient": [w, h],            un-maximize, then size the client area to w x h
#    "move": [x, y],                    in mstsc client-area pixels
#    "click": true, "rightClick": true,
#    "wheel": n,                        n notches, positive = away from the user
#    "text": "echo hi",                 as scancodes, like a physical keyboard
#    "unicode": "中文",                 as KEYEVENTF_UNICODE (mstsc sends TS_UNICODE_EVENT)
#    "enter": true,
#    "cursor": true}                    report the cursor shape mstsc shows
# Logs to input.txt: focus, client geometry, and what was done.
$ErrorActionPreference = 'Stop'
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$req = Get-Content (Join-Path $dir 'input.json') -Raw -Encoding UTF8 | ConvertFrom-Json
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class In {
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT { public int dx, dy; public uint data, flags, time; public IntPtr extra; }
  [StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT { public ushort vk, scan; public uint flags, time; public IntPtr extra; }
  [StructLayout(LayoutKind.Explicit)] public struct INPUT {
    [FieldOffset(0)] public uint type;
    [FieldOffset(8)] public MOUSEINPUT mi;
    [FieldOffset(8)] public KEYBDINPUT ki;
  }
  [StructLayout(LayoutKind.Sequential)] public struct CURSORINFO { public int size, flags; public IntPtr hCursor; public POINT pos; }
  [StructLayout(LayoutKind.Sequential)] public struct ICONINFO { public bool fIcon; public int xHotspot, yHotspot; public IntPtr hbmMask, hbmColor; }
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern uint SendInput(uint n, INPUT[] inputs, int size);
  [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int hh, uint flags);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, IntPtr pid);
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool attach);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")] public static extern short VkKeyScan(char c);
  [DllImport("user32.dll")] public static extern uint MapVirtualKey(uint code, uint type);
  [DllImport("user32.dll")] public static extern int GetSystemMetrics(int i);
  [DllImport("user32.dll")] public static extern bool GetCursorInfo(ref CURSORINFO ci);
  [DllImport("user32.dll")] public static extern bool GetIconInfo(IntPtr h, out ICONINFO ii);

  const uint MOVE = 0x1, LDOWN = 0x2, LUP = 0x4, RDOWN = 0x8, RUP = 0x10, WHEEL = 0x800, ABSOLUTE = 0x8000, VIRTUALDESK = 0x4000;
  const uint KEYUP = 0x2, UNICODE = 0x4, SCANCODE = 0x8;

  static void Send(INPUT i) { SendInput(1, new[] { i }, Marshal.SizeOf(typeof(INPUT))); }

  // Windows only lets the foreground thread hand focus over; borrow its input queue.
  public static void Focus(IntPtr h) {
    if (IsIconic(h)) ShowWindow(h, 9);   // SW_RESTORE
    IntPtr fg = GetForegroundWindow();
    if (fg == h) return;
    uint me = GetCurrentThreadId(), them = GetWindowThreadProcessId(fg, IntPtr.Zero);
    AttachThreadInput(me, them, true);
    BringWindowToTop(h); SetForegroundWindow(h);
    AttachThreadInput(me, them, false);
  }
  public static void MoveTo(int x, int y) {
    int vx = GetSystemMetrics(76), vy = GetSystemMetrics(77), vw = GetSystemMetrics(78), vh = GetSystemMetrics(79);
    INPUT i = new INPUT { type = 0 };
    i.mi.dx = (int)((x - vx) * 65535L / (vw - 1));
    i.mi.dy = (int)((y - vy) * 65535L / (vh - 1));
    i.mi.flags = MOVE | ABSOLUTE | VIRTUALDESK;
    Send(i);
  }
  public static void Button(bool right) {
    INPUT i = new INPUT { type = 0 };
    i.mi.flags = right ? RDOWN : LDOWN; Send(i);
    i.mi.flags = right ? RUP : LUP; Send(i);
  }
  public static void Wheel(int notches) {
    INPUT i = new INPUT { type = 0 };
    i.mi.flags = WHEEL; i.mi.data = unchecked((uint)(notches * 120));
    Send(i);
  }
  public static void Scan(ushort scan, bool up) {
    INPUT i = new INPUT { type = 1 };
    i.ki.scan = scan; i.ki.flags = SCANCODE | (up ? KEYUP : 0);
    Send(i);
  }
  public static void Vk(ushort vk, bool up) {
    INPUT i = new INPUT { type = 1 };
    i.ki.vk = vk; i.ki.flags = up ? KEYUP : 0;
    Send(i);
  }
  public static void Type(string s) {
    foreach (char c in s) {
      short r = VkKeyScan(c);
      ushort scan = (ushort)MapVirtualKey((uint)(r & 0xFF), 0);
      bool shift = (r & 0x100) != 0;
      if (shift) Scan(0x2A, false);
      Scan(scan, false); Scan(scan, true);
      if (shift) Scan(0x2A, true);
      System.Threading.Thread.Sleep(15);
    }
  }
  public static void TypeUnicode(string s) {
    foreach (char c in s) {
      INPUT i = new INPUT { type = 1 };
      i.ki.scan = c; i.ki.flags = UNICODE; Send(i);
      i.ki.flags = UNICODE | KEYUP; Send(i);
      System.Threading.Thread.Sleep(15);
    }
  }
}
'@
[In]::SetProcessDPIAware() | Out-Null
$log = @()
function Report { $log | Out-File -Encoding ascii (Join-Path $dir 'input.txt') }
$p = Get-Process mstsc -ErrorAction SilentlyContinue | Where-Object MainWindowHandle -ne 0 | Select-Object -First 1
if (-not $p) { $log += 'no mstsc window'; Report; exit 1 }
$h = $p.MainWindowHandle

function Geometry {
  $o = New-Object In+POINT; [In]::ClientToScreen($h, [ref]$o) | Out-Null
  $c = New-Object In+RECT; [In]::GetClientRect($h, [ref]$c) | Out-Null
  $w = New-Object In+RECT; [In]::GetWindowRect($h, [ref]$w) | Out-Null
  @{ origin = $o; client = $c; window = $w }
}

[In]::Focus($h); Start-Sleep -Milliseconds 300

if ($req.toggleFullscreen) {
  [In]::Vk(0x11, $false); [In]::Vk(0x12, $false); [In]::Vk(0x03, $false)   # Ctrl, Alt, Break (VK_CANCEL)
  [In]::Vk(0x03, $true); [In]::Vk(0x12, $true); [In]::Vk(0x11, $true)
  Start-Sleep -Milliseconds 1500; [In]::Focus($h); $log += 'toggled full screen'
}
if ($req.maximize) {
  [In]::ShowWindow($h, 3) | Out-Null   # SW_MAXIMIZE
  Start-Sleep -Milliseconds 500; $log += 'maximized'
}
if ($req.resizeClient) {
  # A maximized window ignores SetWindowPos; mstsc starts out maximized.
  if ([In]::IsZoomed($h)) { [In]::ShowWindow($h, 9) | Out-Null; Start-Sleep -Milliseconds 500 }   # SW_RESTORE
  $g = Geometry
  $dw = ($g.window.R - $g.window.L) - $g.client.R; $dh = ($g.window.B - $g.window.T) - $g.client.B
  [In]::SetWindowPos($h, [IntPtr]::Zero, 0, 0, [int]$req.resizeClient[0] + $dw, [int]$req.resizeClient[1] + $dh, 0x16) | Out-Null   # NOMOVE|NOZORDER|NOACTIVATE
  Start-Sleep -Milliseconds 500; $log += "resized client to $($req.resizeClient[0])x$($req.resizeClient[1])"
}
$g = Geometry
$log += "foreground=$([In]::GetForegroundWindow() -eq $h) clientOrigin=$($g.origin.X),$($g.origin.Y) clientSize=$($g.client.R)x$($g.client.B) screen=$([In]::GetSystemMetrics(0))x$([In]::GetSystemMetrics(1))"

if ($req.move) {
  [In]::MoveTo($g.origin.X + [int]$req.move[0], $g.origin.Y + [int]$req.move[1]); Start-Sleep -Milliseconds 300
  $log += "moved to client $($req.move[0]),$($req.move[1])"
}
if ($req.click) { [In]::Button($false); Start-Sleep -Milliseconds 300; $log += 'clicked' }
if ($req.rightClick) { [In]::Button($true); Start-Sleep -Milliseconds 300; $log += 'right-clicked' }
if ($req.wheel) { [In]::Wheel([int]$req.wheel); Start-Sleep -Milliseconds 300; $log += "wheel $($req.wheel)" }
if ($req.text) { [In]::Type([string]$req.text); $log += "typed $($req.text.Length) chars" }
if ($req.unicode) { [In]::TypeUnicode([string]$req.unicode); $log += "typed $($req.unicode.Length) UTF-16 units as Unicode" }
if ($req.enter) { [In]::Scan(0x1C, $false); [In]::Scan(0x1C, $true); $log += 'enter' }
if ($req.cursor) {
  Start-Sleep -Milliseconds 700   # let the server's pointer update land
  $ci = New-Object In+CURSORINFO; $ci.size = [Runtime.InteropServices.Marshal]::SizeOf($ci)
  [In]::GetCursorInfo([ref]$ci) | Out-Null
  $ii = New-Object In+ICONINFO; [In]::GetIconInfo($ci.hCursor, [ref]$ii) | Out-Null
  $bmp = [System.Drawing.Icon]::FromHandle($ci.hCursor).ToBitmap()
  $sb = New-Object System.Text.StringBuilder
  for ($y = 0; $y -lt $bmp.Height; $y++) { for ($x = 0; $x -lt $bmp.Width; $x++) { [void]$sb.Append($bmp.GetPixel($x, $y).ToArgb()) } }
  $md5 = [BitConverter]::ToString([Security.Cryptography.MD5]::Create().ComputeHash([Text.Encoding]::ASCII.GetBytes($sb.ToString()))).Replace('-', '').Substring(0, 12).ToLower()
  $log += "cursor hotspot=$($ii.xHotspot),$($ii.yHotspot) size=$($bmp.Width)x$($bmp.Height) hash=$md5"
}
Report
