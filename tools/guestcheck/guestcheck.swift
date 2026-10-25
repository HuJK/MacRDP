// guestcheck — read and drive the Mac's own state from inside the test VM,
// so an RDP feature can be checked end to end from a script (run through
// `scripts/tart-vm.sh exec`, which is in the logged-on user's session).
//
//   guestcheck mouse                     # "x y screenW screenH" (points, top-left origin)
//   guestcheck clip-types                # each pasteboard item's types (and file URL)
//   guestcheck clip-text-get             # pasteboard string
//   guestcheck clip-text-set <text>
//   guestcheck clip-image-get <out.png>  # pasteboard image as PNG; prints WxH
//   guestcheck clip-image-set <in.png>
//   guestcheck clip-files-get            # file URLs on the pasteboard, one path per line
//   guestcheck clip-files-set <path>...   # first path only, see below; prefer finder-copy
//   guestcheck finder-copy <dir>         # Finder: open <dir>, select all, copy (as a user would)
//   guestcheck cp <src> <dst>            # copy a file or tree, fetching File Provider placeholders
//                                        # (`tart exec` children may not, and get EDEADLK)
//   guestcheck sck-record <secs> <out>   # system audio via ScreenCaptureKit, as MacRDP gets it:
//                                        # 48 kHz stereo float32 interleaved, raw
//   guestcheck status-menu <bundle-id> [item]  # open an app's menu-bar (status item) menu,
//                                        # print its items, press the first containing [item]
//   guestcheck cameras                   # video capture devices, as an app's camera picker lists them
//   guestcheck camera-grab <name> <secs> <out.png>  # open the first camera whose name contains
//                                        # <name>, as an app would; prints frames, size, and how
//                                        # much of the last frame (saved as PNG) changed since the
//                                        # first and is colourful. Needs camera access: run it as
//                                        # /Applications/GuestCheck.app through `open`, which can
//                                        # be asked once (the guest agent's children can't)
//   guestcheck input-record <device> <secs> <out>  # an input device (e.g. "BlackHole 2ch",
//                                        # where MacRDP plays the client's mic), same raw
//                                        # layout; prints the device's sample rate
//   guestcheck scene <dir> <secs>        # full-screen picture moved, then held still, on cue
//                                        # (files in <dir>, see SceneView): for picture convergence
//   guestcheck flash <secs> [animate]    # grey screen whose centre square flips black/white on
//                                        # every mouse-down, for click-to-photon latency; animate
//                                        # jitters the square every frame (H.264 tiles)
//   guestcheck video <file> <secs>       # play a movie full screen, looped (encoder load)
//   guestcheck sink <secs> <log>         # full-screen test pattern that logs input (JSON lines):
//                                        # typed text, clicks, scrolls; cursor regions for
//                                        # pointer-shape checks (see SinkView)

import AppKit
import ApplicationServices
import AVFoundation
import CoreAudio
import CoreImage
import ScreenCaptureKit

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(1)
}

/// A value shared with a callback queue.
final class Box<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    init(_ v: T) { value = v }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
}

/// The camera checks' verdict on a capture: frames, size, and (sampled every
/// 4th pixel) the share of the last frame that changed since the first (a
/// live feed moves, a placeholder doesn't) and that is colourful (a grey
/// placeholder isn't). Saves the last frame as PNG.
func reportFrames(name: String, frames: Int, elapsed: Double, first: Data,
                  last frame: CVPixelBuffer, out: String) {
    CVPixelBufferLockBaseAddress(frame, .readOnly)
    let w = CVPixelBufferGetWidth(frame), h = CVPixelBufferGetHeight(frame)
    let stride = CVPixelBufferGetBytesPerRow(frame)
    let px = CVPixelBufferGetBaseAddress(frame)!.assumingMemoryBound(to: UInt8.self)
    var changed = 0, colourful = 0, total = 0
    first.withUnsafeBytes { (old: UnsafeRawBufferPointer) in
        for y in Swift.stride(from: 0, to: h, by: 4) {
            for x in Swift.stride(from: 0, to: w, by: 4) {
                let i = y * stride + x * 4
                let b = Int(px[i]), g = Int(px[i + 1]), r = Int(px[i + 2])
                if i + 2 < old.count {
                    let d: Int = abs(b - Int(old[i])) + abs(g - Int(old[i + 1])) + abs(r - Int(old[i + 2]))
                    if d > 30 { changed += 1 }
                }
                if max(r, g, b) - min(r, g, b) > 40 { colourful += 1 }
                total += 1
            }
        }
    }
    CVPixelBufferUnlockBaseAddress(frame, .readOnly)
    guard let png = NSBitmapImageRep(ciImage: CIImage(cvPixelBuffer: frame)).representation(using: .png, properties: [:]),
          FileManager.default.createFile(atPath: out, contents: png) else { fail("cannot write \(out)") }
    let pct = { (n: Int) in n * 100 / max(total, 1) }
    print("\(name): \(frames) frames in \(String(format: "%.1f", elapsed)) s, \(w)x\(h), \(pct(changed))% changed, \(pct(colourful))% colourful")
}

