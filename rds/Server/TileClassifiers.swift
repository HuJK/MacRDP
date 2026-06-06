//
//  TileClassifiers.swift
//  MacRDP
//
//  Independent per-tile classifiers for the hybrid codec. Each turns a frame
//  into a per-tile (active, desired-codec) decision; the AnalysisEngine then
//  applies the shared skip/settle/hysteresis pass.
//
//  Classifiers declare whether they require ScreenCaptureKit's dirtyRects.
//  There is NO silent fallback: if a dirtyRects-requiring classifier is
//  selected but the data is unavailable, the engine notifies and exits so the
//  user switches to a classifier that doesn't need it (e.g. "pixelRate").
//
//  Naming: the "DR" suffix means the change signal comes from dirtyRects (a set
//  of changed *rectangles* per frame — region-level, no per-pixel magnitude); no
//  suffix means a true per-pixel comparison.
//
//    "blobDR"      — dirtyRects → connected-component AREA of touched tiles
//                    (large blob → video).
//    "dirtyFreqDR" — dirtyRects → per tile, the FREQUENCY over recent frames
//                    that the tile was touched by any dirty rect (boolean per
//                    frame, no area magnitude — that would be bogus since a
//                    dirty rect is only a bounding box). High frequency =
//                    continuously updating = video.
//    "pixelRate"   — full-frame per-pixel RGB comparison → per tile, the
//                    fraction of recent frames whose *real* changed-pixel
//                    coverage was high. Per-pixel coverage is a true magnitude,
//                    so the coverage-rate rule is meaningful here. Needs no
//                    dirtyRects.
//

import Foundation
@preconcurrency import CoreVideo
import CoreGraphics

protocol TileClassifier: AnyObject {
    var name: String { get }
    var requiresDirtyRects: Bool { get }
    /// Re-size internal state for a new grid (resolution change).
    func reset(grid: TileGrid)
    /// Per-tile codec decision for one frame. `dirtyRects` is guaranteed
    /// non-nil when `requiresDirtyRects`. `pixel` is used only by
    /// pixel-based classifiers (they lock it themselves). `nowMs` is
    /// wall-clock monotonic milliseconds — used by window-based
    /// classifiers (dirtyFreqDR / pixelRate) to advance their time-bucket
    /// history regardless of analysis cadence; blobDR ignores it.
    /// Returns an array of length tileCount whose entries are
    /// `TileCodec.rawValue` — one of the two real codecs for every tile.
    func classify(grid: TileGrid, nowMs: UInt64,
                  dirtyRects: [CGRect]?, pixel: CVPixelBuffer) -> [UInt8]
}

/// Build one classifier by name, or nil if the name is unknown. Each
/// classifier gets only ITS sub-config from `tile`; the nested layout in
/// `Config.swift` is the source of truth for which knobs are whose.
func makeTileClassifier(named name: String, tile: Config.TileConfig) -> TileClassifier? {
    switch name.lowercased() {
    case "blobdr":      return BlobDRClassifier(cfg: tile.blobDR)
    case "dirtyfreqdr": return DirtyFreqDRClassifier(cfg: tile.dirtyFreqDR)
    case "pixelrate":   return PixelRateClassifier(cfg: tile.pixelRate)
    default:            return nil
    }
}

// MARK: - Shared helpers

