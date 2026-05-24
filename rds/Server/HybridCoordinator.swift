//
//  HybridCoordinator.swift
//  MacRDP
//
//  Bridge-side glue for the hybrid per-tile codec. Owns the tile-map store,
//  the analysis engine, the masking pixel-buffer pool, and a serial send
//  queue. Conforms to HybridFrameSink so DisplayPipeline can drive it without
//  importing the FreeRDP bridge.
//
//  Two things cross threads here:
//    - route()  runs on MainActor (capture thread): submit-for-analysis +
//      read map + coalesce + (optional) build masked frame.
//    - send()   runs on MainActor (Progressive-only frames) or the encoder
//      output queue (H.264 frames); both hop onto `sendQueue` so the GFX
//      channel + progressive context are touched by exactly one thread.
//

#if MACRDP_BRIDGE_AVAILABLE

import Foundation
@preconcurrency import CoreMedia
@preconcurrency import CoreVideo
import os

final class HybridCoordinator: HybridFrameSink, @unchecked Sendable {
    private let cfg: Config.HybridConfig
    let store: TileCodecMapStore
    private let engine: AnalysisEngine
    private weak var bridge: BridgePeer?
    private let sendQueue = DispatchQueue(label: "com.macrdp.hybrid.send",
                                          qos: .userInteractive)

    // Masking pool (recreated when capture dimensions change).
    private var pool: CVPixelBufferPool?
    private var poolW = 0
    private var poolH = 0

    init(config: Config, bridge: BridgePeer, initialGrid: TileGrid) {
        self.cfg = config.video.effectiveHybrid
        self.bridge = bridge
        self.store = TileCodecMapStore(initialGrid: initialGrid)
        self.engine = AnalysisEngine(hybrid: self.cfg, store: store)
    }

    /// Resolution change hook — rebuild grid on both store and engine.
    func resolutionChanged(width: Int, height: Int) {
        let g = TileGrid(width: width, height: height, tileSize: cfg.tileSize)
        store.rebuild(to: g)
        engine.rebuildGrid(g)
    }

    // MARK: - HybridFrameSink

    func route(pixel: CVPixelBuffer, width: Int, height: Int, stride: Int,
               dirtyRects: [CGRect]?) -> HybridRouting {
        engine.submit(frame: pixel, grid: store.currentGrid, dirtyRects: dirtyRects)

        let (grid, tiles) = store.latest()
        // Resize raced ahead of the published map: fall back to a single
        // full-frame Progressive region — always correct, never blank.
        guard grid.width == width, grid.height == height else {
            let full = Rect16(left: 0, top: 0,
                              right: UInt16(clamping: width), bottom: UInt16(clamping: height))
            return HybridRouting(videoRects: [], staticRects: [full],
                                 grid: grid, maskedBuffer: nil)
        }

        let (videoRects, staticRects) = coalesce(tiles: tiles, grid: grid)

        var masked: CVPixelBuffer?
        if cfg.maskNonVideoTiles, !videoRects.isEmpty,
           let srcRaw = CVPixelBufferGetBaseAddress(pixel) {
            let src = srcRaw.assumingMemoryBound(to: UInt8.self)
            // Keep real pixels for the video tiles PLUS a halo around them, so
            // the H.264 references stay realistic at the seam (no flash when a
            // tile enters video). Only the un-dilated videoRects are blitted.
            let margin = max(0, cfg.maskHaloTiles) * cfg.tileSize
            let keepReal = margin > 0
                ? inflate(videoRects, by: margin, width: width, height: height)
                : videoRects
            masked = makeMasked(srcBase: src, srcStride: stride,
                                width: width, height: height, keepRealRects: keepReal)
        }
        return HybridRouting(videoRects: videoRects, staticRects: staticRects,
                             grid: grid, maskedBuffer: masked)
    }