/// Cameras as apps see them; CMIO extensions' devices are `.external`.
func videoDevices() -> [AVCaptureDevice] {
    AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external],
                                     mediaType: .video, position: .unspecified).devices
}

let args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else { fail("usage: guestcheck <command> [args]") }
let pb = NSPasteboard.general

switch cmd {
case "mouse":
    guard let screen = NSScreen.main else { fail("no screen") }
    let p = NSEvent.mouseLocation
    let h = screen.frame.height
    print(String(format: "%.0f %.0f %.0f %.0f", p.x, h - p.y, screen.frame.width, h))

case "clip-types":
    for (i, item) in (pb.pasteboardItems ?? []).enumerated() {
        print("item \(i): " + item.types.map(\.rawValue).joined(separator: " "))
        if let url = item.string(forType: .fileURL) { print("  file-url \(url)") }
    }

case "clip-text-get":
    guard let s = pb.string(forType: .string) else { fail("no string on the pasteboard") }
    print(s)

case "clip-text-set":
    guard args.count == 2 else { fail("usage: guestcheck clip-text-set <text>") }
    pb.clearContents()
    pb.setString(args[1], forType: .string)

case "clip-image-get":
    guard args.count == 2 else { fail("usage: guestcheck clip-image-get <out.png>") }
    guard let image = NSImage(pasteboard: pb),
          let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        fail("no image on the pasteboard")
    }
    try! png.write(to: URL(fileURLWithPath: args[1]))
    print("\(rep.pixelsWide)x\(rep.pixelsHigh)")

case "clip-image-set":
    guard args.count == 2, let image = NSImage(contentsOfFile: args[1]) else {
        fail("usage: guestcheck clip-image-set <in.png>")
    }
    pb.clearContents()
    pb.writeObjects([image])

case "clip-files-get":
    let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    guard !urls.isEmpty else { fail("no file URLs on the pasteboard") }
    for u in urls { print(u.path) }

case "clip-files-set":
    guard args.count >= 2 else { fail("usage: guestcheck clip-files-set <path>...") }
    // Only the first URL survives when this tool writes several (NSURLs or
    // NSPasteboardItems alike, macOS 26.6); multi-file copies go through
    // finder-copy instead.
    pb.clearContents()
    pb.writeObjects(args.dropFirst().map { URL(fileURLWithPath: $0) as NSURL })

case "finder-copy":
    guard args.count == 2 else { fail("usage: guestcheck finder-copy <dir>") }
    NSWorkspace.shared.open(URL(fileURLWithPath: args[1]))
    sleep(2)
    NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.activate()
    usleep(500_000)
    for key: CGKeyCode in [0, 8] {               // A, C
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down)
            e?.flags = .maskCommand
            e?.post(tap: .cghidEventTap)
            usleep(100_000)
        }
    }
    usleep(500_000)
    let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    for u in urls { print(u.path) }

