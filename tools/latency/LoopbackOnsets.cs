// LoopbackOnsets — client half of the audio-out latency measurement.
//
//   LoopbackOnsets.exe <mac-host> <udp-port> <seconds> <out-dir> [options]
//   LoopbackOnsets.exe --self-play <seconds> <out-dir> [options]
//
// Detects the onsets of latbeep's tone bursts in what this machine plays and
// timestamps them on its wall clock via the packets' QPC positions. The
// capture point is, by default, WASAPI loopback of the default render device
// (what the RDP client hands to the audio engine); --capture <endpoint-id>
// records a capture endpoint instead, e.g. VB-Cable's "CABLE Output", which
// hears whatever is played into "CABLE Input".
//
// With a Mac host, an NTP-style clock exchange with latbeep's UDP port runs
// around the capture, so the host-side analysis can map the Mac's burst
// times onto this clock. --self-play is the local control: it plays
// latbeep's signal itself on the default render device and writes the
// bursts' play times (from IAudioClock) to beeps.csv in latbeep's format,
// so a local run and an RDP run are analysed the same way.
//
// Options: --freq <hz> (burst tone, 1000), --capture <endpoint-id>,
// --interval <s> and --bed <amplitude> (self-play signal; 2 and 0.1).
//
// Writes <out-dir>\onsets.csv (unix_ns,amplitude,freq_hz: the burst's peak
// after the band-pass and its pitch from zero crossings, so level or
// sample-rate errors along the path show up), and sync.csv
// (phase,send_unix_ns,mac_unix_ns,recv_unix_ns) or, with --self-play,
// beeps.csv (index,unix_ns).
//
// Built with the .NET Framework csc.exe that ships with Windows, so C# 5:
//   csc /nologo /optimize /out:LoopbackOnsets.exe LoopbackOnsets.cs

using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Threading;

static class LoopbackOnsets
{
    [DllImport("kernel32.dll")] static extern void GetSystemTimePreciseAsFileTime(out long ft);
    [DllImport("kernel32.dll")] static extern bool QueryPerformanceCounter(out long count);
    [DllImport("kernel32.dll")] static extern bool QueryPerformanceFrequency(out long freq);

    const long UnixEpochFileTime = 116444736000000000L;

    static long NowUnixNs()
    {
        long ft;
        GetSystemTimePreciseAsFileTime(out ft);
        return (ft - UnixEpochFileTime) * 100;
    }

    // QPC in the 100 ns units IAudioCaptureClient reports, without overflowing.
    static long Qpc100ns()
    {
        long c, f;
        QueryPerformanceCounter(out c);
        QueryPerformanceFrequency(out f);
        return c / f * 10000000L + c % f * 10000000L / f;
    }

