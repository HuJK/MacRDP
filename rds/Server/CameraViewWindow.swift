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
//  Each sample is one Annex-B H.264 access unit, which H264SampleBuilder (see
//  CameraFrameDecoder.swift) turns into one sample buffer, shown with
//  display-immediately.
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
    private var builder = H264SampleBuilder()
    private var reportedFailure = false

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
        guard let sampleBuffer = builder.sampleBuffer(for: data) else { return }

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

        if displayLayer.status == .failed {
            if !reportedFailure {
                reportedFailure = true
                LogTo.session.error("Camera view: decoding failed: \(String(describing: self.displayLayer.error))")
            }
            displayLayer.flush()
        }
        displayLayer.enqueue(sampleBuffer)
    }
}
