// ClickLatency — client half of the click-to-photon measurement: how long a
// click inside mstsc takes to change the remote picture, on this machine's
// clock alone (no clock sync needed).
//
//   ClickLatency.exe <out.txt> <trials> <click-x> <click-y> <probe-x> <probe-y> [gap-ms]
//
// Pairs with `guestcheck flash` on the Mac, whose centre square flips between
// near-black and near-white on every mouse-down. Each trial reads the probe
// pixel, sends a left click at (click-x, click-y) with SendInput, and polls
// the probe (GetPixel on the screen DC, i.e. what DWM composed) until its
// brightness moves by more than 100 of 255. That covers the client's input
// path, the network both ways, the Mac app reacting and redrawing, capture,
// encode, decode and the client's compositing; not the monitor's scan-out.
// Coordinates are screen pixels; run mstsc full screen. Each click goes out
// only if the window under (click-x, click-y) is mstsc's. Trials are spaced
// <gap-ms> (default 500) plus up to 200 ms of jitter, so they don't lock to
// the frame clock.
//
// Writes one latency (ms, or "timeout") per line to <out.txt> and prints:
// trials, timeouts, median, p10, p90, min, max, and the mean time per probe
// read (the measurement's resolution; a latency is the read's midpoint).
//
// Runs in the desktop session (scripts/win/clicklat.ps1), built on the client
// with scripts/win-client.sh build.

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;

static class ClickLatency
{
    [StructLayout(LayoutKind.Sequential)]
    struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)]
    struct INPUT { public uint type; public MOUSEINPUT mi; }

    [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] static extern uint SendInput(uint n, INPUT[] inputs, int size);
    [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr hwnd);
    [DllImport("gdi32.dll")] static extern uint GetPixel(IntPtr dc, int x, int y);
    [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }
    [DllImport("user32.dll")] static extern IntPtr WindowFromPoint(POINT p);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);

    static bool MstscAt(int x, int y)
    {
        var p = new POINT(); p.X = x; p.Y = y;
        uint pid;
        GetWindowThreadProcessId(WindowFromPoint(p), out pid);
        try { return Process.GetProcessById((int)pid).ProcessName == "mstsc"; }
        catch (ArgumentException) { return false; }
    }

    const uint LeftDown = 0x0002, LeftUp = 0x0004, Invalid = 0xFFFFFFFF;

    static int Luma(uint c)
    {
        int r = (int)(c & 0xFF), g = (int)((c >> 8) & 0xFF), b = (int)((c >> 16) & 0xFF);
        return (r * 299 + g * 587 + b * 114) / 1000;
    }

    static INPUT[] Click(uint flags)
    {
        var i = new INPUT();
        i.type = 0; // INPUT_MOUSE
        i.mi.dwFlags = flags;
        return new INPUT[] { i };
    }

    static double Pct(List<double> sorted, double p)
    {
        return sorted[Math.Min(sorted.Count - 1, (int)Math.Round(p * (sorted.Count - 1)))];
    }

    static int Main(string[] args)
    {
        if (args.Length < 6 || args.Length > 7)
        {
            Console.Error.WriteLine("usage: ClickLatency <out.txt> <trials> <click-x> <click-y> <probe-x> <probe-y> [gap-ms]");
            return 2;
        }
        int trials = int.Parse(args[1]);
        int cx = int.Parse(args[2]), cy = int.Parse(args[3]);
        int px = int.Parse(args[4]), py = int.Parse(args[5]);
        int gap = args.Length == 7 ? int.Parse(args[6]) : 500;
        SetProcessDPIAware();
        IntPtr dc = GetDC(IntPtr.Zero);
        int size = Marshal.SizeOf(typeof(INPUT));
        INPUT[] down = Click(LeftDown), up = Click(LeftUp);
        var rng = new Random(1);
        var sw = Stopwatch.StartNew();
        var lat = new List<double>();
        int timeouts = 0;
        long reads = 0;
        double readMs = 0;

        SetCursorPos(cx, cy);
        Thread.Sleep(500);
        using (var w = new StreamWriter(args[0]))
        {
            for (int t = 0; t < trials; t++)
            {
                if (!MstscAt(cx, cy)) { Console.Error.WriteLine("not clicking: mstsc isn't the window at the click point"); return 1; }
                uint c0 = GetPixel(dc, px, py);
                if (c0 == Invalid) { Console.Error.WriteLine("GetPixel failed"); return 1; }
                int before = Luma(c0);
                double t0 = sw.Elapsed.TotalMilliseconds;
                SendInput(1, down, size);
                SendInput(1, up, size);
                double hit = -1;
                while (sw.Elapsed.TotalMilliseconds - t0 < 2000)
                {
                    double r0 = sw.Elapsed.TotalMilliseconds;
                    uint c = GetPixel(dc, px, py);
                    double r1 = sw.Elapsed.TotalMilliseconds;
                    reads++;
                    readMs += r1 - r0;
                    if (c != Invalid && Math.Abs(Luma(c) - before) > 100) { hit = (r0 + r1) / 2 - t0; break; }
                }
                if (hit < 0) { timeouts++; w.WriteLine("timeout"); }
                else { lat.Add(hit); w.WriteLine(hit.ToString("F1")); }
                Thread.Sleep(gap + rng.Next(0, 200));
            }
        }

        lat.Sort();
        if (lat.Count == 0) { Console.WriteLine("trials={0} timeouts={1}", trials, timeouts); return 1; }
        Console.WriteLine("trials={0} timeouts={1} median={2:F1} p10={3:F1} p90={4:F1} min={5:F1} max={6:F1} read_ms={7:F2}",
                          trials, timeouts, Pct(lat, 0.5), Pct(lat, 0.1), Pct(lat, 0.9),
                          lat[0], lat[lat.Count - 1], readMs / Math.Max(1, reads));
        return 0;
    }
}
