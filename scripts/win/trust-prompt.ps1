# Answer mstsc's "Do you trust this remote connection?" prompt, shown before
# it redirects local devices such as the microphone: tick "Don't ask me
# again for connections to this computer" (so later sessions skip it) and
# press Connect. The dialog ignores UI Automation's Invoke, so this only
# uses UI Automation to find the controls and clicks them with real mouse
# input. Runs in the desktop session (through session-run.ps1); exits 1 when
# there is no prompt. Logs to trust-prompt.txt.
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$log = Join-Path $dir 'trust-prompt.txt'
Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class M {
  [StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT { public int dx, dy; public uint data, flags, time; public IntPtr extra; }
  [StructLayout(LayoutKind.Explicit)] public struct INPUT { [FieldOffset(0)] public uint type; [FieldOffset(8)] public MOUSEINPUT mi; }
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] static extern uint SendInput(uint n, INPUT[] i, int s);
  [DllImport("user32.dll")] static extern int GetSystemMetrics(int i);
  [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] static extern bool BringWindowToTop(IntPtr h);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, IntPtr pid);
  [DllImport("user32.dll")] static extern bool AttachThreadInput(uint a, uint b, bool attach);
  [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
  // Windows only lets the foreground thread hand focus over; borrow its queue.
  public static void Focus(IntPtr h) {
    uint me = GetCurrentThreadId(), them = GetWindowThreadProcessId(GetForegroundWindow(), IntPtr.Zero);
    AttachThreadInput(me, them, true);
    BringWindowToTop(h); SetForegroundWindow(h);
    AttachThreadInput(me, them, false);
  }
  public static void Click(int x, int y) {
    foreach (uint f in new uint[] { 0x8001, 0x8003, 0x8005 }) {   // absolute move, +left down, +left up
      INPUT i = new INPUT { type = 0 };
      i.mi.dx = (int)(x * 65535L / (GetSystemMetrics(0) - 1));
      i.mi.dy = (int)(y * 65535L / (GetSystemMetrics(1) - 1));
      i.mi.flags = f;
      SendInput(1, new[] { i }, Marshal.SizeOf(typeof(INPUT)));
      System.Threading.Thread.Sleep(60);
    }
  }
}
'@
[M]::SetProcessDPIAware() | Out-Null   # before UI Automation, so its rectangles are in pixels
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$AE = [Windows.Automation.AutomationElement]
$byName = { param($n) New-Object Windows.Automation.PropertyCondition($AE::NameProperty, $n) }
$dialog = $AE::RootElement.FindFirst([Windows.Automation.TreeScope]::Children,
  (& $byName 'Remote Desktop Connection security warning'))
if (-not $dialog) { 'no prompt' | Out-File -Encoding ascii $log; exit 1 }

$all = $dialog.FindAll([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.Condition]::TrueCondition)
$box = $all | Where-Object { $_.Current.Name -like "Don't ask me again*" } | Select-Object -First 1
$connect = $dialog.FindFirst([Windows.Automation.TreeScope]::Descendants, (& $byName 'Connect'))
if (-not $box -or -not $connect) { 'prompt without the expected controls' | Out-File -Encoding ascii $log; exit 1 }

[M]::Focus([IntPtr]$dialog.Current.NativeWindowHandle)
Start-Sleep -Milliseconds 300
foreach ($el in $box, $connect) {
  $r = $el.Current.BoundingRectangle
  [M]::Click([int]($r.X + $r.Width / 2), [int]($r.Y + $r.Height / 2))
  Start-Sleep -Milliseconds 300
}
'answered: remember + Connect' | Out-File -Encoding ascii $log