    // MARK: - WASAPI interop

    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    class MMDeviceEnumerator { }

    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceEnumerator
    {
        int EnumAudioEndpoints(int dataFlow, int stateMask, out IntPtr devices);
        int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice endpoint);
        int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IMMDevice device);
    }

    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDevice
    {
        int Activate(ref Guid iid, int clsCtx, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object iface);
        int OpenPropertyStore(int access, out IntPtr properties);
        int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
        int GetState(out int state);
    }

    [ComImport, Guid("1CB9AD4C-DBFA-4c32-B178-C2F568A703B2"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioClient
    {
        int Initialize(int shareMode, int streamFlags, long bufferDuration, long periodicity, IntPtr format, IntPtr sessionGuid);
        int GetBufferSize(out uint frames);
        int GetStreamLatency(out long latency);
        int GetCurrentPadding(out uint padding);
        int IsFormatSupported(int shareMode, IntPtr format, out IntPtr closest);
        int GetMixFormat(out IntPtr format);
        int GetDevicePeriod(out long defaultPeriod, out long minimumPeriod);
        int Start();
        int Stop();
        int Reset();
        int SetEventHandle(IntPtr handle);
        int GetService(ref Guid iid, [MarshalAs(UnmanagedType.IUnknown)] out object service);
    }

    [ComImport, Guid("C8ADBD64-E71E-48a0-A4DE-185C395CD317"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioCaptureClient
    {
        int GetBuffer(out IntPtr data, out uint frames, out uint flags, out ulong devicePosition, out ulong qpcPosition);
        int ReleaseBuffer(uint frames);
        int GetNextPacketSize(out uint frames);
    }

    [ComImport, Guid("F294ACFC-3146-4483-A7BF-ADDCA7C260E2"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioRenderClient
    {
        int GetBuffer(uint frames, out IntPtr data);
        int ReleaseBuffer(uint frames, uint flags);
    }

    [ComImport, Guid("CD63314F-3FBA-4a1b-812C-EF96358728E7"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioClock
    {
        int GetFrequency(out ulong frequency);
        int GetPosition(out ulong position, out ulong qpcPosition);
        int GetCharacteristics(out uint characteristics);
    }

    const int AUDCLNT_STREAMFLAGS_LOOPBACK = 0x00020000;
    const uint AUDCLNT_BUFFERFLAGS_SILENT = 0x2;
    const uint AUDCLNT_BUFFERFLAGS_TIMESTAMP_ERROR = 0x4;

    static void Check(int hr, string what)
    {
        if (hr < 0) throw new Exception(what + " failed: 0x" + hr.ToString("X8"));
    }

    // A stream on an endpoint plus its mix format.
    class Endpoint
    {
        public IAudioClient Client;
        public string Id;
        public int Channels, Rate, BlockAlign, Bits;
        public bool IsFloat;

        public Endpoint(IMMDevice device, int flags, long bufferDuration)
        {
            device.GetId(out Id);
            Guid iid = typeof(IAudioClient).GUID;
            object o;
            Check(device.Activate(ref iid, 23 /* CLSCTX_ALL */, IntPtr.Zero, out o), "Activate");
            Client = (IAudioClient)o;
            IntPtr fmt;
            Check(Client.GetMixFormat(out fmt), "GetMixFormat");
            int tag = Marshal.ReadInt16(fmt, 0) & 0xFFFF;
            Channels = Marshal.ReadInt16(fmt, 2);
            Rate = Marshal.ReadInt32(fmt, 4);
            BlockAlign = Marshal.ReadInt16(fmt, 12);
            Bits = Marshal.ReadInt16(fmt, 14);
            IsFloat = tag == 3 || (tag == 0xFFFE && Marshal.ReadInt32(fmt, 24) == 3);
            if (!(IsFloat && Bits == 32) && Bits != 16) throw new Exception("unsupported mix format: tag " + tag + ", " + Bits + " bits");
            Check(Client.Initialize(0 /* shared */, flags, bufferDuration, 0, fmt, IntPtr.Zero), "Initialize");
        }

        public T Service<T>()
        {
            Guid iid = typeof(T).GUID;
            object o;
            Check(Client.GetService(ref iid, out o), "GetService");
            return (T)o;
        }

        public string Describe()
        {
            return Id + ": " + Rate + " Hz x" + Channels + ", " + Bits + "-bit " + (IsFloat ? "float" : "pcm");
        }
    }

    // MARK: - Clock exchange

    static void Sync(UdpClient udp, IPEndPoint mac, string phase, int samples, TextWriter w)
    {
        var any = new IPEndPoint(IPAddress.Any, 0);
        for (int i = 0; i < samples; i++)
        {
            byte[] req = BitConverter.GetBytes((long)i);
            long send = NowUnixNs();
            udp.Send(req, req.Length, mac);
            byte[] resp;
            try { resp = udp.Receive(ref any); }
            catch (SocketException) { continue; }
            long recv = NowUnixNs();
            if (resp.Length < 16 || BitConverter.ToInt64(resp, 0) != i) continue;
            long macNs = 0;
            for (int b = 8; b < 16; b++) macNs = (macNs << 8) | resp[b];
            w.WriteLine(phase + "," + send + "," + macNs + "," + recv);
            Thread.Sleep(20);
        }
    }

    // MARK: - Signal and onset detection

    // latbeep's signal: 1 s of lead-in, then a 5 ms-ramped burst every
    // interval over an optional continuous 440 Hz bed.
    static double Signal(long frame, int rate, double freq, double interval, double bed)
    {
        double v = bed * Math.Sin(2 * Math.PI * 440 * frame / rate);
        long rel = frame - rate, intervalFrames = (long)(interval * rate), burst = rate * 40 / 1000, ramp = rate * 5 / 1000;
        if (rel >= 0)
        {
            long off = rel % intervalFrames;
            if (off < burst)
            {
                long edge = Math.Min(off, burst - 1 - off);
                double env = edge < ramp ? 0.5 - 0.5 * Math.Cos(Math.PI * edge / ramp) : 1;
                v += 0.5 * env * Math.Sin(2 * Math.PI * freq * off / rate);
            }
        }
        return v;
    }

    // RBJ band-pass biquad (0 dB at the centre). Two in series around the
    // burst tone pass it at full amplitude and push the 440 Hz bed down to
    // ~2% of its level, so the bed can't hold the detector "on".
    class BandPass
    {
        double b0, b2, a1, a2, x1, x2, y1, y2;
        public BandPass(double freq, double rate, double q)
        {
            double w = 2 * Math.PI * freq / rate, alpha = Math.Sin(w) / (2 * q), a0 = 1 + alpha;
            b0 = alpha / a0; b2 = -alpha / a0; a1 = -2 * Math.Cos(w) / a0; a2 = (1 - alpha) / a0;
        }
        public double Step(double x)
        {
            double y = b0 * x + b2 * x2 - a1 * y1 - a2 * y2;
            x2 = x1; x1 = x; y2 = y1; y1 = y;
            return y;
        }
    }

    static int Main(string[] args)
    {
        var pos = new List<string>();
        double freq = 1000, interval = 2, bed = 0.1;
        string captureId = null;
        bool selfPlay = false;
        for (int i = 0; i < args.Length; i++)
        {
            switch (args[i])
            {
                case "--self-play": selfPlay = true; break;
                case "--freq": freq = double.Parse(args[++i], CultureInfo.InvariantCulture); break;
                case "--interval": interval = double.Parse(args[++i], CultureInfo.InvariantCulture); break;
                case "--bed": bed = double.Parse(args[++i], CultureInfo.InvariantCulture); break;
                case "--capture": captureId = args[++i]; break;
                default: pos.Add(args[i]); break;
            }
        }
        if (pos.Count != (selfPlay ? 2 : 4))
        {
            Console.Error.WriteLine("usage: LoopbackOnsets <mac-host> <udp-port> <seconds> <out-dir> [options]");
            Console.Error.WriteLine("       LoopbackOnsets --self-play <seconds> <out-dir> [options]");
            return 2;
        }
        IPEndPoint mac = selfPlay ? null : new IPEndPoint(Dns.GetHostAddresses(pos[0])[0], int.Parse(pos[1]));
        double seconds = double.Parse(pos[selfPlay ? 0 : 2], CultureInfo.InvariantCulture);
        string outDir = pos[selfPlay ? 1 : 3];
        Directory.CreateDirectory(outDir);

        UdpClient udp = null;
        StreamWriter syncOut = null;
        if (!selfPlay)
        {
            udp = new UdpClient();
            udp.Client.ReceiveTimeout = 500;
            syncOut = new StreamWriter(Path.Combine(outDir, "sync.csv"));
            syncOut.WriteLine("phase,send_unix_ns,mac_unix_ns,recv_unix_ns");
            Sync(udp, mac, "pre", 40, syncOut);
            syncOut.Flush();
        }

        var enumerator = (IMMDeviceEnumerator)new MMDeviceEnumerator();
        IMMDevice defaultRender;
        Check(enumerator.GetDefaultAudioEndpoint(0 /* eRender */, 0 /* eConsole */, out defaultRender), "GetDefaultAudioEndpoint");
        Endpoint cap;
        if (captureId != null)
        {
            IMMDevice d;
            Check(enumerator.GetDevice(captureId, out d), "GetDevice " + captureId);
            cap = new Endpoint(d, 0, 10000000 /* 1 s */);
        }
        else
        {
            cap = new Endpoint(defaultRender, AUDCLNT_STREAMFLAGS_LOOPBACK, 10000000);
        }
        var capture = cap.Service<IAudioCaptureClient>();

        Endpoint play = null;
        IAudioRenderClient render = null;
        IAudioClock clock = null;
        ulong clockFreq = 0;
        uint playBuffer = 0;
        long written = 0;
        int nextBurst = 0;
        StreamWriter beepsOut = null;
        if (selfPlay)
        {
            play = new Endpoint(defaultRender, 0, 1000000 /* 100 ms */);
            render = play.Service<IAudioRenderClient>();
            clock = play.Service<IAudioClock>();
            Check(clock.GetFrequency(out clockFreq), "GetFrequency");
            Check(play.Client.GetBufferSize(out playBuffer), "GetBufferSize");
            beepsOut = new StreamWriter(Path.Combine(outDir, "beeps.csv"));
            beepsOut.WriteLine("index,unix_ns");
        }

        // Map QPC (100 ns) to Unix ns once; both clocks are monotonic enough
        // over a run of a few minutes.
        long wallA = NowUnixNs(), qpcAnchor = Qpc100ns(), wallB = NowUnixNs();
        long wallAnchor = (wallA + wallB) / 2;

        Console.WriteLine((captureId != null ? "capture " : "device ") + cap.Describe());
        if (selfPlay) Console.WriteLine("self-play " + play.Describe());
        var onsetsOut = new StreamWriter(Path.Combine(outDir, "onsets.csv"));
        onsetsOut.WriteLine("unix_ns,amplitude,freq_hz");

        int rate = cap.Rate, channels = cap.Channels, blockAlign = cap.BlockAlign, bits = cap.Bits;
        bool isFloat = cap.IsFloat;
        var bp1 = new BandPass(freq, rate, 4);
        var bp2 = new BandPass(freq, rate, 4);
        double env = 0, decay = Math.Exp(-1.0 / (0.005 * rate));   // 5 ms peak-hold release
        // Bursts leave at 0.5 but can arrive ~14 dB down after RDP and volume
        // stages; the filtered bed stays near 0.002 of full scale.
        const double on = 0.02, off = 0.006;
        long onsetNs = 0;
        double peak = 0, loudest = 0, prevY = 0;
        int crossings = 0, burstFrames = 0, rejected = 0;
        long nextQpc = -1;
        bool inBurst = false;
        int quiet = 0, onsets = 0;
        // Capture frames vs QPC across the run. A loopback position only
        // advances while the render engine is running, so below the nominal
        // rate means the render stream went idle or glitched (the client
        // starving) - it is not the device clock; scripts/win/audio-clock.ps1
        // measures that.
        ulong firstPos = 0, lastPos = 0; long firstQpc = -1, lastQpc = 0;

        if (selfPlay) Check(play.Client.Start(), "Start render");
        Check(cap.Client.Start(), "Start");
        var stopAt = DateTime.UtcNow.AddSeconds(seconds);
        while (DateTime.UtcNow < stopAt)
        {
            Thread.Sleep(5);

            if (selfPlay)
            {
                uint padding;
                Check(play.Client.GetCurrentPadding(out padding), "GetCurrentPadding");
                uint avail = playBuffer - padding;
                if (avail > 0)
                {
                    IntPtr buf;
                    Check(render.GetBuffer(avail, out buf), "render GetBuffer");
                    int n = (int)avail * play.Channels;
                    if (play.IsFloat)
                    {
                        var f = new float[n];
                        for (int i = 0; i < avail; i++)
                        {
                            float s = (float)Signal(written + i, play.Rate, freq, interval, bed);
                            for (int c = 0; c < play.Channels; c++) f[i * play.Channels + c] = s;
                        }
                        Marshal.Copy(f, 0, buf, n);
                    }
                    else
                    {
                        var p = new short[n];
                        for (int i = 0; i < avail; i++)
                        {
                            short s = (short)(32767 * Signal(written + i, play.Rate, freq, interval, bed));
                            for (int c = 0; c < play.Channels; c++) p[i * play.Channels + c] = s;
                        }
                        Marshal.Copy(p, 0, buf, n);
                    }
                    Check(render.ReleaseBuffer(avail, 0), "render ReleaseBuffer");
                    written += avail;
                }
                // Each burst's play time: where the device clock stood when its
                // first frame came up, back-dated to that frame.
                ulong devPos, devQpc;
                Check(clock.GetPosition(out devPos, out devQpc), "GetPosition");
                double playedSec = (double)devPos / clockFreq;
                long intervalFrames = (long)(interval * play.Rate);
                while (true)
                {
                    long startFrame = play.Rate + nextBurst * intervalFrames;
                    double startSec = (double)startFrame / play.Rate;
                    if (startSec > playedSec) break;
                    long burstQpc = (long)devQpc - (long)((playedSec - startSec) * 1e7);
                    beepsOut.WriteLine(nextBurst + "," + (wallAnchor + (burstQpc - qpcAnchor) * 100));
                    beepsOut.Flush();
                    nextBurst++;
                }
            }

            uint packet;
            Check(capture.GetNextPacketSize(out packet), "GetNextPacketSize");
            while (packet > 0)
            {
                IntPtr data; uint frames, flags; ulong devPos, qpcPos;
                Check(capture.GetBuffer(out data, out frames, out flags, out devPos, out qpcPos), "GetBuffer");
                long packetQpc = (flags & AUDCLNT_BUFFERFLAGS_TIMESTAMP_ERROR) != 0 && nextQpc >= 0 ? nextQpc : (long)qpcPos;
                bool silent = (flags & AUDCLNT_BUFFERFLAGS_SILENT) != 0;
                if ((flags & AUDCLNT_BUFFERFLAGS_TIMESTAMP_ERROR) == 0)
                {
                    if (firstQpc < 0) { firstQpc = (long)qpcPos; firstPos = devPos; }
                    lastQpc = (long)qpcPos; lastPos = devPos;
                }
                for (int i = 0; i < frames; i++)
                {
                    float v = 0;
                    if (!silent)
                    {
                        for (int c = 0; c < channels; c++)
                        {
                            int at = i * blockAlign + c * (bits / 8);
                            v += isFloat ? BitConverter.ToSingle(BitConverter.GetBytes(Marshal.ReadInt32(data, at)), 0)
                                         : Marshal.ReadInt16(data, at) / 32768f;
                        }
                        v /= channels;
                    }
                    double y = bp2.Step(bp1.Step(v));
                    env = Math.Max(Math.Abs(y), env * decay);
                    double lastY = prevY; prevY = y;
                    if (!inBurst && env > on)
                    {
                        onsetNs = wallAnchor + (packetQpc + (long)i * 10000000L / rate - qpcAnchor) * 100;
                        inBurst = true; peak = 0; crossings = 0; burstFrames = 0; onsets++;
                    }
                    if (inBurst)
                    {
                        peak = Math.Max(peak, env);
                        // Pitch over the loud part only; the filter's ring-down is at its own centre.
                        if (env > peak * 0.5)
                        {
                            if ((y >= 0) != (lastY >= 0)) crossings++;
                            burstFrames++;
                        }
                        quiet = env < off ? quiet + 1 : 0;
                        if (quiet >= rate / 10)                    // 100 ms of quiet ends it
                        {
                            // A burst is 40 ms of ~freq; a click or dropout in the
                            // stream is short and broadband. +-20% still admits a
                            // 48k-played-as-44.1k burst (919 Hz).
                            double hz = burstFrames > 0 ? crossings / 2.0 * rate / burstFrames : 0;
                            if (burstFrames >= rate / 50 && Math.Abs(hz - freq) < freq * 0.2)
                            {
                                onsetsOut.WriteLine(onsetNs + "," + peak.ToString("F4", CultureInfo.InvariantCulture)
                                    + "," + hz.ToString("F1", CultureInfo.InvariantCulture));
                                onsetsOut.Flush();
                                loudest = Math.Max(loudest, peak);
                            }
                            else
                            {
                                rejected++; onsets--;
                            }
                            inBurst = false;
                        }
                    }
                }
                nextQpc = packetQpc + (long)frames * 10000000L / rate;
                Check(capture.ReleaseBuffer(frames), "ReleaseBuffer");
                Check(capture.GetNextPacketSize(out packet), "GetNextPacketSize");
            }
        }
        cap.Client.Stop();
        onsetsOut.Close();
        if (selfPlay)
        {
            play.Client.Stop();
            beepsOut.Close();
        }
        else
        {
            Sync(udp, mac, "post", 40, syncOut);
            syncOut.Close();
        }
        Console.WriteLine("onsets " + onsets + (rejected > 0 ? " (rejected " + rejected + " short or off-pitch blips)" : "")
            + (selfPlay ? ", bursts played " + nextBurst : "")
            + ", loudest burst " + loudest.ToString("F3", CultureInfo.InvariantCulture) + " (sent at 0.5)");
        if (lastQpc > firstQpc && firstQpc >= 0)
        {
            double secs = (lastQpc - firstQpc) / 1e7;
            Console.WriteLine("capture active " + ((lastPos - firstPos) / secs / rate * 100).ToString("F1", CultureInfo.InvariantCulture)
                + "% of " + secs.ToString("F1", CultureInfo.InvariantCulture) + " s ("
                + ((lastPos - firstPos) / secs).ToString("F0", CultureInfo.InvariantCulture) + " frames/s, nominal " + rate + ")");
        }
        return 0;
    }
}
