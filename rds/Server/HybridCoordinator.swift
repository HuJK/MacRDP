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
    private let cfg: Config.TileConfig
    let store: TileCodecMapStore
    private let engine: AnalysisEngine
    private weak var bridge: BridgePeer?
    private let sendQueue = DispatchQueue(label: "com.macrdp.hybrid.send",
                                          qos: .userInteractive)

    // Masking pool (recreated when capture dimensions change).
    private var pool: CVPixelBufferPool?
    private var poolW = 0
    private var poolH = 0

    // Capture-order paint tracking — see HybridRouting.captureToken. The token
    // counter is touched only from MainActor (`route()`); the per-tile last-
    // paint map and the keyframe flag are written from the send path
    // (sendQueue) and read from MainActor (DisplayPipeline before encode),
    // so both go under `paintLock`.
    private var nextCaptureToken: Int64 = 1
    private let paintLock = NSLock()
    private var lastPaintToken: [Int64] = []
    private var paintGrid: TileGrid
    private var keyframeRequested = false

    // Progressive goes out only where the client lacks a tile's newest pixels
    // (FreeRDP's progressive_compress encodes every tile it is given, so a
    // full-surface region costs ~0.4-1.4 MB per 1080p frame and floods the
    // client). `changedToken[i]`: the newest capture whose pixels tile i must
    // get losslessly — it changed then, or H.264 painted it (lossy).
    // `progressiveToken[i]`: the newest capture painted there by Progressive.
    // route() keeps the static tiles with progressiveToken < changedToken; a
    // send that never lands leaves them pending for the next route(). Both
    // under `paintLock`, like lastPaintToken.
    private var changedToken: [Int64] = []
    private var progressiveToken: [Int64] = []

    // Change detection: the last routed capture's pixels, compared row by
    // row in route(). Dirty rects don't do: captures skipped under
    // backpressure never reach route(), and their space is unclear when SCK
    // scales. MainActor only.
    private var reference: UnsafeMutableRawPointer?
    private var refWidth = 0, refHeight = 0, refStride = 0

    /// Called on the send queue when the client may be left behind: the
    /// bridge refused a frame, or an AVC frame was dropped so its decoder is
    /// out of step until the next IDR. Either is only repaired by a later
    /// frame, which a still picture never produces. Set once, before frames
    /// flow (DisplayPipeline.requestRepaint resubmits the newest capture).
    var onRepaintNeeded: (@Sendable () -> Void)?

    init(config: Config, bridge: BridgePeer, initialGrid: TileGrid) {
        self.cfg = config.video.tile
        self.bridge = bridge
        self.store = TileCodecMapStore(initialGrid: initialGrid)
        self.engine = AnalysisEngine(tile: self.cfg, store: store)
        self.paintGrid = initialGrid
        self.lastPaintToken = [Int64](repeating: 0,
                                      count: max(0, initialGrid.tileCount))
        resetProgressiveState(tileCount: initialGrid.tileCount)
    }

    deinit { reference?.deallocate() }

    /// Every tile pending: the client surface is blank (new or re-created).
    /// Caller holds `paintLock` (or is init).
    private func resetProgressiveState(tileCount: Int) {
        changedToken = [Int64](repeating: 1, count: max(0, tileCount))
        progressiveToken = [Int64](repeating: 0, count: max(0, tileCount))
    }

    /// Resolution change hook — rebuild grid on both store and engine.
    func resolutionChanged(width: Int, height: Int) {
        let g = TileGrid(width: width, height: height, tileSize: cfg.tileSize)
        store.rebuild(to: g)
        engine.rebuildGrid(g)
        // Reset the per-tile paint map — the old indices no longer mean the
        // same tiles, and any pending H.264 send for the old grid will hit
        // the size-mismatch guard in send() and be dropped anyway.
        paintLock.lock()
        paintGrid = g
        lastPaintToken = [Int64](repeating: 0, count: max(0, g.tileCount))
        resetProgressiveState(tileCount: g.tileCount)
        keyframeRequested = true  // force IDR on the first frame at the new size
        paintLock.unlock()
    }

    /// Paint every tile again on the next route() (the client may have
    /// dropped its surface, e.g. while minimized).
    func repaintAll() {
        paintLock.lock()
        for i in progressiveToken.indices { progressiveToken[i] = 0 }
        paintLock.unlock()
    }

    /// True (and resets to false) if a recent send dropped its AVC NAL because
    /// every blit rect was filtered against newer Progressive paints. The next
    /// encoded frame must be IDR so the client decoder DPB resyncs.
    func popPendingKeyframe() -> Bool {
        paintLock.lock(); defer { paintLock.unlock() }
        let r = keyframeRequested
        keyframeRequested = false
        return r
    }

    // MARK: - HybridFrameSink

    func route(pixel: CVPixelBuffer, width: Int, height: Int, stride: Int,
               dirtyRects: [CGRect]?) -> HybridRouting {
        engine.submit(frame: pixel, grid: store.currentGrid, dirtyRects: dirtyRects)

        // Stamp the capture order BEFORE we publish the routing. `route()` is
        // called from MainActor in capture order, so this counter is the
        // ground truth for "which frame's pixels are these" regardless of
        // how the H.264 encoder reorders work on its own thread later.
        let token = nextCaptureToken
        nextCaptureToken &+= 1

        let (grid, tiles) = store.latest()
        // Resize raced ahead of the published map: fall back to a single
        // full-frame Progressive region — always correct, never blank.
        guard grid.width == width, grid.height == height else {
            let full = Rect16(left: 0, top: 0,
                              right: UInt16(clamping: width), bottom: UInt16(clamping: height))
            return HybridRouting(videoRects: [], staticRects: [full],
                                 grid: grid, maskedBuffer: nil,
                                 captureToken: token)
        }

        let changed = changedTiles(pixel: pixel, width: width, height: height,
                                   stride: stride, grid: grid)
        let (videoRects, staticRects) = coalesce(
            tiles: tilesToPaint(tiles, changed: changed, grid: grid, token: token), grid: grid)

        var masked: CVPixelBuffer?
        if cfg.mask.enable, !videoRects.isEmpty,
           let srcRaw = CVPixelBufferGetBaseAddress(pixel) {
            let src = srcRaw.assumingMemoryBound(to: UInt8.self)
            // Keep real pixels for the video tiles PLUS a halo around them, so
            // the H.264 references stay realistic at the seam (no flash when a
            // tile enters video). Only the un-dilated videoRects are blitted.
            let margin = max(0, cfg.mask.haloTiles) * cfg.tileSize
            let keepReal = margin > 0
                ? inflate(videoRects, by: margin, width: width, height: height)
                : videoRects
            masked = makeMasked(srcBase: src, srcStride: stride,
                                width: width, height: height, keepRealRects: keepReal)
        }
        return HybridRouting(videoRects: videoRects, staticRects: staticRects,
                             grid: grid, maskedBuffer: masked,
                             captureToken: token)
    }

    func send(annexB: Data?, isIDR: Bool, pts: CMTime, payload: HybridFramePayload) {
        sendQueue.async { [weak self] in
            guard let self, let bridge = self.bridge else { return }

            // Filter BOTH codecs' blit rects against any newer paints (paint
            // tokens > this frame's captureToken). The race window covers
            // staticRects too: a hybrid frame's Progressive part comes out
            // of the encoder callback after a later Progressive-only frame
            // has already painted overlapping tiles, and would visibly
            // clobber the newer content with this frame's older pixels.
            // The filter keeps last-writer-wins in *capture* order
            // regardless of sendQueue enqueue order.
            let originalVideo = payload.videoRects
            let filteredVideo = self.filterRectsAgainstNewerPaints(
                originalVideo, grid: payload.grid, token: payload.captureToken)
            let filteredStatic = self.filterRectsAgainstNewerPaints(
                payload.staticRects, grid: payload.grid, token: payload.captureToken)
            let avcAllFiltered = !originalVideo.isEmpty && filteredVideo.isEmpty
            let avcDropped = (annexB != nil) && avcAllFiltered
            if avcDropped {
                // Skip the AVC NAL: emitting the bitstream without blitting it
                // doesn't help (the picture is invisible) but emitting it WITH
                // a blit would stomp newer Progressive. Either way our encoder
                // DPB drifts vs the client decoder; force IDR next time so the
                // chain resyncs before any new H.264 blit lands.
                self.paintLock.lock()
                self.keyframeRequested = true
                self.paintLock.unlock()
                self.onRepaintNeeded?()
            }

            // Nothing survived the filter on either side → no-op (the wire
            // already has newer pixels at every tile we'd touch, or there
            // was nothing to send to begin with).
            let willSendAVC = !avcDropped && (annexB != nil)
            let willSendProgressive = !filteredStatic.isEmpty
            if !willSendAVC && !willSendProgressive { return }

            let pixel = payload.pixel
            CVPixelBufferLockBaseAddress(pixel, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
            guard let baseRaw = CVPixelBufferGetBaseAddress(pixel) else { return }
            let base = baseRaw.assumingMemoryBound(to: UInt8.self)
            let w = CVPixelBufferGetWidth(pixel)
            let h = CVPixelBufferGetHeight(pixel)
            let stride = CVPixelBufferGetBytesPerRow(pixel)

            let ok = bridge.sendHybrid(
                annexB: avcDropped ? nil : annexB,
                isIDR: avcDropped ? false : isIDR,
                pts: pts,
                videoRects: avcDropped ? [] : filteredVideo,
                bgra: base, width: w, height: h, stride: stride,
                staticRects: filteredStatic)

            if ok {
                // Stamp the tiles we just painted at this capture order. Both
                // codecs stamp: H.264 because subsequent late H.264 sends must
                // not stomp it either; Progressive because that's the whole
                // point of the filter. Tiles only move forward in time —
                // markPainted() takes max() with the existing value.
                if !avcDropped {
                    self.markPainted(rects: filteredVideo,
                                     grid: payload.grid, token: payload.captureToken)
                }
                self.markPainted(rects: filteredStatic,
                                 grid: payload.grid, token: payload.captureToken,
                                 progressive: true)
            } else {
                // Bridge rejected the write (backpressure / channel-not-ready /
                // internal error). Nothing landed on the client surface; the
                // static tiles stay pending (progressiveToken didn't advance)
                // and the video tiles are H.264 again, so the next route()
                // re-emits these same rects. Clear the paint tokens so
                // `filterRectsAgainstNewerPaints` doesn't drop that retry
                // against an "older" capture token.
                let rectsToForget = (avcDropped ? [] : filteredVideo) + filteredStatic
                self.forgetPaint(rects: rectsToForget, grid: payload.grid)
                // The client decoder never got this AVC frame while ours did:
                // resync with an IDR, as when a NAL is dropped above.
                if willSendAVC {
                    self.paintLock.lock()
                    self.keyframeRequested = true
                    self.paintLock.unlock()
                }
                // If the picture is now still there is no next route():
                // have the pipeline resubmit its newest capture.
                self.onRepaintNeeded?()
            }
        }
    }

    /// Reset paint tokens to 0 for the given rects so the next route() can
    /// re-paint them without `filterRectsAgainstNewerPaints` rejecting the
    /// retry. Used as the recovery hook for any `bridge.sendHybrid` that the
    /// wire rejects.
    private func forgetPaint(rects: [Rect16], grid: TileGrid) {
        if rects.isEmpty { return }
        paintLock.lock(); defer { paintLock.unlock() }
        guard paintGrid == grid, lastPaintToken.count == grid.tileCount else { return }
        let ts = grid.tileSize
        let cols = grid.cols, rows = grid.rows
        for r in rects {
            let c0 = min(cols - 1, max(0, Int(r.left)  / ts))
            let r0 = min(rows - 1, max(0, Int(r.top)   / ts))
            let c1 = min(cols - 1, max(0, (Int(r.right)  - 1) / ts))
            let r1 = min(rows - 1, max(0, (Int(r.bottom) - 1) / ts))
            if c1 < c0 || r1 < r0 { continue }
            for row in r0...r1 {
                for col in c0...c1 {
                    lastPaintToken[row * cols + col] = 0
                }
            }
        }
    }

    /// Walk the input rects tile-by-tile, drop any tile whose last paint token
    /// is strictly newer than this send's capture token, and coalesce the
    /// survivors back into rectangles. Boolean mask + the existing coalesce()
    /// keeps the rect-shape policy in one place.
    private func filterRectsAgainstNewerPaints(
        _ rects: [Rect16], grid: TileGrid, token: Int64
    ) -> [Rect16] {
        if rects.isEmpty { return rects }
        paintLock.lock()
        guard paintGrid == grid, lastPaintToken.count == grid.tileCount else {
            paintLock.unlock()
            return rects   // grid raced ahead; let the bridge's size guard handle it
        }
        let snapshot = lastPaintToken
        paintLock.unlock()

        let ts = grid.tileSize
        let cols = grid.cols, rows = grid.rows
        guard cols > 0, rows > 0 else { return rects }
        // 0 is unused by TileCodec (the enum only carries .progressive=1 and
        // .h264=2) — perfect as a scratch "not kept" sentinel here so coalesce
        // ignores those entries. We then mark kept tiles with .h264 just so
        // the rect-shape policy (greedy run-merge in coalesce) treats them
        // as one channel; only that channel is read back.
        var keep = [UInt8](repeating: 0, count: cols * rows)
        var anyKept = false
        for r in rects {
            let c0 = min(cols - 1, max(0, Int(r.left)  / ts))
            let r0 = min(rows - 1, max(0, Int(r.top)   / ts))
            let c1 = min(cols - 1, max(0, (Int(r.right)  - 1) / ts))
            let r1 = min(rows - 1, max(0, (Int(r.bottom) - 1) / ts))
            if c1 < c0 || r1 < r0 { continue }
            for row in r0...r1 {
                for col in c0...c1 {
                    let i = row * cols + col
                    if snapshot[i] <= token {
                        keep[i] = TileCodec.h264.rawValue
                        anyKept = true
                    }
                }
            }
        }
        if !anyKept { return [] }
        let (kept, _) = coalesce(tiles: keep, grid: grid)
        return kept
    }

    private func markPainted(rects: [Rect16], grid: TileGrid, token: Int64,
                             progressive: Bool = false) {
        if rects.isEmpty { return }
        paintLock.lock(); defer { paintLock.unlock() }
        guard paintGrid == grid, lastPaintToken.count == grid.tileCount else { return }
        let ts = grid.tileSize
        let cols = grid.cols, rows = grid.rows
        for r in rects {
            let c0 = min(cols - 1, max(0, Int(r.left)  / ts))
            let r0 = min(rows - 1, max(0, Int(r.top)   / ts))
            let c1 = min(cols - 1, max(0, (Int(r.right)  - 1) / ts))
            let r1 = min(rows - 1, max(0, (Int(r.bottom) - 1) / ts))
            if c1 < c0 || r1 < r0 { continue }
            for row in r0...r1 {
                for col in c0...c1 {
                    let i = row * cols + col
                    if lastPaintToken[i] < token { lastPaintToken[i] = token }
                    if progressive, progressiveToken[i] < token { progressiveToken[i] = token }
                }
            }
        }
    }

    // MARK: - What to paint

    /// Tiles whose pixels differ from the last routed capture (all of them
    /// when there is none at this size), and the reference updated to this
    /// capture. `pixel` is locked by the caller.
    private func changedTiles(pixel: CVPixelBuffer, width: Int, height: Int,
                              stride: Int, grid: TileGrid) -> [Bool] {
        var changed = [Bool](repeating: false, count: max(0, grid.tileCount))
        guard let src = CVPixelBufferGetBaseAddress(pixel), grid.cols > 0, grid.rows > 0 else {
            return [Bool](repeating: true, count: changed.count)
        }
        if reference == nil || refWidth != width || refHeight != height || refStride != stride {
            reference?.deallocate()
            reference = UnsafeMutableRawPointer.allocate(byteCount: stride * height, alignment: 64)
            refWidth = width; refHeight = height; refStride = stride
            reference!.copyMemory(from: src, byteCount: stride * height)
            return [Bool](repeating: true, count: changed.count)
        }
        let ref = reference!
        let ts = grid.tileSize, cols = grid.cols
        let rowBytes = min(width, cols * ts) * 4
        for y in 0..<min(height, grid.rows * ts) {
            let a = src + y * stride, b = ref + y * stride
            if memcmp(a, b, rowBytes) == 0 { continue }
            let base = (y / ts) * cols
            for col in 0..<cols where !changed[base + col] {
                let x = col * ts * 4
                if memcmp(a + x, b + x, min(ts * 4, rowBytes - x)) != 0 { changed[base + col] = true }
            }
            b.copyMemory(from: a, byteCount: rowBytes)
        }
        return changed
    }

    /// The tile map trimmed to what this capture must paint: every H.264
    /// tile, and the Progressive tiles the client doesn't have losslessly at
    /// their newest pixels. Unpainted tiles get a byte matching neither codec,
    /// so coalesce() skips them.
    private func tilesToPaint(_ tiles: [UInt8], changed: [Bool], grid: TileGrid,
                              token: Int64) -> [UInt8] {
        paintLock.lock(); defer { paintLock.unlock() }
        guard paintGrid == grid, changedToken.count == tiles.count,
              changed.count == tiles.count else { return tiles }
        var out = tiles
        for i in out.indices {
            if changed[i] { changedToken[i] = token }
            if out[i] == TileCodec.h264.rawValue {
                changedToken[i] = token   // painted lossy: Progressive must follow once still
            } else if progressiveToken[i] >= changedToken[i] {
                out[i] = 0
            }
        }
        return out
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
        var word = cfg.mask.colorBGRA
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