case "cp":
    guard args.count == 3 else { fail("usage: guestcheck cp <src> <dst>") }
    // Processes started through the guest agent don't materialize dataless
    // (File Provider) files: reading MacRDP's lazy clipboard folder fails
    // with EDEADLK. Opt in, as Finder does.
    guard setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS,
                         IOPOL_MATERIALIZE_DATALESS_FILES_ON) == 0 else {
        fail("setiopolicy_np: \(String(cString: strerror(errno)))")
    }
    do {
        try FileManager.default.copyItem(at: URL(fileURLWithPath: args[1]), to: URL(fileURLWithPath: args[2]))
    } catch {
        fail("cp: \(error.localizedDescription)")
    }

case "sck-record":
    guard args.count == 3, let secs = Double(args[1]) else { fail("usage: guestcheck sck-record <secs> <out>") }
    // Same stream configuration as MacRDP's DisplayPipeline audio.
    final class Sink: NSObject, SCStreamOutput {
        let file: FileHandle
        var frames = 0
        init(_ f: FileHandle) { file = f }
        func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
            guard type == .audio else { return }
            // Planar stereo: room for one AudioBuffer per channel.
            let list = AudioBufferList.allocate(maximumBuffers: 2)
            defer { free(list.unsafeMutablePointer) }
            var block: CMBlockBuffer?
            guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                    sb, bufferListSizeNeededOut: nil, bufferListOut: list.unsafeMutablePointer,
                    bufferListSize: AudioBufferList.sizeInBytes(maximumBuffers: 2),
                    blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &block) == noErr
            else { return }
            let n = CMSampleBufferGetNumSamples(sb)
            guard let l = list[0].mData?.assumingMemoryBound(to: Float.self) else { return }
            let r = list.count > 1 ? list[1].mData?.assumingMemoryBound(to: Float.self) : nil
            var out = [Float](repeating: 0, count: n * 2)
            for i in 0..<n { out[2 * i] = l[i]; out[2 * i + 1] = r?[i] ?? l[i] }
            out.withUnsafeBytes { file.write(Data($0)) }
            frames += n
        }
    }
    guard FileManager.default.createFile(atPath: args[2], contents: nil),
          let fh = FileHandle(forWritingAtPath: args[2]) else { fail("cannot write \(args[2])") }
    let content = try await SCShareableContent.current
    guard let display = content.displays.first else { fail("no display") }
    let cfg = SCStreamConfiguration()
    cfg.capturesAudio = true
    cfg.sampleRate = 48000
    cfg.channelCount = 2
    cfg.excludesCurrentProcessAudio = true
    cfg.width = 64; cfg.height = 64
    cfg.minimumFrameInterval = CMTime(value: 1, timescale: 2)
    let sink = Sink(fh)
    let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: cfg, delegate: nil)
    try stream.addStreamOutput(sink, type: .audio, sampleHandlerQueue: DispatchQueue(label: "sck-audio"))
    let start = Date()
    try await stream.startCapture()
    try await Task.sleep(nanoseconds: UInt64(secs * 1e9))
    try await stream.stopCapture()
    try fh.close()
    print("\(sink.frames) frames in \(String(format: "%.2f", Date().timeIntervalSince(start))) s")