    func send(annexB: Data?, isIDR: Bool, pts: CMTime, payload: HybridFramePayload) {
        sendQueue.async { [weak self] in
            guard let self, let bridge = self.bridge else { return }
            let pixel = payload.pixel
            CVPixelBufferLockBaseAddress(pixel, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
            guard let baseRaw = CVPixelBufferGetBaseAddress(pixel) else { return }
            let base = baseRaw.assumingMemoryBound(to: UInt8.self)
            let w = CVPixelBufferGetWidth(pixel)
            let h = CVPixelBufferGetHeight(pixel)
            let stride = CVPixelBufferGetBytesPerRow(pixel)
            _ = bridge.sendHybrid(
                annexB: annexB, isIDR: isIDR, pts: pts,
                videoRects: payload.videoRects,
                bgra: base, width: w, height: h, stride: stride,
                staticRects: payload.staticRects)
        }
    }

    // MARK: - Masking

    private func ensurePool(width: Int, height: Int) -> CVPixelBufferPool? {
        if let p = pool, poolW == width, poolH == height { return p }
        let pbAttrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: Int(kCVPixelFormatType_32BGRA) as CFNumber,
            kCVPixelBufferWidthKey: width as CFNumber,
            kCVPixelBufferHeightKey: height as CFNumber,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var p: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(nil, nil, pbAttrs as CFDictionary, &p) == kCVReturnSuccess,
              let created = p else { return nil }
        pool = created; poolW = width; poolH = height
        return created
    }

    /// Build a BGRA copy of the frame with everything outside `videoRects`
    /// flattened to the mask colour, so VideoToolbox spends ~no bits on the
    /// regions the client won't blit from the H.264 stream.
    /// Inflate each rect by `margin` px, clamped to the frame. Used to grow
    /// the keep-real region around video (overlaps are harmless — we only
    /// copy pixels). The blitted regionRects are NOT inflated.
    private func inflate(_ rects: [Rect16], by margin: Int,
                         width: Int, height: Int) -> [Rect16] {
        rects.map { r in
            Rect16(
                left:   UInt16(clamping: max(0, Int(r.left) - margin)),
                top:    UInt16(clamping: max(0, Int(r.top) - margin)),
                right:  UInt16(clamping: min(width,  Int(r.right) + margin)),
                bottom: UInt16(clamping: min(height, Int(r.bottom) + margin)))
        }
    }

    private func makeMasked(srcBase: UnsafePointer<UInt8>, srcStride: Int,
                            width: Int, height: Int,
                            keepRealRects: [Rect16]) -> CVPixelBuffer? {
        guard let pool = ensurePool(width: width, height: height) else { return nil }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess,
              let dst = out else { return nil }
        CVPixelBufferLockBaseAddress(dst, [])
        defer { CVPixelBufferUnlockBaseAddress(dst, []) }
        guard let dstRaw = CVPixelBufferGetBaseAddress(dst) else { return nil }
        let dstStride = CVPixelBufferGetBytesPerRow(dst)
        let dstBase = dstRaw.assumingMemoryBound(to: UInt8.self)

        // Flat fill with the configured mask colour (4-byte BGRX pattern).
        var word = cfg.maskColorBGRA
        withUnsafeBytes(of: &word) { wb in
            if let wp = wb.baseAddress {
                memset_pattern4(dstBase, wp, dstStride * height)
            }
        }
        // Copy the keep-real regions (video tiles + halo) over the flat fill.
        for r in keepRealRects {
            let x = Int(r.left), top = Int(r.top)
            let rowBytes = (Int(r.right) - x) * 4
            guard rowBytes > 0 else { continue }
            var y = top
            let bottom = Int(r.bottom)
            while y < bottom {
                memcpy(dstBase + y * dstStride + x * 4,
                       srcBase + y * srcStride + x * 4,
                       rowBytes)
                y += 1
            }
        }
        return dst
    }
}

#endif  // MACRDP_BRIDGE_AVAILABLE
