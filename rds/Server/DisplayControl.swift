//
//  DisplayControl.swift
//  MacRDP
//
//  Phase 3: DISP dynamic virtual channel handler.
//
//  Mapping flow:
//    1. At session activation (Phase 1/3), DisplayMapping is populated:
//       rdpSlot 0..N-1  <->  CGDirectDisplayID.
//       Phase 1 binds a single slot to config.display.captureDisplayID
//       (or CGMainDisplayID() if 0). Phase 8 binds one slot per
//       captured SCDisplay.
//    2. Client sends DISPLAYCONTROL_MONITOR_LAYOUT_PDU. The C bridge
//       hands us the raw [MonitorLayout] keyed by rdpSlot only.
//    3. We use DisplayMapping.decorate(...) to fill in displayID per
//       slot, then invoke the resize hook with the full layout.
//    4. After the hook returns, we wait for SCDisplay dimensions to
//       reflect the change, rebuild capture/encoder, and send the
//       client a RDPGFX RESETGRAPHICS.
//
//  Phase 0a: declarations only.
//

import Foundation
import CoreGraphics
import ScreenCaptureKit
import os

@MainActor
final class DisplayControl {
    private let config: Config
    private let pipeline: DisplayPipeline
    private var mapping: DisplayMapping

    init(config: Config, pipeline: DisplayPipeline, mapping: DisplayMapping) {
        self.config = config
        self.pipeline = pipeline
        self.mapping = mapping
    }

    /// Update the mapping (e.g. when we re-advertise a new monitor layout
    /// after a Phase 8 multi-monitor reconfiguration).
    func setMapping(_ m: DisplayMapping) { self.mapping = m }

    /// Handle a DISPLAYCONTROL_MONITOR_LAYOUT_PDU from the client.
    /// `raw` carries one entry per requested monitor, with rdpSlot set
    /// by the C bridge but displayID left at 0 — we fill it in here.
    func handleClientResize(raw: [MonitorLayout]) async {
        let decorated = mapping.decorate(raw)
        guard !decorated.isEmpty else {
            Log.resize.error("Client resize: no monitors matched our slot mapping (raw=\(raw.count, privacy: .public))")
            return
        }
        let request = MonitorLayoutRequest(version: 1, monitors: decorated)

        guard let template = config.display.resizeHook else {
            Log.resize.error("Client requested resize but no resize_hook configured")
            return
        }
        let hook = ResizeHook(template: template,
                              timeoutSeconds: config.display.resizeTimeoutSeconds)
        do {
            try await hook.run(request)
        } catch {
            Log.resize.error("Resize hook failed: \(String(describing: error), privacy: .public)")
            return
        }

        // TODO(Phase 3): poll the bound CGDirectDisplayID(s) until their
        // CGDisplayPixelsWide/High match the requested size (max
        // config.display.resizeTimeoutSeconds), then drive
        //   pipeline.resize(width:height:)
        //   send RDPGFX_CMDID_RESETGRAPHICS.
        // TODO(Phase 8): fan out across decorated.monitors with one
        //                encoder + surface per displayID.
        guard let primary = request.primary else { return }
        do {
            try await pipeline.resize(width: primary.width,
                                      height: primary.height)
        } catch {
            Log.resize.error("Pipeline resize failed: \(String(describing: error), privacy: .public)")
        }
    }
}