case "status-menu":
    // Through Accessibility, which the guest agent (our parent) holds.
    guard args.count >= 2,
          let app = NSRunningApplication.runningApplications(withBundleIdentifier: args[1]).first else {
        fail("usage: guestcheck status-menu <bundle-id> [item] (app must be running)")
    }
    func attr(_ el: AXUIElement, _ name: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
    }
    func kids(_ el: AXUIElement) -> [AXUIElement] { (attr(el, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
    func title(_ el: AXUIElement) -> String { (attr(el, kAXTitleAttribute) as? String) ?? "" }
    let root = AXUIElementCreateApplication(app.processIdentifier)
    guard let bar = attr(root, "AXExtrasMenuBar"), let item = kids(bar as! AXUIElement).first else {
        fail("\(args[1]) has no status item")
    }
    // The menu is rebuilt each time it opens; wait for it, and for [item].
    var target: AXUIElement?
    var titles: [String] = []
    func walk(_ el: AXUIElement) {
        if (attr(el, kAXRoleAttribute) as? String) == "AXMenuItem", !title(el).isEmpty {
            titles.append(title(el))
            if target == nil, args.count > 2, title(el).contains(args[2]) { target = el }
        }
        kids(el).forEach(walk)
    }
    for attempt in 1...3 {
        AXUIElementPerformAction(item, kAXPressAction as CFString)
        for _ in 0..<15 where target == nil && (titles.isEmpty || args.count > 2) {
            usleep(200_000)
            titles = []; walk(item)
        }
        if args.count <= 2 { break }
        if let t = target, AXUIElementPerformAction(t, kAXPressAction as CFString) == .success { break }
        AXUIElementPerformAction(item, kAXCancelAction as CFString)
        target = nil
        if attempt == 3 { titles.forEach { print($0) }; fail("could not press a menu item containing \(args[2])") }
        usleep(500_000)
    }
    titles.forEach { print($0) }
    if let target { print("pressed \(title(target))") } else { AXUIElementPerformAction(item, kAXCancelAction as CFString) }

case "cameras":
    for d in videoDevices() { print("\(d.localizedName)\t\(d.uniqueID)") }

case "camera-grab":
    guard args.count == 4, let secs = Double(args[2]) else {
        fail("usage: guestcheck camera-grab <name> <secs> <out.png>")
    }
    // Access first, so the one-time prompt can be raised with no camera around.
    if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
        // The first time, macOS asks whether we (GuestCheck.app) may use the
        // camera; wait a while for someone to answer. tccd only asks for a
        // process that is an app on screen, hence NSApplication.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        let answer = Box<Bool?>(nil)
        AVCaptureDevice.requestAccess(for: .video) { answer.set($0) }
        for _ in 0..<600 where answer.get() == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
    }
    guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
        fail("no camera access for the guest agent (\(AVCaptureDevice.authorizationStatus(for: .video).rawValue))")
    }
    guard let device = videoDevices().first(where: { $0.localizedName.contains(args[1]) }) else {
        fail("no camera named like \(args[1]): \(videoDevices().map(\.localizedName))")
    }
    final class Grab: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
        let frames = Box(0)
        let first = Box<Data?>(nil)   // the first frame's pixels, to tell a live feed from a still
        let last = Box<CVPixelBuffer?>(nil)
        func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from c: AVCaptureConnection) {
            frames.set(frames.get() + 1)
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { return }
            if first.get() == nil {
                CVPixelBufferLockBaseAddress(pb, .readOnly)
                first.set(Data(bytes: CVPixelBufferGetBaseAddress(pb)!,
                               count: CVPixelBufferGetBytesPerRow(pb) * CVPixelBufferGetHeight(pb)))
                CVPixelBufferUnlockBaseAddress(pb, .readOnly)
            }
            last.set(pb)
        }
    }
    let session = AVCaptureSession()
    let input = try AVCaptureDeviceInput(device: device)
    let output = AVCaptureVideoDataOutput()
    output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    let grab = Grab()
    output.setSampleBufferDelegate(grab, queue: DispatchQueue(label: "camera-grab"))
    guard session.canAddInput(input), session.canAddOutput(output) else { fail("cannot capture from \(device.localizedName)") }
    session.addInput(input)
    session.addOutput(output)
    let start = Date()
    session.startRunning()
    try await Task.sleep(nanoseconds: UInt64(secs * 1e9))
    session.stopRunning()
    let elapsed = Date().timeIntervalSince(start)
    guard let frame = grab.last.get(), let first = grab.first.get() else {
        fail("\(device.localizedName): no frames in \(secs) s")
    }
    reportFrames(name: device.localizedName, frames: grab.frames.get(), elapsed: elapsed,
                 first: first, last: frame, out: args[3])

