//
//  CameraViewWindow.swift
//  MacRDP
//
//  Live view of a client's redirected camera. The H.264 samples arriving over
//  the RDPECAM media channel are decoded and shown DIRECTLY here (via
//  AVSampleBufferDisplayLayer) — they do NOT go through the system / a virtual
//  camera device. Purpose: confirm "is the client's camera actually coming
//  through?" from the menu bar.
//
//  Each sample is an Annex-B H.264 elementary stream: we split NAL units, cache
//  SPS/PPS to build a CMVideoFormatDescription, and feed VCL NALs as
//  length-prefixed (AVCC) CMSampleBuffers tagged display-immediately.
//

import AppKit
import AVFoundation
import CoreMedia

@MainActor
final class CameraViewWindowController: NSWindowController, NSWindowDelegate {

    var onClose: (() -> Void)?
    private let videoView = CameraVideoView()

    init(title: String) {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        win.title = title
        win.isReleasedWhenClosed = false
        win.center()
        super.init(window: win)
        win.delegate = self
        win.contentView = videoView
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Feed one Annex-B H.264 sample. Called on MainActor.
    func enqueue(_ annexB: Data) { videoView.enqueue(annexB) }

    func windowWillClose(_ notification: Notification) { onClose?() }
}

// MARK: - Decoding view

private final class CameraVideoView: NSView {
    private let displayLayer = AVSampleBufferDisplayLayer()
    private var sps: [UInt8]?
    private var pps: [UInt8]?
    private var formatDesc: CMFormatDescription?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        let root = CALayer()
        root.backgroundColor = NSColor.black.cgColor
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
        root.addSublayer(displayLayer)
        layer = root
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        displayLayer.frame = bounds
    }

    func enqueue(_ data: Data) {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            let buf = UnsafeBufferPointer(start: base, count: raw.count)
            forEachNAL(buf) { handleNAL($0) }
        }
    }

    /// Walk Annex-B NAL units (3- or 4-byte start codes).
    private func forEachNAL(_ b: UnsafeBufferPointer<UInt8>,
                            _ body: (UnsafeBufferPointer<UInt8>) -> Void) {
        let n = b.count
        func startLen(_ p: Int) -> Int {
            if p + 3 <= n, b[p] == 0, b[p + 1] == 0, b[p + 2] == 1 { return 3 }
            if p + 4 <= n, b[p] == 0, b[p + 1] == 0, b[p + 2] == 0, b[p + 3] == 1 { return 4 }
            return 0
        }
        var i = 0
        var nalStart = -1
        while i < n {
            let sc = startLen(i)
            if sc > 0 {
                if nalStart >= 0, i > nalStart {
                    body(UnsafeBufferPointer(rebasing: b[nalStart..<i]))
                }
                i += sc
                nalStart = i
            } else {
                i += 1
            }
        }
        if nalStart >= 0, nalStart < n {
            body(UnsafeBufferPointer(rebasing: b[nalStart..<n]))
        }
    }

    private func handleNAL(_ nal: UnsafeBufferPointer<UInt8>) {
        guard let first = nal.first else { return }
        switch first & 0x1F {
        case 7: sps = Array(nal); rebuildFormat()
        case 8: pps = Array(nal); rebuildFormat()
        case 1, 5: enqueueVCL(nal)
        default: break   // SEI / AUD / etc.
        }
    }

    private func rebuildFormat() {
        guard let sps, let pps else { return }
        var fmt: CMFormatDescription?
        let status = sps.withUnsafeBufferPointer { sp in
            pps.withUnsafeBufferPointer { pp in
                let pointers = [sp.baseAddress!, pp.baseAddress!]
                let sizes = [sp.count, pp.count]
                return pointers.withUnsafeBufferPointer { pPtr in
                    sizes.withUnsafeBufferPointer { sPtr in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: pPtr.baseAddress!,
                            parameterSetSizes: sPtr.baseAddress!,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &fmt)
                    }
                }
            }
        }
        if status == noErr { formatDesc = fmt }
    }

    private func enqueueVCL(_ nal: UnsafeBufferPointer<UInt8>) {
        guard let formatDesc else { return }   // need SPS/PPS first

        // AVCC: 4-byte big-endian length prefix + NAL payload.
        var avcc = [UInt8](repeating: 0, count: 4 + nal.count)
        let len = UInt32(nal.count)
        avcc[0] = UInt8((len >> 24) & 0xFF)
        avcc[1] = UInt8((len >> 16) & 0xFF)
        avcc[2] = UInt8((len >> 8) & 0xFF)
        avcc[3] = UInt8(len & 0xFF)
        if let src = nal.baseAddress {
            avcc.withUnsafeMutableBytes { memcpy($0.baseAddress!.advanced(by: 4), src, nal.count) }
        }

        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: avcc.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: avcc.count, flags: 0,
            blockBufferOut: &blockBuffer) == kCMBlockBufferNoErr, let blockBuffer
        else { return }
        guard CMBlockBufferReplaceDataBytes(
            with: avcc, blockBuffer: blockBuffer, offsetIntoDestination: 0,
            dataLength: avcc.count) == kCMBlockBufferNoErr else { return }

        var sampleBuffer: CMSampleBuffer?
        var sizes = [avcc.count]
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: blockBuffer,
            formatDescription: formatDesc, sampleCount: 1,
            sampleTimingEntryCount: 0, sampleTimingArray: nil,
            sampleSizeEntryCount: 1, sampleSizeArray: &sizes,
            sampleBufferOut: &sampleBuffer) == noErr, let sampleBuffer
        else { return }

        // No PTS — tell the layer to show each frame as it arrives.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0),
                                     to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }

        if displayLayer.status == .failed { displayLayer.flush() }
        displayLayer.enqueue(sampleBuffer)
    }
}