/// Per-tile change coverage (0–1) from dirty rects (in surface pixels).
private func coverageFromDirtyRects(_ rects: [CGRect], grid g: TileGrid) -> [Double] {
    let cols = g.cols, rows = g.rows, ts = g.tileSize, w = g.width, h = g.height
    var dirtyArea = [Int](repeating: 0, count: max(0, cols * rows))
    guard cols > 0, rows > 0 else { return [] }
    for rect in rects {
        let x0 = max(0, Int(rect.minX.rounded(.down)))
        let y0 = max(0, Int(rect.minY.rounded(.down)))
        let x1 = min(w, Int(rect.maxX.rounded(.up)))
        let y1 = min(h, Int(rect.maxY.rounded(.up)))
        if x1 <= x0 || y1 <= y0 { continue }
        for tr in (y0 / ts)...((y1 - 1) / ts) {
            let ty0 = tr * ts, ty1 = min(ty0 + ts, h)
            let iy0 = max(y0, ty0), iy1 = min(y1, ty1)
            if iy1 <= iy0 { continue }
            for tc in (x0 / ts)...((x1 - 1) / ts) {
                let tx0 = tc * ts, tx1 = min(tx0 + ts, w)
                let ix0 = max(x0, tx0), ix1 = min(x1, tx1)
                if ix1 <= ix0 { continue }
                dirtyArea[tr * cols + tc] += (ix1 - ix0) * (iy1 - iy0)
            }
        }
    }
    var coverage = [Double](repeating: 0, count: cols * rows)
    for tr in 0..<rows {
        let th = min(ts, h - tr * ts)
        for tc in 0..<cols {
            let tw = min(ts, w - tc * ts)
            let i = tr * cols + tc
            coverage[i] = min(1.0, Double(dirtyArea[i]) / Double(max(1, tw * th)))
        }
    }
    return coverage
}

/// Per-tile boolean: was the tile overlapped by ANY dirty rect (≥1 pixel)?
/// Region-level only — no area magnitude (a dirty rect is just a bounding box).
private func tilesTouched(by rects: [CGRect], grid g: TileGrid) -> [Bool] {
    let cols = g.cols, rows = g.rows, ts = g.tileSize, w = g.width, h = g.height
    var touched = [Bool](repeating: false, count: max(0, cols * rows))
    guard cols > 0, rows > 0 else { return touched }
    for rect in rects {
        let x0 = max(0, Int(rect.minX.rounded(.down)))
        let y0 = max(0, Int(rect.minY.rounded(.down)))
        let x1 = min(w, Int(rect.maxX.rounded(.up)))
        let y1 = min(h, Int(rect.maxY.rounded(.up)))
        if x1 <= x0 || y1 <= y0 { continue }
        for tr in (y0 / ts)...((y1 - 1) / ts) {
            for tc in (x0 / ts)...((x1 - 1) / ts) {
                touched[tr * cols + tc] = true
            }
        }
    }
    return touched
}

/// Per-tile wall-clock-bucketed activity history → Schmitt-trigger codec
/// decision (dual threshold, integer count).
///
///   dirtyFreqDR observes "tile was touched this analysis";
///   pixelRate   observes "real changed-pixel coverage was high this analysis".
///
/// The ring is indexed by **absolute time bucket** (`nowMs / bucketMs`),
/// not by analysis tick — so the total window covers a fixed wall-clock
/// period of `bucketMs × bucketCount` regardless of how often `observe()`
/// is called. Multiple observations falling in the same bucket fold into
/// one idempotent OR; a long gap between calls scrolls the corresponding
/// number of buckets out of the window when the next call finally arrives.
/// There is no separate "tick on idle" path: time advances on every
/// observe.
///
/// Schmitt thresholds are absolute bucket counts (Int), compared directly
/// against the maintained `popcount[i]`. Avoids the floating-point
/// quantization corners that fractions hit at the ring's edge (e.g.
/// `0.999 × 30 ≈ 29.97` ends up needing popcount==30 exactly to enter).
///
/// Storage: tileCount × bucketCount bools + tileCount Ints for popcount.
/// ~60 KB at 4K/64 tiles × 30 buckets, ~180 KB at 90 buckets.
private final class TimeBucketHistory {
    private let bucketMs: Int
    private let bucketCount: Int
    private var tileCount: Int = 0
    private var bits: [Bool] = []         // flat ring: bits[i * bucketCount + slot]
    private var popcount: [Int] = []       // 1-bits per tile across the whole ring
    private var videoState: [Bool] = []   // Schmitt latched output per tile
    private var lastBucket: Int64 = 0     // absolute bucket id of the last observe
    private var primed: Bool = false      // false until the first observe

    init(bucketMs: Int, bucketCount: Int) {
        self.bucketMs = max(1, bucketMs)
        self.bucketCount = max(1, bucketCount)
    }

    /// Reset for a new tile count (resize). Window dimensions are kept.
    func reset(tileCount: Int) {
        self.tileCount = tileCount
        bits = [Bool](repeating: false, count: tileCount * bucketCount)
        popcount = [Int](repeating: 0, count: tileCount)
        videoState = [Bool](repeating: false, count: tileCount)
        primed = false
    }