case "input-record":
    guard args.count == 4, let secs = Double(args[2]) else {
        fail("usage: guestcheck input-record <device-name> <secs> <out>")
    }
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
    let device = ids.first { id in
        var nameAddr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                  mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var n = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &n, &name) == noErr,
              let s = name?.takeRetainedValue() as String? else { return false }
        return s == args[1]
    }
    guard var device else { fail("no audio device named \(args[1])") }
    let engine = AVAudioEngine()
    guard let unit = engine.inputNode.audioUnit,
          AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                               &device, UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr else {
        fail("cannot select \(args[1]) as the input")
    }
    let fmt = engine.inputNode.outputFormat(forBus: 0)
    guard FileManager.default.createFile(atPath: args[3], contents: nil),
          let fh = FileHandle(forWritingAtPath: args[3]) else { fail("cannot write \(args[3])") }
    var frames = 0
    engine.inputNode.installTap(onBus: 0, bufferSize: 4800, format: fmt) { buf, _ in
        guard let ch = buf.floatChannelData else { return }
        let n = Int(buf.frameLength), right = buf.format.channelCount > 1 ? 1 : 0
        var out = [Float](repeating: 0, count: n * 2)
        for i in 0..<n { out[2 * i] = ch[0][i]; out[2 * i + 1] = ch[right][i] }
        out.withUnsafeBytes { fh.write(Data($0)) }
        frames += n
    }
    try engine.start()
    try await Task.sleep(nanoseconds: UInt64(secs * 1e9))
    engine.stop()
    try fh.close()
    print("\(frames) frames at \(Int(fmt.sampleRate)) Hz")

case "sink":
    guard args.count == 3, let secs = Double(args[1]) else { fail("usage: guestcheck sink <secs> <log>") }
    runSink(seconds: secs, logPath: args[2])

case "scene":
    guard args.count == 3, let secs = Double(args[2]) else { fail("usage: guestcheck scene <dir> <secs>") }
    runScene(dir: args[1], seconds: secs)

case "video":
    guard args.count == 3, let secs = Double(args[2]) else { fail("usage: guestcheck video <file> <secs>") }
    runVideo(path: args[1], seconds: secs)

case "flash":
    guard (2...3).contains(args.count), let secs = Double(args[1]),
          args.count == 2 || args[2] == "animate" else { fail("usage: guestcheck flash <secs> [animate]") }
    runFlash(seconds: secs, animate: args.count == 3)

default:
    fail("unknown command \(cmd)")
}

// MARK: - sink

/// Everything a remote-input check needs to read back, one JSON object per
/// line, appended as it happens so a test can read the log mid-run.
final class SinkLog {
    private let fh: FileHandle
    init(path: String) {
        FileManager.default.createFile(atPath: path, contents: nil)
        fh = FileHandle(forWritingAtPath: path)!
    }
    func write(_ obj: [String: Any]) {
        guard var d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return }
        d.append(0x0A)
        fh.write(d)
    }
}

/// Borderless windows refuse key status by default; the sink needs it.
final class SinkWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// The test pattern, drawn in screen points with a top-left origin:
///   - top half: eight SMPTE-style colour bars
///   - bottom half, left: a horizontal grey ramp; right: 1 px and 4 px checkerboards
///   - a band of cursor regions (I-beam, pointing hand, crosshair; arrow elsewhere)
///   - a frame counter in the black bar, top right (x 0.875-1, y 0-0.15),
///     redrawn every 250 ms so a frozen client picture is detectable
/// It also logs typed text (keyDown characters, so both scancode and Unicode
/// injection land here), clicks and scroll deltas.
final class SinkView: NSView {
    let log: SinkLog
    var counter = 0
    static let counterRegion = (x0: 0.875, y0: 0.0, x1: 1.0, y1: 0.15)
    static let bars: [NSColor] = [.white, .yellow, .cyan, .green, .magenta, .red, .blue, .black]
    init(frame: NSRect, log: SinkLog) { self.log = log; super.init(frame: frame) }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Cursor regions, as fractions of the view: x0, y0, x1, y1.
    static let cursorRegions: [(String, NSCursor, CGFloat, CGFloat, CGFloat, CGFloat)] = [
        ("ibeam", .iBeam, 0.05, 0.55, 0.25, 0.70),
        ("hand", .pointingHand, 0.40, 0.55, 0.60, 0.70),
        ("crosshair", .crosshair, 0.75, 0.55, 0.95, 0.70),
    ]

