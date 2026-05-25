//
//  CursorSource.swift
//  MacRDP
//
//  Reads the current macOS system cursor (shape + hotspot) for the RDP
//  pointer channel. Bridge-agnostic — produces a plain BGRA bitmap.
//
//  Change detection uses the private CoreGraphics-Services cursor seed
//  (`CGSCurrentCursorSeed`) when available — a cheap integer that bumps
//  whenever the cursor changes — resolved via dlsym so a missing/renamed
//  symbol degrades gracefully (we fall back to hashing the rendered image).
//
//  The image itself comes from the public `NSCursor.currentSystem`. If that
//  proves stale for other apps' cursors in testing, the CGS image path
//  (`CGSGetGlobalCursorData`) can be slotted in behind the same interface.
//
//  Output orientation: top-down BGRA (row 0 = top), premultiplied alpha.
//  The C bridge flips to RDP's bottom-up layout when building the pointer PDU.
//

import Foundation
import AppKit
import CoreGraphics

struct CursorImage {
    var bgra: [UInt8]      // top-down, premultiplied, width*height*4
    var width: Int
    var height: Int
    var hotX: Int          // in pixels, from top-left
    var hotY: Int
}

final class CursorSource: @unchecked Sendable {
    /// Cheap CGS cursor seed (bumps on any cursor change). nil if the symbol
    /// couldn't be resolved — caller then dedupes by image hash instead.
    private let cgsCurrentCursorSeed: (@convention(c) () -> Int32)?

    init() {
        // RTLD_DEFAULT lookup — CoreGraphics is already loaded in-process.
        let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGSCurrentCursorSeed")
        if let sym {
            cgsCurrentCursorSeed = unsafeBitCast(sym, to: (@convention(c) () -> Int32).self)
        } else {
            cgsCurrentCursorSeed = nil
        }
    }

    /// Cheap change token. Returns the CGS seed when available, else -1 to
    /// signal "unknown" (caller should fetch + hash to detect changes).
    func changeToken() -> Int {
        if let f = cgsCurrentCursorSeed { return Int(f()) }
        return -1
    }

    /// The current system cursor as a top-down BGRA bitmap, or nil if hidden /
    /// unavailable.
    ///
    /// `scale` is the desktop's point→surface-pixel factor (surfaceWidth /
    /// CGDisplayPixelsWide). The cursor is rendered at its *point* size × scale
    /// so it matches the captured desktop's scale. NSCursor's cgImage is the
    /// native Retina (e.g. 2×) bitmap; on a point-resolution desktop (scale=1)
    /// that would draw double-size, so we resample to point size here.
    func currentCursor(scale: Double) -> CursorImage? {
        guard let cursor = NSCursor.currentSystem ?? NSCursor.current as NSCursor?,
              let cg = cursor.image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }

        let s = scale > 0 ? scale : 1.0
        let ptW = cursor.image.size.width, ptH = cursor.image.size.height
        guard ptW > 0, ptH > 0, cg.width > 0, cg.height > 0 else { return nil }
        let w = max(1, Int((ptW * s).rounded()))
        let h = max(1, Int((ptH * s).rounded()))

        var data = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        // premultipliedFirst + 32-little ⇒ bytes laid down B,G,R,A.
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
                       | CGBitmapInfo.byteOrder32Little.rawValue
        let ok: Bool = data.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(
                data: buf.baseAddress, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4,
                space: cs, bitmapInfo: bitmapInfo) else { return false }
            ctx.interpolationQuality = .high
            // A bitmap context already yields row 0 = top of the image, so we
            // do NOT flip here — that gives true top-down BGRA. The C bridge
            // flips top-down → RDP's bottom-up wire layout. Drawing into the
            // point-sized rect resamples the native cgImage to the right scale.
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }

        // NSCursor.hotSpot is in the image's point coordinate space (top-left
        // origin); scale it the same way as the bitmap.
        let hotX = Int((Double(cursor.hotSpot.x) * s).rounded())
        let hotY = Int((Double(cursor.hotSpot.y) * s).rounded())

        return CursorImage(bgra: data, width: w, height: h,
                           hotX: max(0, min(w - 1, hotX)),
                           hotY: max(0, min(h - 1, hotY)))
    }

    /// FNV-1a hash of a cursor bitmap, for dedup when the CGS seed is absent.
    static func hash(_ img: CursorImage) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        h = (h ^ UInt64(img.width)) &* 0x100000001b3
        h = (h ^ UInt64(img.height)) &* 0x100000001b3
        for b in img.bgra { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return h
    }
}
