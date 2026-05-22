//
//  DisplayBindingResolver.swift
//  MacRDP
//
//  Turns three inputs into a per-session DisplayMapping:
//
//    1. The list of macOS displays available right now
//       (a snapshot of SCShareableContent.displays / CGGetActiveDisplayList,
//       always with the main display present and flagged).
//    2. The number of RDP monitor channels we're going to advertise to
//       the client (1 in Phase 1, ≤16 in Phase 8 — bounded by RDP's max
//       monitor count and the client's TS_UD_CS_CORE.max_monitor_count).
//    3. The optional `Config.DisplayConfig.monitors` array of explicit
//       bindings.
//
//  Rules (documented and unit-test-shaped):
//
//    - Without an explicit `monitors` config, we auto-bind in
//      *deterministic* order: primary first, then the rest sorted by
//      displayID ascending. That avoids relying on the undocumented
//      order returned by CGGetActiveDisplayList / SCShareableContent.
//    - With `monitors`, config-specified bindings take precedence.
//      Unspecified slots are filled from the remaining auto-ordered
//      displays.
//    - If we run out of macOS displays before all RDP slots are bound,
//      the resulting mapping has fewer entries than `channelCount` —
//      higher layers cap their advertisement to `mapping.count`.
//    - Config bindings that reference an unknown displayID are logged
//      and skipped (slot falls through to auto-fill).
//    - Phase 1 (single-monitor) uses channelCount=1 + the legacy
//      `captureDisplayID` shorthand, see `forSingleMonitor(...)`.
//

import Foundation
import os

struct AvailableDisplay: Sendable, Equatable {
    let displayID: UInt32
    let isPrimary: Bool
}

enum DisplayBindingResolver {

    /// Auto-ordered: primary first, then by displayID ascending.
    static func autoOrder(_ displays: [AvailableDisplay]) -> [UInt32] {
        let primary = displays.first(where: { $0.isPrimary })?.displayID
        let rest = displays
            .filter { !$0.isPrimary }
            .map { $0.displayID }
            .sorted()
        if let p = primary { return [p] + rest }
        return rest
    }

    /// Resolve a binding for the *initial* monitor advertisement.
    ///
    /// - Parameters:
    ///   - channelCount: how many RDP monitor slots we want to advertise.
    ///                   The result may bind FEWER slots if macOS doesn't
    ///                   have enough displays to satisfy the request.
    ///   - displays: macOS displays available right now.
    ///   - configBindings: optional `config.display.monitors`.
    /// - Returns: A `DisplayMapping` containing 0..<min(channelCount, available) bindings.
    static func resolve(
        channelCount: Int,
        displays: [AvailableDisplay],
        configBindings: [Config.MonitorBinding]?
    ) -> DisplayMapping {
        var mapping = DisplayMapping()
        let ordered = autoOrder(displays)
        let primary = displays.first(where: { $0.isPrimary })?.displayID

        // 1. Honor explicit bindings first.
        var consumed = Set<UInt32>()
        var slotsTaken = Set<Int>()
        if let bindings = configBindings {
            for b in bindings {
                guard (0..<channelCount).contains(b.rdpSlot) else {
                    Log.config.error("display.monitors: rdpSlot \(b.rdpSlot, privacy: .public) out of range [0, \(channelCount, privacy: .public)), skipping")
                    continue
                }
                if slotsTaken.contains(b.rdpSlot) {
                    Log.config.error("display.monitors: rdpSlot \(b.rdpSlot, privacy: .public) bound twice, ignoring later entry")
                    continue
                }
                let resolved: UInt32?
                switch b.macDisplay {
                case .main:
                    resolved = primary
                case .displayID(let id):
                    resolved = displays.contains(where: { $0.displayID == id }) ? id : nil
                case .orderedIndex(let i):
                    resolved = (0..<ordered.count).contains(i) ? ordered[i] : nil
                }
                guard let id = resolved else {
                    Log.config.error("display.monitors: macDisplay \(String(describing: b.macDisplay), privacy: .public) unresolved for rdpSlot \(b.rdpSlot, privacy: .public), will auto-fill")
                    continue
                }
                if consumed.contains(id) {
                    Log.config.error("display.monitors: displayID \(id, privacy: .public) bound twice, ignoring rdpSlot \(b.rdpSlot, privacy: .public)")
                    continue
                }
                mapping.bind(rdpSlot: b.rdpSlot, displayID: id)
                consumed.insert(id)
                slotsTaken.insert(b.rdpSlot)
            }
        }

        // 2. Auto-fill remaining slots from the auto-ordered list.
        var autoIter = ordered.makeIterator()
        for slot in 0..<channelCount where !slotsTaken.contains(slot) {
            while let id = autoIter.next() {
                if consumed.contains(id) { continue }
                mapping.bind(rdpSlot: slot, displayID: id)
                consumed.insert(id)
                break
            }
            // If we ran out of macOS displays, we're done — the resulting
            // mapping will have fewer entries than channelCount, and the
            // caller advertises only `mapping.count` monitors.
            if !mapping.hasSlot(slot) { break }
        }

        if mapping.count < channelCount {
            Log.config.notice("Bound only \(mapping.count, privacy: .public) of \(channelCount, privacy: .public) requested RDP monitor slot(s); macOS has \(displays.count, privacy: .public) display(s) available")
        }
        return mapping
    }

    /// Phase-1 convenience: resolve a single-monitor mapping using the
    /// legacy `captureDisplayID` shorthand. Falls back to primary.
    static func forSingleMonitor(
        captureDisplayID: UInt32,
        displays: [AvailableDisplay]
    ) -> DisplayMapping {
        var mapping = DisplayMapping()
        let primary = displays.first(where: { $0.isPrimary })?.displayID
        if captureDisplayID != 0,
           displays.contains(where: { $0.displayID == captureDisplayID }) {
            mapping.bind(rdpSlot: 0, displayID: captureDisplayID)
        } else if let p = primary {
            mapping.bind(rdpSlot: 0, displayID: p)
        }
        return mapping
    }
}
