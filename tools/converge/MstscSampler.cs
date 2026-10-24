// MstscSampler — client half of the picture-convergence check: what mstsc
// shows, sampled over time.
//
//   MstscSampler.exe <out.gz> <seconds> <interval-ms> <stop-file>
//
// Captures mstsc's window (PrintWindow with PW_RENDERFULLCONTENT, like
// scripts/win/winshot.ps1, so it works where CopyFromScreen comes back blank)
// every <interval-ms> until <seconds> pass or <stop-file> appears, and keeps
// each frame as the mean colour of every 8x8 block of the client area: small
// enough to sample the whole run, fine enough to compare 64 px tiles.
//
// <out.gz> is gzip of: "MRDS", int32 blocksWide, int32 blocksHigh, then per
// frame int64 unix ms (this machine's clock) and blocksWide*blocksHigh*3
// bytes, rows top-down, R G B. imgcmp converge (tools/imgcmp) reads it.
// Prints the frame count and the mean time per capture.
//
// Runs in the desktop session (scripts/win/sampler.ps1), built on the client
// with scripts/win-client.sh build.

using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.IO.Compression;
using System.Runtime.InteropServices;
using System.Threading;

static class MstscSampler
{
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int L, T, R, B; }
    [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }
    [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr h, ref POINT p);
    [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr h, IntPtr dc, uint flags);

    const int Block = 8;

    static int Main(string[] args)
    {
        if (args.Length != 4) { Console.Error.WriteLine("usage: MstscSampler <out.gz> <seconds> <interval-ms> <stop-file>"); return 2; }
        double seconds = double.Parse(args[1]);
        int interval = int.Parse(args[2]);
        string stop = args[3];
        SetProcessDPIAware();

        IntPtr hwnd = IntPtr.Zero;
        foreach (Process p in Process.GetProcessesByName("mstsc"))
            if (p.MainWindowHandle != IntPtr.Zero) { hwnd = p.MainWindowHandle; break; }
        if (hwnd == IntPtr.Zero) { Console.Error.WriteLine("no mstsc window"); return 1; }

        RECT wr, cr; GetWindowRect(hwnd, out wr); GetClientRect(hwnd, out cr);
        POINT org = new POINT(); ClientToScreen(hwnd, ref org);
        int ww = wr.R - wr.L, wh = wr.B - wr.T;
        int ox = org.X - wr.L, oy = org.Y - wr.T;
        int bw = cr.R / Block, bh = cr.B / Block;
        var bmp = new Bitmap(ww, wh, PixelFormat.Format32bppArgb);
        var row = new byte[ww * 4];
        var means = new byte[bw * bh * 3];
        var sums = new int[bw * 3];

        int frames = 0; double captureMs = 0;
        using (var fs = File.Create(args[0]))
        using (var gz = new GZipStream(fs, CompressionMode.Compress))
        using (var w = new BinaryWriter(gz))
        {
            w.Write(new[] { (byte)'M', (byte)'R', (byte)'D', (byte)'S' });
            w.Write(bw); w.Write(bh);
            var clock = Stopwatch.StartNew();
            long next = 0;
            while (clock.ElapsedMilliseconds < seconds * 1000 && !File.Exists(stop))
            {
                long t = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
                long c0 = clock.ElapsedMilliseconds;
                using (var g = Graphics.FromImage(bmp))
                {
                    IntPtr dc = g.GetHdc();
                    PrintWindow(hwnd, dc, 2);   // PW_RENDERFULLCONTENT
                    g.ReleaseHdc(dc);
                }
                BitmapData d = bmp.LockBits(new Rectangle(0, 0, ww, wh), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
                for (int by = 0; by < bh; by++)
                {
                    Array.Clear(sums, 0, sums.Length);
                    for (int y = 0; y < Block; y++)
                    {
                        Marshal.Copy(d.Scan0 + (oy + by * Block + y) * d.Stride, row, 0, ww * 4);
                        for (int bx = 0; bx < bw; bx++)
                            for (int x = 0; x < Block; x++)
                            {
                                int i = (ox + bx * Block + x) * 4;   // B G R A
                                sums[bx * 3] += row[i + 2]; sums[bx * 3 + 1] += row[i + 1]; sums[bx * 3 + 2] += row[i];
                            }
                    }
                    for (int k = 0; k < bw * 3; k++) means[by * bw * 3 + k] = (byte)(sums[k] / (Block * Block));
                }
                bmp.UnlockBits(d);
                captureMs += clock.ElapsedMilliseconds - c0;
                w.Write(t); w.Write(means);
                frames++;
                next += interval;
                long wait = next - clock.ElapsedMilliseconds;
                if (wait > 0) Thread.Sleep((int)wait); else next = clock.ElapsedMilliseconds;
            }
        }
        Console.WriteLine("frames={0} blocks={1}x{2} capture_ms={3:F1}", frames, bw, bh, frames > 0 ? captureMs / frames : 0);
        return 0;
    }
}