    override func draw(_ dirtyRect: NSRect) {
        let w = bounds.width, h = bounds.height
        for (i, c) in Self.bars.enumerated() {
            c.setFill()
            NSRect(x: w * CGFloat(i) / 8, y: 0, width: w / 8 + 1, height: h / 2).fill()
        }
        // Grey ramp.
        let steps = 64
        for i in 0..<steps {
            NSColor(white: CGFloat(i) / CGFloat(steps - 1), alpha: 1).setFill()
            NSRect(x: w * 0.5 * CGFloat(i) / CGFloat(steps), y: h / 2, width: w * 0.5 / CGFloat(steps) + 1, height: h / 2).fill()
        }
        // Checkerboards (fine detail for the codec).
        for (x0, cell) in [(w * 0.5, CGFloat(1)), (w * 0.75, CGFloat(4))] {
            NSColor.white.setFill(); NSRect(x: x0, y: h / 2, width: w * 0.25, height: h / 2).fill()
            NSColor.black.setFill()
            var y = h * 0.75
            while y < h {
                var x = x0
                var odd = Int((y - h * 0.75) / cell) % 2 == 1
                while x < x0 + w * 0.25 {
                    if odd { NSRect(x: x, y: y, width: cell, height: cell).fill() }
                    odd.toggle(); x += cell
                }
                y += cell
            }
        }
        // Frame counter: big white digits on the black bar.
        let c = Self.counterRegion
        NSColor.black.setFill()
        NSRect(x: w * c.x0, y: h * c.y0, width: w * (c.x1 - c.x0), height: h * (c.y1 - c.y0)).fill()
        ("\(counter)" as NSString).draw(at: NSPoint(x: w * c.x0 + 10, y: h * c.y0 + 10),
                                      withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 96, weight: .bold),
                                                       .foregroundColor: NSColor.white])
        // Cursor regions, outlined and labelled.
        for (name, _, x0, y0, x1, y1) in Self.cursorRegions {
            let r = NSRect(x: w * x0, y: h * y0, width: w * (x1 - x0), height: h * (y1 - y0))
            NSColor(white: 0.85, alpha: 1).setFill(); r.fill()
            NSColor.black.setStroke(); NSBezierPath(rect: r).stroke()
            (name as NSString).draw(at: NSPoint(x: r.minX + 8, y: r.minY + 8),
                                    withAttributes: [.font: NSFont.systemFont(ofSize: 24), .foregroundColor: NSColor.black])
        }
    }

    override func resetCursorRects() {
        let w = bounds.width, h = bounds.height
        addCursorRect(bounds, cursor: .arrow)
        for (_, cursor, x0, y0, x1, y1) in Self.cursorRegions {
            addCursorRect(NSRect(x: w * x0, y: h * y0, width: w * (x1 - x0), height: h * (y1 - y0)), cursor: cursor)
        }
    }

    private func screenPoint(_ e: NSEvent) -> [String: Any] {
        let p = NSEvent.mouseLocation
        let h = NSScreen.main?.frame.height ?? 0
        return ["x": Int(p.x.rounded()), "y": Int((h - p.y).rounded())]
    }

    override func keyDown(with e: NSEvent) {
        log.write(["type": "key", "chars": e.characters ?? "", "keyCode": Int(e.keyCode),
                   "flags": Int(e.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue)])
    }
    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        log.write(["type": "click", "button": "left"].merging(screenPoint(e)) { a, _ in a })
    }
    override func rightMouseDown(with e: NSEvent) {
        log.write(["type": "click", "button": "right"].merging(screenPoint(e)) { a, _ in a })
    }
    override func scrollWheel(with e: NSEvent) {
        log.write(["type": "scroll", "dy": Double(e.scrollingDeltaY), "dx": Double(e.scrollingDeltaX),
                   "precise": e.hasPreciseScrollingDeltas, "inverted": e.isDirectionInvertedFromDevice])
    }
}

