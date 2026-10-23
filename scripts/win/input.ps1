# Send real input into the mstsc window. Runs in the desktop session
# (through session-run.ps1). Reads input.json next to this script:
#   {"move": [x, y], "click": true, "text": "echo hi", "enter": true}
# move is in mstsc client-area pixels (= remote desktop pixels when the
# window isn't scaled). Keys go out as scancodes, like a physical keyboard,
# so mstsc forwards them as scancode events. Logs to input.txt.
$ErrorActionPreference = 'Stop'
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$req = Get-Content (Join-Path $dir 'input.json') -Raw -Encoding UTF8 | ConvertFrom-Json
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
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern uint SendInput(uint n, INPUT[] inputs, int size);
  [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern short VkKeyScan(char c);
  [DllImport("user32.dll")] public static extern uint MapVirtualKey(uint code, uint type);
  [DllImport("user32.dll")] public static extern int GetSystemMetrics(int i);

  const uint MOVE = 0x1, LDOWN = 0x2, LUP = 0x4, ABSOLUTE = 0x8000, VIRTUALDESK = 0x4000;
  const uint KEYUP = 0x2, SCANCODE = 0x8;

  static void Send(INPUT i) { SendInput(1, new[] { i }, Marshal.SizeOf(typeof(INPUT))); }

  public static void MoveTo(int x, int y) {
    int vx = GetSystemMetrics(76), vy = GetSystemMetrics(77), vw = GetSystemMetrics(78), vh = GetSystemMetrics(79);
    INPUT i = new INPUT { type = 0 };
    i.mi.dx = (int)((x - vx) * 65535L / (vw - 1));
    i.mi.dy = (int)((y - vy) * 65535L / (vh - 1));
    i.mi.flags = MOVE | ABSOLUTE | VIRTUALDESK;
    Send(i);
  }
  public static void Click() {
    INPUT i = new INPUT { type = 0 };
    i.mi.flags = LDOWN; Send(i);
    i.mi.flags = LUP; Send(i);
  }
  public static void Scan(ushort scan, bool up) {
    INPUT i = new INPUT { type = 1 };
    i.ki.scan = scan; i.ki.flags = SCANCODE | (up ? KEYUP : 0);
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
}
'@
[In]::SetProcessDPIAware() | Out-Null
$log = @()
$p = Get-Process mstsc | Where-Object MainWindowHandle -ne 0 | Select-Object -First 1
if (-not $p) { 'no mstsc window' | Out-File -Encoding ascii (Join-Path $dir 'input.txt'); exit 1 }
$h = $p.MainWindowHandle
[In]::ShowWindow($h, 9) | Out-Null           # SW_RESTORE
$origin = New-Object In+POINT
[In]::ClientToScreen($h, [ref]$origin) | Out-Null
# A click on the title bar activates mstsc without touching the remote desktop.
[In]::MoveTo($origin.X + 150, $origin.Y - 12); [In]::Click(); Start-Sleep -Milliseconds 300
$cr = New-Object In+RECT; [In]::GetClientRect($h, [ref]$cr) | Out-Null
$log += "foreground=$([In]::GetForegroundWindow() -eq $h) clientOrigin=$($origin.X),$($origin.Y) clientSize=$($cr.R)x$($cr.B) screen=$([In]::GetSystemMetrics(0))x$([In]::GetSystemMetrics(1))"
if ($req.move) {
  [In]::MoveTo($origin.X + [int]$req.move[0], $origin.Y + [int]$req.move[1]); Start-Sleep -Milliseconds 300
  $log += "moved to client $($req.move[0]),$($req.move[1])"
}
if ($req.click) { [In]::Click(); Start-Sleep -Milliseconds 300; $log += 'clicked' }
if ($req.text) { [In]::Type([string]$req.text); $log += "typed $($req.text.Length) chars" }
if ($req.enter) { [In]::Scan(0x1C, $false); [In]::Scan(0x1C, $true); $log += 'enter' }
$log | Out-File -Encoding ascii (Join-Path $dir 'input.txt')
