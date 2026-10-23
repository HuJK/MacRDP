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
//   guestcheck sck-record <secs> <out>   # system audio via ScreenCaptureKit, as MacRDP gets it:
//                                        # 48 kHz stereo float32 interleaved, raw
//   guestcheck sink <secs> <log>         # full-screen test pattern that logs input (JSON lines):
//                                        # typed text, clicks, scrolls; cursor regions for
//                                        # pointer-shape checks (see SinkView)

import AppKit
import ScreenCaptureKit

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(1)
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

case "sink":
    guard args.count == 3, let secs = Double(args[1]) else { fail("usage: guestcheck sink <secs> <log>") }
    runSink(seconds: secs, logPath: args[2])

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