func runSink(seconds: Double, logPath: String) {
    let log = SinkLog(path: logPath)
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    guard let screen = NSScreen.main else { fail("no screen") }
    let win = SinkWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    win.level = .screenSaver
    let view = SinkView(frame: NSRect(origin: .zero, size: screen.frame.size), log: log)
    win.contentView = view
    win.makeKeyAndOrderFront(nil)
    win.makeFirstResponder(view)
    app.activate(ignoringOtherApps: true)
    log.write(["type": "ready", "w": Int(screen.frame.width), "h": Int(screen.frame.height)])
    Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
        view.counter += 1
        let c = SinkView.counterRegion, b = view.bounds
        view.setNeedsDisplay(NSRect(x: b.width * c.x0, y: b.height * c.y0,
                                    width: b.width * (c.x1 - c.x0), height: b.height * (c.y1 - c.y0)))
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { app.terminate(nil) }
    app.run()
}

// MARK: - scene

/// A full-screen picture that is moved, then held perfectly still, on cue —
/// for checking that the client's picture catches up once the Mac's stops
/// changing (the hybrid encoder flips tiles between H.264 while they change
/// and Progressive once they're still; a tile must never stay behind).
///
/// Background: 8 px cells in colours hashed from their position, so every
/// tile is distinct and a stale one shows. Sprite: 320x200 stripes with a
/// counter that changes every frame, so the tiles it covers keep changing
/// while it moves.
///
/// Driven by files in `dir`: `go-N` (contents: seconds, default 4) moves the
/// sprite along path N; when it has stopped and the final frame is drawn,
/// `held-N` appears. `ready` once the window is up; `quit` ends it.
final class SceneView: NSView {
    override var isFlipped: Bool { true }
    let background: CGImage
    var sprite = CGPoint(x: 100, y: 100)
    var frameNumber = 0
    static let spriteSize = CGSize(width: 320, height: 200)

    init(size: CGSize) {
        let w = Int(size.width), h = Int(size.height)
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
        for cy in stride(from: 0, to: h, by: 8) {
            for cx in stride(from: 0, to: w, by: 8) {
                var v = UInt32(truncatingIfNeeded: cx &* 73856093 ^ cy &* 19349663)
                v = (v ^ (v >> 13)) &* 0x5bd1e995
                ctx.setFillColor(CGColor(srgbRed: CGFloat(v & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                                         blue: CGFloat((v >> 16) & 0xFF) / 255, alpha: 1))
                ctx.fill(CGRect(x: cx, y: h - cy - 8, width: 8, height: 8))
            }
        }
        background = ctx.makeImage()!
        super.init(frame: NSRect(origin: .zero, size: size))
    }
    required init?(coder: NSCoder) { fatalError() }

    var spriteRect: NSRect { NSRect(origin: sprite, size: SceneView.spriteSize) }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.translateBy(x: 0, y: bounds.height); ctx.scaleBy(x: 1, y: -1)   // image is bottom-up
        ctx.draw(background, in: CGRect(origin: .zero, size: bounds.size))
        ctx.restoreGState()
        let r = spriteRect
        guard r.intersects(dirtyRect) else { return }
        let colors: [NSColor] = [.systemRed, .systemYellow, .systemGreen, .systemTeal, .systemBlue, .systemPurple]
        for i in 0..<12 {
            colors[(i + frameNumber) % colors.count].setFill()
            NSRect(x: r.minX + CGFloat(i) * r.width / 12, y: r.minY, width: r.width / 12 + 1, height: r.height).fill()
        }
        let text = String(format: "%05d", frameNumber) as NSString
        text.draw(at: NSPoint(x: r.minX + 40, y: r.minY + 60),
                  withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 64, weight: .bold),
                                   .foregroundColor: NSColor.white])
    }
}

