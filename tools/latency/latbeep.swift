// latbeep — timed tone bursts for end-to-end audio-out latency measurement.
//
//   latbeep [--interval 2.0] [--duration 60] [--freq 1000] [--burst-ms 40] [--port 47100]
//           [--bed 0.1]
//
// Plays a short sine burst every --interval seconds on the default output
// device (the one MacRDP's system-audio tap captures) and prints one CSV
// line per burst to stdout:
//
//   index,unix_ns
//
// unix_ns is the wall-clock time the burst's first sample is presented at
// this Mac's output: the render callback's host time, plus the frame offset
// inside the buffer, plus the output node's presentation latency.
//
// Also answers UDP clock queries on --port: each datagram is echoed back
// with this machine's CLOCK_REALTIME (8 bytes, big-endian ns) appended, so
// the client can estimate its clock offset with a min-RTT exchange. That
// keeps the measurement on the client's clock alone; the VM's own NTP sync
// is often off by more than a second.
//
// --bed adds a continuous 440 Hz tone at that amplitude under the bursts,
// so the stream never goes silent, like a video playing; latency that only
// builds up during continuous playback needs it to show.
//
// In a VZ guest an IO overload can leave AVAudioEngine rendering into a dead
// HAL IO context: the callbacks keep running but nothing reaches the mix.
// So the engine is restarted after any overload or configuration change. A
// screen-capture source keeps streaming through the gap, so the RDP audio
// stream stays continuous; only the content goes quiet for a moment.

import AVFoundation
import Darwin

var interval = 2.0, duration = 60.0, freq = 1000.0, burstMs = 40.0, port: UInt16 = 47100, bed = 0.0
var args = CommandLine.arguments.dropFirst()
while let a = args.popFirst() {
    guard let v = args.popFirst() else { break }
    switch a {
    case "--interval": interval = Double(v) ?? interval
    case "--duration": duration = Double(v) ?? duration
    case "--freq": freq = Double(v) ?? freq
    case "--burst-ms": burstMs = Double(v) ?? burstMs
    case "--port": port = UInt16(v) ?? port
    case "--bed": bed = Double(v) ?? bed
    default: FileHandle.standardError.write("unknown option \(a)\n".data(using: .utf8)!); exit(2)
    }
}

func log(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

// MARK: - UDP clock server

Thread.detachNewThread {
    let fd = socket(AF_INET, SOCK_DGRAM, 0)
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr = in_addr(s_addr: INADDR_ANY)
    let ok = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard ok == 0 else { log("latbeep: bind udp/\(port) failed: errno \(errno)"); return }
    var buf = [UInt8](repeating: 0, count: 64)
    var from = sockaddr_storage()
    while true {
        var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let n = withUnsafeMutablePointer(to: &from) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                recvfrom(fd, &buf, 48, 0, $0, &len)
            }
        }
        guard n > 0 else { continue }
        var now = clock_gettime_nsec_np(CLOCK_REALTIME).bigEndian
        withUnsafeBytes(of: &now) { raw in
            for i in 0..<8 { buf[n + i] = raw[i] }
        }
        _ = withUnsafeMutablePointer(to: &from) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, buf, n + 8, 0, $0, len)
            }
        }
    }
}

// MARK: - Tone bursts

let engine = AVAudioEngine()
let hwFormat = engine.outputNode.inputFormat(forBus: 0)
let sr = hwFormat.sampleRate
guard let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: hwFormat.channelCount) else {
    log("latbeep: no output format"); exit(1)
}

var timebase = mach_timebase_info_data_t()
mach_timebase_info(&timebase)
let nsPerTick = Double(timebase.numer) / Double(timebase.denom)

let leadFrames = Int64(sr)                       // 1 s of silence first
let intervalFrames = Int64(interval * sr)
let burstFrames = Int64(burstMs / 1000 * sr)
let rampFrames = max(1, Int64(0.005 * sr))       // 5 ms raised-cosine ramps

// Handoff from the render thread: it fills slot k, then publishes count.
// Single writer, single polling reader; a test tool, not production audio.
let capacity = 1 << 16
let burstHost = UnsafeMutablePointer<UInt64>.allocate(capacity: capacity)
let anchorHost = UnsafeMutablePointer<UInt64>.allocate(capacity: capacity)
let anchorWall = UnsafeMutablePointer<UInt64>.allocate(capacity: capacity)
let published = UnsafeMutablePointer<Int>.allocate(capacity: 1)
published.pointee = 0
var rendered: Int64 = 0