    /// Advance the wall-clock axis to `nowMs`, OR `touched` into the current
    /// bucket, run the Schmitt, and return per-tile codec decisions.
    ///
    /// Advancement zeros each slot the head just scrolled into (those
    /// slots hold a bit from `bucketCount` buckets ago — now outside the
    /// window). If `stride ≥ bucketCount` the whole ring is stale: bulk
    /// clear instead of looping.
    ///
    /// `enterCount > exitCount` is the operator's responsibility — we
    /// don't validate, an invalid pair degrades to "stuck in one state"
    /// (observable, not crashy).
    func observe(touched: [Bool], nowMs: UInt64,
                 enterCount: Int, exitCount: Int) -> [UInt8] {
        if touched.count != tileCount {
            reset(tileCount: touched.count)
        }
        let curr = Int64(nowMs / UInt64(bucketMs))
        if !primed {
            lastBucket = curr
            primed = true
        } else if curr > lastBucket {
            let stride = curr - lastBucket
            if stride >= Int64(bucketCount) {
                // Long pause: every slot is stale → bulk clear.
                for j in 0..<bits.count { bits[j] = false }
                for i in 0..<tileCount { popcount[i] = 0 }
            } else {
                // Zero each slot the head scrolled into (held a bit from
                // the prior revolution; now out-of-window).
                for k in 1...Int(stride) {
                    let slot = Int((lastBucket + Int64(k)) % Int64(bucketCount))
                    for i in 0..<tileCount {
                        let idx = i * bucketCount + slot
                        if bits[idx] {
                            bits[idx] = false
                            popcount[i] -= 1
                        }
                    }
                }
            }
            lastBucket = curr
        }
        // OR touched into the current bucket — idempotent within a bucket
        // so multiple analyses landing in the same bucket count once.
        let slot = Int(curr % Int64(bucketCount))
        for i in 0..<tileCount where touched[i] {
            let idx = i * bucketCount + slot
            if !bits[idx] {
                bits[idx] = true
                popcount[i] += 1
            }
        }
        // Schmitt sweep — pure Int compare.
        var out = [UInt8](repeating: TileCodec.progressive.rawValue, count: tileCount)
        for i in 0..<tileCount {
            let pc = popcount[i]
            if videoState[i] {
                if pc < exitCount { videoState[i] = false }
            } else if pc >= enterCount {
                videoState[i] = true
            }
            out[i] = videoState[i] ? TileCodec.h264.rawValue : TileCodec.progressive.rawValue
        }
        return out
    }
}

/// Connected-component (4-conn) area rule: large changed regions → H.264.
private func classifyByRegionArea(active: [Bool], grid g: TileGrid,
                                  largeRegionTiles: Int, into desired: inout [UInt8]) {
    let cols = g.cols, rows = g.rows
    var visited = [Bool](repeating: false, count: active.count)
    var stack: [Int] = []
    for start in 0..<active.count where active[start] && !visited[start] {
        stack.removeAll(keepingCapacity: true)
        stack.append(start); visited[start] = true
        var members: [Int] = []
        while let idx = stack.popLast() {
            members.append(idx)
            let r = idx / cols, c = idx % cols
            if c > 0        { let n = idx - 1;    if active[n] && !visited[n] { visited[n] = true; stack.append(n) } }
            if c < cols - 1 { let n = idx + 1;    if active[n] && !visited[n] { visited[n] = true; stack.append(n) } }
            if r > 0        { let n = idx - cols; if active[n] && !visited[n] { visited[n] = true; stack.append(n) } }
            if r < rows - 1 { let n = idx + cols; if active[n] && !visited[n] { visited[n] = true; stack.append(n) } }
        }
        let code: UInt8 = members.count >= largeRegionTiles
            ? TileCodec.h264.rawValue : TileCodec.progressive.rawValue
        for m in members { desired[m] = code }
    }
}

// MARK: - blobDR (dirtyRects → connected-component blob area)

