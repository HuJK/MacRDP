//
//  MonitorLayout.swift
//  MacRDP
//
//  Wire-format-agnostic monitor layout used end-to-end:
//   - parsed from the DISP DISPLAYCONTROL_MONITOR_LAYOUT_PDU (Phase 3)
//   - passed to ResizeHook (Phase 3)
//   - drives DisplayPipeline reconfiguration (Phase 3 / Phase 8 multi-mon)
//
//  Each MonitorLayout entry carries BOTH:
//    - `rdpSlot`   — the index the RDP client uses to address this monitor
//                    in subsequent DISP / GFX-MapSurfaceToOutput PDUs.
//    - `displayID` — the macOS CGDirectDisplayID our session has bound to
//                    that slot. Stable for the lifetime of the session.
//
//  The hook gets both, so user scripts / driver glue can map an RDP
//  resize event back to the right virtual head.
//
//  Schema is versioned via `MonitorLayoutRequest.version` so future
//  additions don't break user resize hooks.
//

import Foundation

struct MonitorLayout: Codable, Sendable, Hashable {
    /// RDP-side slot. The client refers to this monitor by index in
    /// DISPLAYCONTROL / RDPGFX PDUs.
    var rdpSlot: Int

    /// macOS-side CGDirectDisplayID that this slot is bound to in the
    /// current session. The user's driver glue uses this to know
    /// *which* virtual head to update.
    /// In Phase 1 (single-monitor) every layout request will carry this
    /// for the one display we capture; in Phase 8 multi-monitor each
    /// slot gets its own ID.
    var displayID: UInt32

    /// Top-left in virtual-desktop coordinates (pixels).
    var x: Int
    var y: Int
    var width: Int
    var height: Int
    /// Vertical refresh in Hz. Often 0 in DISP PDUs (clients rarely set
    /// it); we substitute config.video.maxFps when 0.
    var refreshHz: Int
    /// 0 / 90 / 180 / 270.
    var orientation: Int = 0
    /// DesktopScaleFactor / 100.
    var scale: Double = 1.0
    /// DeviceScaleFactor / 100.
    var deviceScale: Double = 1.0
    var physicalWidthMm: Int?
    var physicalHeightMm: Int?
    var primary: Bool = false
}

struct MonitorLayoutRequest: Codable, Sendable {
    /// Schema version. Hook scripts should reject unknown majors.
    var version: Int = 1
    var monitors: [MonitorLayout]

    var primary: MonitorLayout? {
        monitors.first(where: { $0.primary }) ?? monitors.first
    }
}

/// Per-session mapping of RDP slot -> macOS CGDirectDisplayID.
/// Owned by RDPSession; built at connect time from the
/// initial multi-monitor advertisement and consulted on every
/// DISP layout update from the client.
struct DisplayMapping: Sendable {
    private var slotToDisplay: [Int: UInt32] = [:]
    private var displayToSlot: [UInt32: Int] = [:]

    mutating func bind(rdpSlot: Int, displayID: UInt32) {
        slotToDisplay[rdpSlot] = displayID
        displayToSlot[displayID] = rdpSlot
    }

    func displayID(forSlot rdpSlot: Int) -> UInt32? {
        slotToDisplay[rdpSlot]
    }

    func slot(forDisplay displayID: UInt32) -> Int? {
        displayToSlot[displayID]
    }

    func hasSlot(_ rdpSlot: Int) -> Bool {
        slotToDisplay[rdpSlot] != nil
    }

    var boundSlots: [Int] { Array(slotToDisplay.keys).sorted() }

    var count: Int { slotToDisplay.count }

    /// Decorate a raw DISP-derived layout with our per-session
    /// displayID assignments. Layouts missing a slot are dropped.
    func decorate(_ raw: [MonitorLayout]) -> [MonitorLayout] {
        raw.compactMap { entry in
            guard let id = slotToDisplay[entry.rdpSlot] else { return nil }
            var copy = entry
            copy.displayID = id
            return copy
        }
    }
}
