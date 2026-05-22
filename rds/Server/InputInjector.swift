//
//  InputInjector.swift
//  MacRDP
//
//  RDP input PDUs -> CGEvents.
//
//  Mouse: PTRFLAGS_MOVE / DOWN / WHEEL / BUTTON1..3 / HWHEEL  (TS_POINTER_EVENT)
//  Keyboard: KBDFLAGS_EXTENDED + scancode (PS/2 set 1)        (TS_KEYBOARD_EVENT)
//  Unicode: 16-bit code unit                                  (TS_UNICODE_EVENT)
//
//  Requires Accessibility permission to actually post events.
//

import Foundation
@preconcurrency import CoreGraphics
import AppKit
import IOKit
import os

// Mirror of FreeRDP / MS-RDPBCGR PTRFLAGS values; values are spec-defined.
private struct PTRFLAGS {
    static let MOVE       : UInt16 = 0x0800
    static let WHEEL      : UInt16 = 0x0200
    static let HWHEEL     : UInt16 = 0x0400
    static let DOWN       : UInt16 = 0x8000
    static let BUTTON1    : UInt16 = 0x1000
    static let BUTTON2    : UInt16 = 0x2000
    static let BUTTON3    : UInt16 = 0x4000
    static let WHEEL_NEGATIVE: UInt16 = 0x0100
    static let WHEEL_ROTATION_MASK: UInt16 = 0x01FF
}

private struct PTRXFLAGS {
    static let DOWN    : UInt16 = 0x8000
    static let BUTTON1 : UInt16 = 0x0001    // XBUTTON1
    static let BUTTON2 : UInt16 = 0x0002    // XBUTTON2
}

private struct KBDFLAGS {
    static let RELEASE  : UInt16 = 0x8000
    static let EXTENDED : UInt16 = 0x0100
    static let EXTENDED1: UInt16 = 0x0200
}

final class InputInjector: @unchecked Sendable {
    private let surfaceWidth: Int
    private let surfaceHeight: Int
    private let outputDisplayBounds: CGRect
    private let wheelPixelsPerNotch: Int

    /// Track current mouse position to map MOVE-less button events.
    private var lastCursor: CGPoint = .zero
    /// Track button state so MOVE while a button is held emits a
    /// .leftMouseDragged / .rightMouseDragged event (not .mouseMoved),
    /// which is what AppKit needs to recognise a window drag.
    private var leftDown   = false
    private var rightDown  = false
    private var centerDown = false

    /// Click-count tracking for double/triple-click recognition. macOS
    /// apps key off `kCGMouseEventClickState`, not just timing — we
    /// MUST set this field or Finder won't open folders, NSTableView
    /// won't trigger double-click actions, etc. Tracked per button.
    private struct ClickState {
        var lastUpTime: CFAbsoluteTime = 0
        var lastDownPoint: CGPoint = .zero
        var count: Int = 0
    }
    private var leftClick = ClickState()
    private var rightClick = ClickState()
    private var centerClick = ClickState()
    /// Pixel slop allowed between consecutive clicks. Matches macOS's
    /// implicit slop (~4 logical points on standard mice, more for
    /// trackpads; we use a generous value because RDP coordinates can
    /// jitter slightly after the aspect-fit transform).
    private let clickSlopPixels: CGFloat = 5
    /// macOS's system double-click interval (typically 0.5s). Read once;
    /// users rarely change it mid-session.
    private let doubleClickInterval: TimeInterval = NSEvent.doubleClickInterval

    init(surfaceWidth: Int, surfaceHeight: Int,
         outputDisplayBounds: CGRect,
         wheelPixelsPerNotch: Int) {
        self.surfaceWidth = surfaceWidth
        self.surfaceHeight = surfaceHeight
        self.outputDisplayBounds = outputDisplayBounds
        self.wheelPixelsPerNotch = wheelPixelsPerNotch
    }

