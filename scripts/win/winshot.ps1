# Screen size, mstsc window state, and a PrintWindow capture of mstsc
# (works even when CopyFromScreen of the desktop comes back blank). A
# minimized mstsc is restored without activation for the capture, so the
# client renders, then minimized again.
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
public static class W {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint flags);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
}
'@
[W]::SetProcessDPIAware() | Out-Null
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$log = @("screen=" + [System.Windows.Forms.SystemInformation]::VirtualScreen)
$p = Get-Process mstsc -ErrorAction SilentlyContinue | Where-Object MainWindowHandle -ne 0 | Select-Object -First 1
if ($p) {
  $wasMin = [W]::IsIconic($p.MainWindowHandle)
  if ($wasMin) { [W]::ShowWindow($p.MainWindowHandle, 4) | Out-Null; Start-Sleep 4 }  # SW_SHOWNOACTIVATE
  $r = New-Object W+RECT; [W]::GetWindowRect($p.MainWindowHandle, [ref]$r) | Out-Null
  $w = $r.R - $r.L; $h = $r.B - $r.T
  $log += "mstsc pid=$($p.Id) title='$($p.MainWindowTitle)' rect=$($r.L),$($r.T) ${w}x${h} wasMinimized=$wasMin"
  $bmp = New-Object System.Drawing.Bitmap $w, $h
  $g = [System.Drawing.Graphics]::FromImage($bmp); $dc = $g.GetHdc()
  $ok = [W]::PrintWindow($p.MainWindowHandle, $dc, 2); $g.ReleaseHdc($dc)
  $bmp.Save((Join-Path $dir 'mstsc.png'), [System.Drawing.Imaging.ImageFormat]::Png)
  $log += "printwindow=$ok"
  if ($wasMin) { [W]::ShowWindow($p.MainWindowHandle, 7) | Out-Null; $log += "re-minimized" }  # SW_SHOWMINNOACTIVE
} else { $log += "no mstsc window" }
$log | Out-File -Encoding ascii (Join-Path $dir 'winshot.txt')
