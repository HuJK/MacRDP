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

    // Convergence ("settle on idle"): the H.264 region the client is currently
    // showing. When capture goes idle we repaint it once via Progressive so it
    // doesn't stay stuck on the last lossy H.264 blit. Guarded by settleLock.
    private let settleLock = NSLock()
    private var settleRects: [Rect16] = []   // last frame's videoRects
    private var settlePending = false        // last sent frame had H.264 tiles
    private var settleInFlight = false        // a flush is enqueued

    // Capture-order paint tracking — see HybridRouting.captureToken. The token
    // counter is touched only from MainActor (`route()` / `flushSettle()`); the
    // per-tile last-paint map and the keyframe flag are written from the send
    // path (sendQueue) and read from MainActor (DisplayPipeline before encode),
    // so both go under `paintLock`.
    private var nextCaptureToken: Int64 = 1
    private let paintLock = NSLock()
    private var lastPaintToken: [Int64] = []
    private var paintGrid: TileGrid
    private var keyframeRequested = false

    init(config: Config, bridge: BridgePeer, initialGrid: TileGrid) {
        self.cfg = config.video.effectiveHybrid
        self.bridge = bridge
        self.store = TileCodecMapStore(initialGrid: initialGrid)
        self.engine = AnalysisEngine(hybrid: self.cfg, store: store)
        self.paintGrid = initialGrid
        self.lastPaintToken = [Int64](repeating: 0,
                                      count: max(0, initialGrid.tileCount))
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
        keyframeRequested = true  // force IDR on the first frame at the new size
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

        let (videoRects, staticRects) = coalesce(tiles: tiles, grid: grid)

        // Surface priming: any tile we've never *successfully* painted (paint
        // token still 0) must end up in staticRects this frame regardless of
        // what the analyzer published — otherwise an early `.skip` decision
        // (which the analyzer can reach within 2 analysis passes ≈ 64 ms,
        // long before RDPGFX caps confirm + first ack land on a slow client)
        // leaves those tiles black on the client until the user happens to
        // touch that area. Fast path: a fully-primed surface bails immediately.
        let primingRects = self.unpaintedExtras(grid: grid)
        let finalStatic = primingRects.isEmpty ? staticRects : staticRects + primingRects

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
        return HybridRouting(videoRects: videoRects, staticRects: finalStatic,
                             grid: grid, maskedBuffer: masked,
                             captureToken: token)
    }

    /// Coalesce every tile whose `lastPaintToken == 0` — i.e. never covered by
    /// a *successful* send — into a list of rectangles, so `route()` can union
    /// them into the next Progressive command. If those tiles are also in this
    /// frame's videoRects the bridge will end up painting them twice (AVC
    /// first, Progressive last → Progressive wins for the priming frame); a
    /// tiny waste vs. leaving them black.
    private func unpaintedExtras(grid: TileGrid) -> [Rect16] {
        paintLock.lock()
        guard paintGrid == grid, lastPaintToken.count == grid.tileCount else {
            paintLock.unlock(); return []
        }
        // Scan for any unpainted tile; once the surface is fully primed this
        // returns immediately on every subsequent frame.
        var any = false
        for v in lastPaintToken where v == 0 { any = true; break }
        guard any else { paintLock.unlock(); return [] }
        var mask = [UInt8](repeating: TileCodec.skip.rawValue,
                           count: lastPaintToken.count)
        for i in 0..<lastPaintToken.count where lastPaintToken[i] == 0 {
            mask[i] = TileCodec.progressive.rawValue
        }
        paintLock.unlock()
        let (_, extras) = coalesce(tiles: mask, grid: grid)
        return extras
    }

    func send(annexB: Data?, isIDR: Bool, pts: CMTime, payload: HybridFramePayload) {
        sendQueue.async { [weak self] in
            guard let self, let bridge = self.bridge else { return }

            // Filter BOTH codecs' blit rects against any newer paints (paint
            // tokens > this frame's captureToken). The race window covers
            // staticRects too: a hybrid frame's Progressive part comes out
            // of the encoder callback after a later Progressive-only frame
            // (or settle) has already painted overlapping tiles, and would
            // visibly clobber the newer content with this frame's older
            // pixels. The filter keeps last-writer-wins in *capture* order
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
                                 grid: payload.grid, token: payload.captureToken)
                // Settle bookkeeping (only on confirmed wire writes): the H.264
                // region the client is currently showing is the union of AVC
                // blits we've *actually* committed. Skipped on avcDropped (we
                // didn't paint H.264) or on bridge reject (nothing landed) so
                // settleRects keeps reflecting client truth, not intent.
                if !avcDropped {
                    self.settleLock.lock()
                    self.settleRects = filteredVideo
                    self.settlePending = !filteredVideo.isEmpty
                    self.settleLock.unlock()
                }
            } else {
                // Bridge rejected the write (backpressure / channel-not-ready /
                // internal error). Nothing landed on the client surface; the
                // tiles we intended to update are still showing whatever was
                // last successfully painted. Re-arm them by clearing their
                // paint tokens so the next route() pulls them back into
                // staticRects via unpaintedExtras — otherwise an analyzer
                // `.skip` transition (which happens cheaply once wasActive is
                // cleared) leaves them stuck at the stale paint until the
                // user happens to dirty that area.
                let rectsToForget = (avcDropped ? [] : filteredVideo) + filteredStatic
                self.forgetPaint(rects: rectsToForget, grid: payload.grid)
            }
        }
    }

    /// Reset paint tokens to 0 for the given rects so `unpaintedExtras` treats
    /// them as never-painted on the next `route()` pass. Used as the recovery
    /// hook for any `bridge.sendHybrid` that the wire rejects.
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
        var keep = [UInt8](repeating: TileCodec.skip.rawValue, count: cols * rows)
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
                        // Tile codec doesn't matter for coalesce() since we
                        // only read back one channel — reuse .h264 as a
                        // generic "kept" sentinel.
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

    private func markPainted(rects: [Rect16], grid: TileGrid, token: Int64) {
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
                }
            }
        }
    }

    func flushSettle(pixel: CVPixelBuffer, width: Int, height: Int, stride: Int) {
        // Only when the client is currently showing an H.264 region and no
        // flush is already in flight. Cleared on a successful send; on failure
        // (backpressure) we keep it pending and retry on the next idle frame.
        settleLock.lock()
        guard settlePending, !settleInFlight, !settleRects.isEmpty else {
            settleLock.unlock(); return
        }
        settleInFlight = true
        let rects = settleRects
        settleLock.unlock()

        // Bump the capture token so this Progressive paint outranks anything
        // a late H.264 send still has queued — settle MUST win against the
        // very stream it's trying to converge over. `nextCaptureToken` is
        // single-threaded on MainActor; flushSettle is documented MainActor.
        let token = nextCaptureToken
        nextCaptureToken &+= 1
        let grid = paintGrid

        sendQueue.async { [weak self] in
            guard let self else { return }
            var ok = false
            if let bridge = self.bridge {
                CVPixelBufferLockBaseAddress(pixel, .readOnly)
                if let baseRaw = CVPixelBufferGetBaseAddress(pixel) {
                    let base = baseRaw.assumingMemoryBound(to: UInt8.self)
                    // Progressive-only repaint of the now-static former H.264
                    // region — no analysis, no AVC, just converge the pixels.
                    ok = bridge.sendHybrid(
                        annexB: nil, isIDR: false, pts: .invalid,
                        videoRects: [],
                        bgra: base, width: width, height: height, stride: stride,
                        staticRects: rects)
                }
                CVPixelBufferUnlockBaseAddress(pixel, .readOnly)
            }
            if ok {
                self.markPainted(rects: rects, grid: grid, token: token)
            } else {
                // Settle write rejected — re-arm so unpaintedExtras can pull
                // these tiles back into staticRects on the next route() pass.
                // settlePending stays set so a later idle frame retries too.
                self.forgetPaint(rects: rects, grid: grid)
            }
            self.settleLock.lock()
            self.settleInFlight = false
            if ok { self.settlePending = false }
            self.settleLock.unlock()
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
