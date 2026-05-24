//
//  DisplayModeController.swift
//  MacRDP
//
//  Resize policy for a client desktop-resize (DISP) request, plus the
//  "setOnServer" implementation: change the macOS display mode to the largest
//  available resolution that fits the client's pixels, DPI-aware.
//
//  Mode changes made with CGDisplaySetDisplayMode(.., nil) are per-process and
//  macOS auto-reverts them when we exit; we also restore explicitly on
//  disconnect (the daemon outlives a session).
//

import Foundation
import CoreGraphics
import os

/// How to react to a client desktop-resize request.
enum ResizePolicy: String {
    case none
    case resize          // GPU resample to client size before encode
    case setOnServer     // change the macOS display mode to best fit
    case cliCommand      // run the resize hook (e.g. virtual-display driver)

    init(_ raw: String) {
        switch raw.lowercased() {
        case "none":        self = .none
        case "setonserver": self = .setOnServer
        case "clicommand":  self = .cliCommand
        default:            self = .resize
        }
    }
}

@MainActor
final class DisplayModeController {
    enum HiDPIPolicy {
        case client, force, off
        init(_ raw: String) {
            switch raw.lowercased() {
            case "force": self = .force
            case "off":   self = .off
            default:      self = .client
            }
        }
    }

    private let hidpi: HiDPIPolicy
    /// Original mode per display, captured before our first change, for restore.
    private var saved: [CGDirectDisplayID: CGDisplayMode] = [:]

    init(hidpiPolicy: String) { self.hidpi = HiDPIPolicy(hidpiPolicy) }

    /// Pick + apply the largest mode whose pixels fit the client, honoring DPI.
    /// Returns the chosen pixel size, or nil if nothing was changed.
    @discardableResult
    func applyBestFit(displayID: CGDirectDisplayID,
                      clientPixelW: Int, clientPixelH: Int,
                      desktopScale: Double) -> (w: Int, h: Int)? {
        guard clientPixelW > 0, clientPixelH > 0 else { return nil }
        let opts = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, opts) as? [CGDisplayMode] else {
            Log.resize.error("setOnServer: CGDisplayCopyAllDisplayModes returned nil for \(displayID, privacy: .public)")
            return nil
        }

        // Client DPI → desired backing scale (macOS is effectively 1× or 2×).
        let wantHiDPI: Bool
        switch hidpi {
        case .force: wantHiDPI = true
        case .off:   wantHiDPI = false
        case .client: wantHiDPI = desktopScale >= 1.5
        }

        let fits = modes.filter {
            $0.isUsableForDesktopGUI()
            && $0.pixelWidth <= clientPixelW
            && $0.pixelHeight <= clientPixelH
        }
        guard !fits.isEmpty else {
            Log.resize.notice("setOnServer: no mode fits \(clientPixelW, privacy: .public)x\(clientPixelH, privacy: .public); leaving display unchanged")
            return nil
        }

        // Rank: matching HiDPI intent first, then larger pixel area, then refresh.
        func backingScale(_ m: CGDisplayMode) -> Double {
            Double(m.pixelWidth) / Double(max(1, m.width))
        }
        func score(_ m: CGDisplayMode) -> (Int, Int, Double) {
            let isHiDPI = backingScale(m) >= 1.5
            let match = (isHiDPI == wantHiDPI) ? 1 : 0
            return (match, m.pixelWidth * m.pixelHeight, m.refreshRate)
        }
        guard let chosen = fits.max(by: { score($0) < score($1) }) else { return nil }

        let pw = chosen.pixelWidth
        let ph = chosen.pixelHeight

        // Already in this mode? Nothing to do (but report the size).
        if let cur = CGDisplayCopyDisplayMode(displayID), sameMode(cur, chosen) {
            return (pw, ph)
        }
        if saved[displayID] == nil, let cur = CGDisplayCopyDisplayMode(displayID) {
            saved[displayID] = cur
        }
        let rc = CGDisplaySetDisplayMode(displayID, chosen, nil)
        guard rc == .success else {
            Log.resize.error("setOnServer: CGDisplaySetDisplayMode failed rc=\(rc.rawValue, privacy: .public)")
            return nil
        }
        Log.resize.info("setOnServer: display \(displayID, privacy: .public) → \(pw, privacy: .public)x\(ph, privacy: .public)px (wantHiDPI=\(wantHiDPI, privacy: .public))")
        return (pw, ph)
    }

    /// Restore every display we changed back to its original mode.
    func restoreAll() {
        for (id, mode) in saved {
            _ = CGDisplaySetDisplayMode(id, mode, nil)
        }
        saved.removeAll()
    }

    private func sameMode(_ a: CGDisplayMode, _ b: CGDisplayMode) -> Bool {
        a.pixelWidth == b.pixelWidth && a.pixelHeight == b.pixelHeight
        && a.width == b.width && a.refreshRate == b.refreshRate
    }
}
