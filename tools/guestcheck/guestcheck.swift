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

default:
    fail("unknown command \(cmd)")
}