func runScene(dir: String, seconds: Double) {
    let fm = FileManager.default
    try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    for f in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] { try? fm.removeItem(atPath: dir + "/" + f) }
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    guard let screen = NSScreen.main else { fail("no screen") }
    let win = SinkWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    win.level = .screenSaver
    let view = SceneView(size: screen.frame.size)
    win.contentView = view
    win.makeKeyAndOrderFront(nil)
    app.activate(ignoringOtherApps: true)
    fm.createFile(atPath: dir + "/ready", contents: nil)

    var cycle = 0
    // Poll for the next go-N; run its motion at 60 Hz, then hold.
    Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { poll in
        if fm.fileExists(atPath: dir + "/quit") { app.terminate(nil) }
        let next = cycle + 1
        guard let go = fm.contents(atPath: dir + "/go-\(next)") else { return }
        cycle = next
        poll.fireDate = .distantFuture
        let move = Double(String(decoding: go, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 4
        let b = view.bounds, s = SceneView.spriteSize
        let cx = (b.width - s.width) / 2, cy = (b.height - s.height) / 2
        let n = Double(next)
        let start = Date()
        Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { tick in
            let t = min(Date().timeIntervalSince(start), move)
            let old = view.spriteRect
            view.sprite = CGPoint(x: cx + cx * 0.9 * sin(2 * .pi * (0.13 + 0.02 * n) * t + n),
                                  y: cy + cy * 0.9 * sin(2 * .pi * (0.21 + 0.03 * n) * t + 2 * n))
            view.frameNumber += 1
            view.setNeedsDisplay(old.union(view.spriteRect).insetBy(dx: -1, dy: -1))
            guard t >= move else { return }
            tick.invalidate()
            view.displayIfNeeded()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                let held = String(format: "%.3f %d %d %d\n", Date().timeIntervalSince1970,
                                  Int(view.sprite.x), Int(view.sprite.y), view.frameNumber)
                fm.createFile(atPath: dir + "/held-\(next)", contents: Data(held.utf8))
                poll.fireDate = Date()
            }
        }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { app.terminate(nil) }
    app.run()
}

// MARK: - flash

/// Click-to-photon target (tools/latency/click-latency.sh): mid-grey, with a
/// 400x400 square in the centre that flips between near-black and near-white
/// on every mouse-down, drawn at once. With `animate` the square's level
/// jitters by a few steps every frame, so the hybrid encoder sends its tiles
/// as H.264 instead of Progressive.
final class FlashView: NSView {
    var lit = false
    var jitter: CGFloat = 0
    static let side: CGFloat = 400

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        lit.toggle()
        display()
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.5, alpha: 1).setFill()
        bounds.fill()
        NSColor(white: (lit ? 0.85 : 0.12) + jitter, alpha: 1).setFill()
        NSRect(x: bounds.midX - Self.side / 2, y: bounds.midY - Self.side / 2,
               width: Self.side, height: Self.side).fill()
    }
}

func runFlash(seconds: Double, animate: Bool) {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    guard let screen = NSScreen.main else { fail("no screen") }
    let win = SinkWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    win.level = .screenSaver
    let view = FlashView(frame: NSRect(origin: .zero, size: screen.frame.size))
    win.contentView = view
    win.makeKeyAndOrderFront(nil)
    app.activate(ignoringOtherApps: true)
    if animate {
        var step = 0
        Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { _ in
            step += 1
            view.jitter = CGFloat(step % 4) * 0.02
            view.setNeedsDisplay(view.bounds)
        }
    }
    print("ready"); fflush(stdout)
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { app.terminate(nil) }
    app.run()
}

// MARK: - video

/// A movie full screen, looped: the encoder's heavy case (every tile changes
/// every frame).
func runVideo(path: String, seconds: Double) {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    guard let screen = NSScreen.main else { fail("no screen") }
    let win = SinkWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    win.level = .screenSaver
    let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
    view.wantsLayer = true
    let item = AVPlayerItem(url: URL(fileURLWithPath: path))
    let player = AVQueuePlayer()
    let looper = AVPlayerLooper(player: player, templateItem: item)
    let layer = AVPlayerLayer(player: player)
    layer.frame = view.bounds
    layer.videoGravity = .resizeAspectFill
    view.layer?.addSublayer(layer)
    win.contentView = view
    win.makeKeyAndOrderFront(nil)
    app.activate(ignoringOtherApps: true)
    player.play()
    print("playing"); fflush(stdout)
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { _ = looper; app.terminate(nil) }
    app.run()
}