final class BlobDRClassifier: TileClassifier {
    let name = "blobDR"
    let requiresDirtyRects = true
    private let cfg: Config.TileConfig.BlobDRConfig
    init(cfg: Config.TileConfig.BlobDRConfig) { self.cfg = cfg }
    func reset(grid: TileGrid) {}
    func classify(grid: TileGrid, nowMs: UInt64,
                  dirtyRects: [CGRect]?, pixel: CVPixelBuffer) -> [UInt8] {
        let coverage = coverageFromDirtyRects(dirtyRects ?? [], grid: grid)
        // "Active" here is internal — a tile counts as a candidate for the
        // connected-component blob heuristic iff its dirty-rect coverage
        // meets the threshold.
        let active = coverage.map { $0 >= cfg.tileActiveCoverage }
        var desired = [UInt8](repeating: TileCodec.progressive.rawValue, count: grid.tileCount)
        classifyByRegionArea(active: active, grid: grid,
                             largeRegionTiles: cfg.largeRegionTiles, into: &desired)
        return desired
    }
}

// MARK: - dirtyFreqDR (dirtyRects → per-tile touch-frequency over recent frames)

final class DirtyFreqDRClassifier: TileClassifier {
    let name = "dirtyFreqDR"
    let requiresDirtyRects = true
    private let cfg: Config.TileConfig.DirtyFreqDRConfig
    private let history: TimeBucketHistory
    init(cfg: Config.TileConfig.DirtyFreqDRConfig) {
        self.cfg = cfg
        self.history = TimeBucketHistory(
            bucketMs: cfg.bucketMs, bucketCount: cfg.bucketCount)
    }
    func reset(grid: TileGrid) {
        history.reset(tileCount: grid.tileCount)
    }
    func classify(grid: TileGrid, nowMs: UInt64,
                  dirtyRects: [CGRect]?, pixel: CVPixelBuffer) -> [UInt8] {
        // Boolean "touched this analysis" per tile — no area magnitude.
        let touched = tilesTouched(by: dirtyRects ?? [], grid: grid)
        // observe() advances the wall-clock axis: a tile that stopped
        // being touched eventually exits H.264 when enough buckets scroll
        // out of the window, without needing a "tick on idle" path.
        return history.observe(
            touched: touched, nowMs: nowMs,
            enterCount: cfg.videoFramesEnter,
            exitCount:  cfg.videoFramesExit)
    }
}

// MARK: - pixelRate (no dirtyRects; full-frame per-pixel RGB comparison)

/// Pluggable full-frame pixel-diff coverage backend for the pixelRate
/// classifier. A pixel "changed" iff its RGB differs at all from the previous
/// frame (exact inequality; the BGR*X* padding byte is ignored). The CPU
/// backend below is the default; a Metal GPU backend can conform to this
/// protocol later without touching the classifier or the AnalysisEngine.
protocol PixelRateBackend: AnyObject {
    func reset(grid: TileGrid)
    /// Fill `coverage` (length tileCount) with each tile's changed-pixel
    /// fraction vs the previous frame, then store this frame as the new
    /// previous. The first call after `reset(grid:)` compares against a
    /// zero-initialised prev buffer — coverage is bogus for that one frame
    /// (typically ≈100%) but only marks a single time-bucket bit, well
    /// inside the Schmitt's tolerance for a single-frame transient.
    func coverage(grid: TileGrid, pixel: CVPixelBuffer,
                  into coverage: inout [Double])
}

/// CPU backend: compares every pixel to the previous frame using SIMD8<UInt32>
/// lanes (8 BGRX words at a time), masking off the padding byte so only RGB is
/// compared, and counts changed pixels per tile. Tile edges (64 is a multiple
/// of the 8-lane width) and the right/bottom partial tiles fall to a scalar
/// tail so a SIMD chunk never straddles a tile boundary.
final class CPUPixelRateBackend: PixelRateBackend {
    private var prev: [UInt32] = []     // tightly packed w*h previous-frame words
    private var w = 0
    private var h = 0

    func reset(grid: TileGrid) {
        w = grid.width; h = grid.height
        prev = [UInt32](repeating: 0, count: max(0, w * h))
    }