    static func hasAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
    }

    // MARK: - Mouse

    func mouseEvent(flags: UInt16, x: Int, y: Int) {
        if flags & PTRFLAGS.WHEEL != 0 || flags & PTRFLAGS.HWHEEL != 0 {
            // Wheel events don't carry position; use last known cursor.
            postWheel(flags: flags)
            return
        }

        let pt = mapToScreen(x: x, y: y)
        lastCursor = pt

        // Process buttons first so the MOVE-as-drag branch below sees
        // up-to-date button state.
        let isDown = flags & PTRFLAGS.DOWN != 0
        if flags & PTRFLAGS.BUTTON1 != 0 {
            leftDown = isDown
            postButton(button: .left, down: isDown, at: pt)
        }
        if flags & PTRFLAGS.BUTTON2 != 0 {
            rightDown = isDown
            postButton(button: .right, down: isDown, at: pt)
        }
        if flags & PTRFLAGS.BUTTON3 != 0 {
            centerDown = isDown
            postButton(button: .center, down: isDown, at: pt)
        }

        if flags & PTRFLAGS.MOVE != 0 {
            // If a button is held, this is a drag — AppKit window-drag
            // tracking listens for .leftMouseDragged, NOT .mouseMoved.
            let type: CGEventType
            let button: CGMouseButton
            if leftDown        { type = .leftMouseDragged;  button = .left }
            else if rightDown  { type = .rightMouseDragged; button = .right }
            else if centerDown { type = .otherMouseDragged; button = .center }
            else               { type = .mouseMoved;        button = .left }
            post(type: type, button: button, at: pt)
        }
    }

    func extendedMouseEvent(flags: UInt16, x: Int, y: Int) {
        let pt = mapToScreen(x: x, y: y)
        lastCursor = pt
        let isDown = flags & PTRXFLAGS.DOWN != 0
        if flags & PTRXFLAGS.BUTTON1 != 0 {
            postExtraButton(buttonNumber: 3, down: isDown, at: pt)
        }
        if flags & PTRXFLAGS.BUTTON2 != 0 {
            postExtraButton(buttonNumber: 4, down: isDown, at: pt)
        }
    }

    private func mapToScreen(x: Int, y: Int) -> CGPoint {
        let fx = max(0, min(surfaceWidth, x))
        let fy = max(0, min(surfaceHeight, y))
        // x in [0..surfaceWidth] maps linearly to [bounds.minX..maxX].
        let sx = outputDisplayBounds.minX
              + (CGFloat(fx) / CGFloat(max(1, surfaceWidth)))
              * outputDisplayBounds.width
        let sy = outputDisplayBounds.minY
              + (CGFloat(fy) / CGFloat(max(1, surfaceHeight)))
              * outputDisplayBounds.height
        return CGPoint(x: sx, y: sy)
    }

    private func post(type: CGEventType, button: CGMouseButton, at pt: CGPoint,
                      clickCount: Int = 1) {
        guard let e = CGEvent(mouseEventSource: nil, mouseType: type,
                              mouseCursorPosition: pt,
                              mouseButton: button) else { return }
        if clickCount > 1 {
            e.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        }
        e.post(tap: .cghidEventTap)
    }

    private func postButton(button: CGMouseButton, down: Bool, at pt: CGPoint) {
        let type: CGEventType
        switch (button, down) {
        case (.left,  true):  type = .leftMouseDown
        case (.left,  false): type = .leftMouseUp
        case (.right, true):  type = .rightMouseDown
        case (.right, false): type = .rightMouseUp
        case (.center, true), (_, true):  type = .otherMouseDown
        case (.center, false), (_, false): type = .otherMouseUp
        }
        let count = updateClickState(button: button, down: down, at: pt)
        post(type: type, button: button, at: pt, clickCount: count)
    }

    /// Compute the click count to attach to this event. On DOWN we
    /// decide whether this is a continuation of a recent click (close
    /// in time + position) and bump the counter; on UP we just echo
    /// the current counter so a paired down/up share the same count.
    private func updateClickState(button: CGMouseButton, down: Bool, at pt: CGPoint) -> Int {
        // Pick the right tracker by button.
        func update(_ state: inout ClickState) -> Int {
            if down {
                let now = CFAbsoluteTimeGetCurrent()
                let dt = now - state.lastUpTime
                let dx = pt.x - state.lastDownPoint.x
                let dy = pt.y - state.lastDownPoint.y
                let distSq = dx * dx + dy * dy
                let within = dt <= doubleClickInterval && distSq <= clickSlopPixels * clickSlopPixels
                state.count = within ? min(state.count + 1, 3) : 1
                state.lastDownPoint = pt
            } else {
                state.lastUpTime = CFAbsoluteTimeGetCurrent()
            }
            return max(state.count, 1)
        }
        switch button {
        case .left:   return update(&leftClick)
        case .right:  return update(&rightClick)
        case .center: return update(&centerClick)
        default:      return 1
        }
    }

    private func postExtraButton(buttonNumber: Int, down: Bool, at pt: CGPoint) {
        let type: CGEventType = down ? .otherMouseDown : .otherMouseUp
        guard let e = CGEvent(mouseEventSource: nil, mouseType: type,
                              mouseCursorPosition: pt,
                              mouseButton: CGMouseButton(rawValue: UInt32(buttonNumber)) ?? .center) else { return }
        e.post(tap: .cghidEventTap)
    }

    /// Per MS-RDPBCGR § 2.2.8.1.1.3.1.1.3 (Pointer Event PDU):
    ///   - low 8 bits = magnitude (typically WHEEL_DELTA = 120 per notch)
    ///   - PTRFLAGS_WHEEL_NEGATIVE (0x0100) = sign bit (down/left)
    /// We map to pixel-unit scrolls — apps render those as the same smooth
    /// motion a Mac wheel mouse / trackpad would produce, regardless of
    /// per-app "line height". 1 notch → ~pixelsPerNotch screen pixels.
    private func postWheel(flags: UInt16) {
        let pixelsPerNotch = self.wheelPixelsPerNotch
        let magnitude = Int(flags & 0xFF)
        var raw = magnitude
        if flags & PTRFLAGS.WHEEL_NEGATIVE != 0 { raw = -raw }
        var pixels = raw * pixelsPerNotch / 120
        if pixels == 0 && raw != 0 {
            pixels = raw > 0 ? pixelsPerNotch : -pixelsPerNotch
        }
        let isHorizontal = flags & PTRFLAGS.HWHEEL != 0
        let wheel: CGEvent? = isHorizontal
            ? CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                      wheelCount: 2, wheel1: 0, wheel2: Int32(pixels), wheel3: 0)
            : CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                      wheelCount: 1, wheel1: Int32(pixels), wheel2: 0, wheel3: 0)
        wheel?.post(tap: .cghidEventTap)
    }

    // MARK: - Keyboard

    /// Modifier-key bookkeeping. Driven entirely by the RDP scancode
    /// stream — `nil` source CGEvents would otherwise inherit whatever
    /// macOS *thinks* is held, and a dropped key-up (e.g. client window
    /// loses focus mid-Cmd) leaves Cmd permanently sticky, so the next
    /// `e` becomes Cmd+E and lights up the Edit menu instead of typing.
    private struct ModifierState {
        var lShift = false, rShift = false
        var lCtrl  = false, rCtrl  = false
        var lAlt   = false, rAlt   = false
        var lCmd   = false, rCmd   = false
        var capsLock = false
        var flags: CGEventFlags {
            var f = CGEventFlags()
            if lShift || rShift { f.insert(.maskShift) }
            if lCtrl  || rCtrl  { f.insert(.maskControl) }
            if lAlt   || rAlt   { f.insert(.maskAlternate) }
            if lCmd   || rCmd   { f.insert(.maskCommand) }
            if capsLock         { f.insert(.maskAlphaShift) }
            return f
        }
    }
    private var mods = ModifierState()

    /// PS/2 set 1 scancode (with optional E0/E1 extended bits encoded into `flags`)
    /// -> macOS virtual keycode + post.
    func keyboardEvent(flags: UInt16, scancode: UInt16) {
        let extended = flags & KBDFLAGS.EXTENDED != 0
        let down = flags & KBDFLAGS.RELEASE == 0

        let combined = extended ? (UInt32(0xE0) << 8) | UInt32(scancode) : UInt32(scancode)

        // Update our modifier bookkeeping BEFORE we compose flags so
        // the press itself carries the new state (matches macOS's
        // own convention).
        updateModifierState(combined: combined, down: down)

        guard let mac = Self.scancodeToVirtualKey[combined] ?? Self.scancodeToVirtualKey[UInt32(scancode)] else {
            Log.input.debug("unmapped scancode \(scancode, format: .hex, privacy: .public) extended=\(extended, privacy: .public)")
            return
        }
        guard let e = CGEvent(keyboardEventSource: nil,
                              virtualKey: mac,
                              keyDown: down) else { return }
        e.flags = mods.flags
        e.post(tap: .cghidEventTap)
    }

    /// Inject a single UTF-16 code unit as a synthesized keypress.
    /// Unicode events from the client don't carry modifier scancodes,
    /// but we still apply our tracked flags so a held Shift from a
    /// prior scancode press is honored.
    func unicodeKeyboardEvent(flags: UInt16, code: UInt16) {
        let down = flags & KBDFLAGS.RELEASE == 0
        guard let e = CGEvent(keyboardEventSource: nil,
                              virtualKey: 0, keyDown: down) else { return }
        var c = code
        e.keyboardSetUnicodeString(stringLength: 1, unicodeString: &c)
        e.flags = mods.flags
        e.post(tap: .cghidEventTap)
    }

    private func updateModifierState(combined: UInt32, down: Bool) {
        switch combined {
        case 0x2A:           mods.lShift = down
        case 0x36:           mods.rShift = down
        case 0x1D:           mods.lCtrl  = down
        case 0xE000 | 0x1D:  mods.rCtrl  = down
        case 0x38:           mods.lAlt   = down   // also LeftCmd on some Mac clients
        case 0xE000 | 0x38:  mods.rAlt   = down
        case 0xE000 | 0x5B:  mods.lCmd   = down
        case 0xE000 | 0x5C:  mods.rCmd   = down
        case 0x3A:
            // Caps lock toggles only on key-down; ignore key-up.
            if down { mods.capsLock.toggle() }
        default:
            break
        }
    }

    /// Called when a peer disconnects (or we suspect the wire dropped
    /// a key-up). Posts synthetic releases for every modifier we think
    /// is currently held, then zeroes our bookkeeping. Without this
    /// the next session inherits sticky modifiers.
    func releaseAllModifiers() {
        let pairs: [(KeyPath<ModifierState, Bool>, CGKeyCode)] = [
            (\.lShift, 56), (\.rShift, 60),
            (\.lCtrl,  59), (\.rCtrl,  62),
            (\.lAlt,   58), (\.rAlt,   61),
            (\.lCmd,   55), (\.rCmd,   54),
        ]
        for (kp, vk) in pairs where mods[keyPath: kp] {
            if let e = CGEvent(keyboardEventSource: nil, virtualKey: vk, keyDown: false) {
                e.flags = []
                e.post(tap: .cghidEventTap)
            }
        }
        mods = ModifierState()
        Log.input.notice("Released all sticky modifiers")
    }

    /// PS/2 set 1 scan-code to macOS virtual-keycode mapping.
    /// Covers the common 100-ish keys. Entries with the 0xE000 prefix
    /// are "extended" scancodes (numpad, arrow keys, etc.).
    private static let scancodeToVirtualKey: [UInt32: CGKeyCode] = [
        0x01: 53,                                  // ESC
        0x02: 18, 0x03: 19, 0x04: 20, 0x05: 21, 0x06: 23,
        0x07: 22, 0x08: 26, 0x09: 28, 0x0A: 25, 0x0B: 29,    // 1..0
        0x0C: 27, 0x0D: 24,                                  // - =
        0x0E: 51,                                            // BS
        0x0F: 48,                                            // TAB
        0x10: 12, 0x11: 13, 0x12: 14, 0x13: 15, 0x14: 17,
        0x15: 16, 0x16: 32, 0x17: 34, 0x18: 31, 0x19: 35,    // q..p
        0x1A: 33, 0x1B: 30,                                  // [ ]
        0x1C: 36,                                            // Enter
        0x1D: 59,                                            // LCtrl
        0x1E: 0,  0x1F: 1,  0x20: 2,  0x21: 3,  0x22: 5,
        0x23: 4,  0x24: 38, 0x25: 40, 0x26: 37,              // a..l
        0x27: 41, 0x28: 39, 0x29: 50,                        // ; ' `
        0x2A: 56,                                            // LShift
        0x2B: 42,                                            // \
        0x2C: 6,  0x2D: 7,  0x2E: 8,  0x2F: 9,  0x30: 11,
        0x31: 45, 0x32: 46, 0x33: 43, 0x34: 47, 0x35: 44,    // z..,./
        0x36: 60,                                            // RShift
        0x37: 67,                                            // KP *
        0x38: 58,                                            // LAlt
        0x39: 49,                                            // Space
        0x3A: 57,                                            // Caps
        0x3B: 122, 0x3C: 120, 0x3D: 99,  0x3E: 118, 0x3F: 96,
        0x40: 97,  0x41: 98,  0x42: 100, 0x43: 101, 0x44: 109,    // F1..F10
        0x45: 71,                                            // NumLock
        0x46: 107,                                           // ScrollLock
        0x47: 89, 0x48: 91, 0x49: 92,                        // KP 7 8 9
        0x4A: 78,                                            // KP -
        0x4B: 86, 0x4C: 87, 0x4D: 88,                        // KP 4 5 6
        0x4E: 69,                                            // KP +
        0x4F: 83, 0x50: 84, 0x51: 85,                        // KP 1 2 3
        0x52: 82, 0x53: 65,                                  // KP 0 .
        0x57: 103, 0x58: 111,                                // F11 F12

        // Extended scancodes (E0 + ...)
        0xE01C: 76,                                          // KP Enter
        0xE01D: 62,                                          // RCtrl
        0xE035: 75,                                          // KP /
        0xE038: 61,                                          // RAlt
        0xE047: 115,                                         // Home
        0xE048: 126,                                         // Up
        0xE049: 116,                                         // PgUp
        0xE04B: 123,                                         // Left
        0xE04D: 124,                                         // Right
        0xE04F: 119,                                         // End
        0xE050: 125,                                         // Down
        0xE051: 121,                                         // PgDn
        0xE052: 114,                                         // Insert
        0xE053: 117,                                         // Delete
        0xE05B: 55,                                          // LGui (Win key) -> Command
        0xE05C: 54,                                          // RGui
        0xE05D: 110,                                         // Menu
    ]
}