let source = AVAudioSourceNode(format: format) { _, ts, frameCount, abl -> OSStatus in
    let buffers = UnsafeMutableAudioBufferListPointer(abl)
    let validHost = ts.pointee.mFlags.contains(.hostTimeValid)
    let hostNow = mach_absolute_time()
    let cycleHost = validHost ? ts.pointee.mHostTime : hostNow
    for i in 0..<Int(frameCount) {
        let rel = rendered + Int64(i) - leadFrames
        var sample = Float(bed * sin(2 * Double.pi * 440 * Double(rendered + Int64(i)) / sr))
        if rel >= 0 {
            let k = Int(rel / intervalFrames), off = rel % intervalFrames
            if off < burstFrames {
                let edge = min(off, burstFrames - 1 - off)
                let env = edge < rampFrames ? 0.5 - 0.5 * cos(Double.pi * Double(edge) / Double(rampFrames)) : 1
                sample += Float(0.5 * env * sin(2 * Double.pi * freq * Double(off) / sr))
                if off == 0 && k < capacity {
                    burstHost[k] = cycleHost + UInt64(Double(i) / sr * 1e9 / nsPerTick)
                    anchorHost[k] = hostNow
                    anchorWall[k] = clock_gettime_nsec_np(CLOCK_REALTIME)
                    OSMemoryBarrier()
                    published.pointee = k + 1
                }
            }
        }
        for b in buffers { b.mData!.assumingMemoryBound(to: Float.self)[i] = sample }
    }
    rendered += Int64(frameCount)
    return noErr
}

engine.attach(source)
engine.connect(source, to: engine.mainMixerNode, format: format)
do { try engine.start() } catch { log("latbeep: engine start failed: \(error)"); exit(1) }

// Restart requests from the overload listener / config-change notification,
// served by the main loop below.
let restartWanted = UnsafeMutablePointer<Int>.allocate(capacity: 1)
restartWanted.pointee = 0
var outputDevice = AudioObjectID(0)
var deviceSize = UInt32(MemoryLayout<AudioObjectID>.size)
var defaultOutput = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                               mScope: kAudioObjectPropertyScopeGlobal,
                                               mElement: kAudioObjectPropertyElementMain)
AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &defaultOutput, 0, nil, &deviceSize, &outputDevice)
var overload = AudioObjectPropertyAddress(mSelector: kAudioDeviceProcessorOverload,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
AudioObjectAddPropertyListenerBlock(outputDevice, &overload, DispatchQueue.global()) { _, _ in
    restartWanted.pointee = 1
}
NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                       queue: nil) { _ in restartWanted.pointee = 1 }

let presentationNs = engine.outputNode.presentationLatency * 1e9
log("latbeep: \(Int(sr)) Hz x\(format.channelCount), burst \(Int(burstMs)) ms @ \(Int(freq)) Hz every \(interval) s, "
    + "bed \(bed), presentation latency \(String(format: "%.1f", presentationNs / 1e6)) ms, udp/\(port)")
print("index,unix_ns")

let deadline = Date().addingTimeInterval(duration)
var printed = 0, restarts = 0
var lastRestart = Date.distantPast
while Date() < deadline {
    usleep(50_000)
    if restartWanted.pointee != 0 && Date().timeIntervalSince(lastRestart) > 1 {
        restartWanted.pointee = 0
        lastRestart = Date()
        engine.stop()
        do { try engine.start(); restarts += 1 } catch { log("latbeep: engine restart failed: \(error)") }
    }
    let n = published.pointee
    OSMemoryBarrier()
    while printed < n {
        let k = printed
        let ago = Double(Int64(bitPattern: anchorHost[k] &- burstHost[k])) * nsPerTick
        let unixNs = Double(anchorWall[k]) - ago + presentationNs
        print("\(k),\(Int64(unixNs))")
        fflush(stdout)
        printed += 1
    }
}
engine.stop()
log("latbeep: \(restarts) engine restart(s) after IO overloads / config changes")