    func coverage(grid g: TileGrid, pixel: CVPixelBuffer,
                  into coverage: inout [Double]) {
        CVPixelBufferLockBaseAddress(pixel, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
        let ts = g.tileSize, cols = g.cols, rows = g.rows
        guard let base = CVPixelBufferGetBaseAddress(pixel),
              CVPixelBufferGetWidth(pixel) == w, CVPixelBufferGetHeight(pixel) == h,
              w > 0, h > 0, prev.count == w * h else { return }
        let stride = CVPixelBufferGetBytesPerRow(pixel)
        let maskWord: UInt32 = 0x00FF_FFFF      // keep B,G,R; drop the X byte

        var changed = [Int](repeating: 0, count: cols * rows)
        prev.withUnsafeMutableBufferPointer { pbuf in
            guard let pp = pbuf.baseAddress else { return }
            let vmask  = SIMD8<UInt32>(repeating: maskWord)
            let vzeroU = SIMD8<UInt32>(repeating: 0)
            let vzeroI = SIMD8<Int32>(repeating: 0)
            let voneI  = SIMD8<Int32>(repeating: 1)
            for y in 0..<h {
                let curRow = base.advanced(by: y * stride)      // strided source row
                let preRow = pp + y * w                         // packed prev row
                let tileRowBase = (y / ts) * cols
                var x = 0
                while x < w {
                    let run = min(8, min(w - x, ts - (x % ts)))
                    if run == 8 {
                        let cur = curRow.advanced(by: x * 4)
                            .loadUnaligned(as: SIMD8<UInt32>.self)
                        let pre = UnsafeRawPointer(preRow + x)
                            .loadUnaligned(as: SIMD8<UInt32>.self)
                        let diff = (cur ^ pre) & vmask
                        let inc = vzeroI.replacing(with: voneI, where: diff .!= vzeroU)
                        changed[tileRowBase + x / ts] += Int(inc.wrappedSum())
                    } else {
                        var c = 0
                        for k in 0..<run {
                            let cw = curRow.advanced(by: (x + k) * 4)
                                .loadUnaligned(as: UInt32.self)
                            if (cw ^ preRow[x + k]) & maskWord != 0 { c += 1 }
                        }
                        changed[tileRowBase + x / ts] += c
                    }
                    x += run
                }
                // Store this frame's row as the new previous (full words; the
                // masked-off X byte is harmless since the next diff masks too).
                memcpy(preRow, curRow, w * 4)
            }
        }

        for tr in 0..<rows {
            let th = min(ts, h - tr * ts)
            for tc in 0..<cols {
                let tw = min(ts, w - tc * ts)
                let i = tr * cols + tc
                let total = tw * th
                coverage[i] = total > 0 ? Double(changed[i]) / Double(total) : 0
            }
        }
    }
}

final class PixelRateClassifier: TileClassifier {
    let name = "pixelRate"
    let requiresDirtyRects = false
    private let cfg: Config.TileConfig.PixelRateConfig
    private let history: TimeBucketHistory
    private let backend: PixelRateBackend

    init(cfg: Config.TileConfig.PixelRateConfig, backend: PixelRateBackend = CPUPixelRateBackend()) {
        self.cfg = cfg
        self.backend = backend
        self.history = TimeBucketHistory(
            bucketMs: cfg.bucketMs, bucketCount: cfg.bucketCount)
    }

    func reset(grid: TileGrid) {
        backend.reset(grid: grid)
        history.reset(tileCount: grid.tileCount)
    }

    func classify(grid: TileGrid, nowMs: UInt64,
                  dirtyRects: [CGRect]?, pixel: CVPixelBuffer) -> [UInt8] {
        var coverage = [Double](repeating: 0, count: grid.tileCount)
        backend.coverage(grid: grid, pixel: pixel, into: &coverage)
        // Per-pixel coverage IS a true magnitude, so threshold it into the
        // bucket bit (same wall-clock-bucketed Schmitt as dirtyFreqDR).
        let touched = coverage.map { $0 > cfg.perFrameCoverageThreshold }
        return history.observe(
            touched: touched, nowMs: nowMs,
            enterCount: cfg.videoFramesEnter,
            exitCount:  cfg.videoFramesExit)
    }
}
