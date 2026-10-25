//
//  CompositorNudge.swift
//  MacRDP
//
//  ScreenCaptureKit hands over a frame only once the window server has
//  composited the next one (seen in a Virtualization.framework guest): a lone
//  change — a typed character, a clicked button, the last frame of an
//  animation — sits in SCK until something else on screen changes, which can
//  be seconds later, and the client shows the old picture until then.
//
//  So keep a 1-pixel window on the captured display, excluded from capture,
//  and flip its colour every `interval`: there always is a next composite,
//  and a held frame comes out within one interval. Costs one tiny composite
//  per tick while a session captures.
//

import AppKit
import ScreenCaptureKit

@MainActor
final class CompositorNudge {
    private let window: NSWindow
    private var timer: Timer?
    private var phase = false

    var windowID: CGWindowID { CGWindowID(window.windowNumber) }

    init(display: CGDirectDisplayID, intervalMs: Int) {
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display
        } ?? NSScreen.main
        let frame = screen?.frame ?? .zero
        window = NSWindow(contentRect: NSRect(x: frame.minX, y: frame.maxY - 1, width: 1, height: 1),
                          styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.backgroundColor = NSColor(white: 0, alpha: 0.01)
        window.orderFrontRegardless()

        let t = Timer(timeInterval: Double(intervalMs) / 1000, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.flip() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func flip() {
        phase.toggle()
        window.backgroundColor = NSColor(white: phase ? 1 : 0, alpha: 0.01)
    }

    /// The window as SCK knows it, for the capture filter to exclude. It can
    /// take a moment to show up in shareable content after ordering front.
    func shareableWindow() async -> SCWindow? {
        for _ in 0..<10 {
            if let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
               let w = content.windows.first(where: { $0.windowID == windowID }) {
                return w
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return nil
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        window.orderOut(nil)
    }
}
