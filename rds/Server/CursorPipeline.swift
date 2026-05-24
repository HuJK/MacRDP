//
//  CursorPipeline.swift
//  MacRDP
//
//  Drives the RDP pointer channel (hardware cursor). A timer on the main
//  queue polls the cursor position (cheap) and shape-change token; when the
//  shape changes it fetches the bitmap and sends it out-of-band so the client
//  renders the cursor locally — removing mouse-move churn from the captured
//  frame (which is captured with showsCursor=false).
//

#if MACRDP_BRIDGE_AVAILABLE

import Foundation
import AppKit
import CoreGraphics
import os

final class CursorPipeline: @unchecked Sendable {
    private let bridge: BridgePeer
    private let source = CursorSource()
    private let cfg: Config.CursorConfig

    private var timer: DispatchSourceTimer?

    // Geometry for screen→surface mapping (updated from the resolve callback,
    // read on the timer thread → guarded).
    private let geomLock = NSLock()
    private var surfaceW = 0
    private var surfaceH = 0
    private var displayID: CGDirectDisplayID = 0

    // Timer-thread-only state.
    private var lastToken = Int.min
    private var lastHash: UInt64 = 0
    private var hadCursor = false
    private var lastX = Int.min
    private var lastY = Int.min

    init(bridge: BridgePeer, config: Config.CursorConfig) {
        self.bridge = bridge
        self.cfg = config
    }

    func updateGeometry(surfaceWidth: Int, surfaceHeight: Int, displayID: CGDirectDisplayID) {
        geomLock.lock()
        surfaceW = surfaceWidth; surfaceH = surfaceHeight; self.displayID = displayID
        geomLock.unlock()
    }

    func start() {
        guard cfg.hardwareCursor, timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        let interval = max(1, cfg.pollIntervalMs)
        t.schedule(deadline: .now(), repeating: .milliseconds(interval), leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        if cfg.streamPosition { pollPosition() }
        pollShape()
    }

    private func pollPosition() {
        geomLock.lock()
        let sw = surfaceW, sh = surfaceH, did = displayID
        geomLock.unlock()
        guard sw > 0, sh > 0, did != 0 else { return }
        // CGEvent location is global, top-left origin, in points — same space
        // as CGDisplayBounds.
        guard let loc = CGEvent(source: nil)?.location else { return }
        let b = CGDisplayBounds(did)
        guard b.width > 0, b.height > 0 else { return }
        let relX = (loc.x - b.minX) / b.width
        let relY = (loc.y - b.minY) / b.height
        guard relX >= 0, relX <= 1, relY >= 0, relY <= 1 else { return }  // on another display
        let sx = min(sw - 1, max(0, Int((relX * Double(sw)).rounded())))
        let sy = min(sh - 1, max(0, Int((relY * Double(sh)).rounded())))
        if sx != lastX || sy != lastY {
            lastX = sx; lastY = sy
            bridge.sendPointerPosition(x: sx, y: sy)
        }
    }

    private func pollShape() {
        let token = source.changeToken()
        // With a valid seed, skip when unchanged. Token -1 = no seed → always
        // fetch and dedupe by hash below.
        if token >= 0 && token == lastToken { return }
        lastToken = token

        if let img = source.currentCursor() {
            let h = CursorSource.hash(img)
            if h != lastHash || !hadCursor {
                lastHash = h
                hadCursor = true
                bridge.sendPointerShape(width: img.width, height: img.height,
                                        hotX: img.hotX, hotY: img.hotY,
                                        bgra: img.bgra, allowLarge: cfg.allowLargePointer)
            }
        } else if hadCursor {
            hadCursor = false
            bridge.sendPointerHidden()
        }
    }
}

#endif  // MACRDP_BRIDGE_AVAILABLE
