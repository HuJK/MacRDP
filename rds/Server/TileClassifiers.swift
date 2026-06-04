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
    /// Cadence the engine should use while THIS classifier is the active one
    /// (when to run / how often). Lives with the classifier so two classifiers
    /// can't accidentally share a cadence.
    var analysis: Config.TileConfig.AnalysisCadence { get }
    /// Re-size internal state for a new grid (resolution change).
    func reset(grid: TileGrid)
    /// Per-tile decision for one frame. `dirtyRects` is guaranteed non-nil
    /// when `requiresDirtyRects`. `pixel` is used only by pixel-based
    /// classifiers (they lock it themselves). Returns parallel arrays of
    /// length tileCount: `active` is "should we send this tile this frame";
    /// `desired` is "which codec if we do send it". The engine treats
    /// `!active` as skip and never overrides `desired`.
    func classify(grid: TileGrid, primed: Bool,
                  dirtyRects: [CGRect]?, pixel: CVPixelBuffer)
        -> (active: [Bool], desired: [UInt8])
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

/// A tile is "active" (worth sending) if enough of it changed. First frame:
/// everything active (full repaint).
private func activeMask(_ coverage: [Double], primed: Bool, threshold: Double) -> [Bool] {
    coverage.map { primed ? ($0 >= threshold) : true }
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

/// Rolling per-tile bit history → windowed set-bit fraction → Schmitt-trigger
/// codec decision (dual threshold).
///
///   dirtyFreqDR pushes "tile was touched this frame";
///   pixelRate   pushes "real changed-pixel coverage was high this frame".
///
/// The set-bit fraction over the recent window is the video signal; the
/// enter/exit band stops it flickering when the fraction hovers around a
/// single cutoff (e.g. bouncing 0.3↔0.5 around 0.4).
///
/// Storage: per-tile ring buffer of bits, with the window length set at
/// reset time. The window honors `historyFrames` verbatim (no silent cap);
/// memory cost is `tileCount * historyFrames` bytes, which is well under a
/// MB even at 4K/64.
///
/// Schmitt updates EVERY analysis for EVERY tile, regardless of whether the
/// tile is being touched this frame. That's the only enter/exit mechanism:
/// when the tile stops changing, the window fills with 0s, the fraction
/// decays past `videoFractionExit`, and the Schmitt flips back to
/// Progressive on its own. There is no separate "settle on idle" path.
private final class BitHistory {
    private var window: Int = 1
    private var bits: [Bool] = []       // flat ring: bits[i * window + j]
    private var head: [Int] = []        // next-write position per tile (0..<window)
    private var popcount: [Int] = []    // current 1-bit count in window per tile
    private var videoState: [Bool] = [] // last Schmitt decision per tile

    func reset(tileCount: Int, window: Int) {
        self.window = max(1, window)
        bits = [Bool](repeating: false, count: tileCount * self.window)
        head = [Int](repeating: 0, count: tileCount)
        popcount = [Int](repeating: 0, count: tileCount)
        videoState = [Bool](repeating: false, count: tileCount)
    }

    /// Shift `newBits[i]` into tile i's ring; maintain `popcount` in O(1).
    /// If the per-frame array doesn't match our tile count (resize raced),
    /// re-init at the new count, keeping the configured window.
    func push(_ newBits: [Bool]) {
        if head.count != newBits.count {
            reset(tileCount: newBits.count, window: window)
        }
        for i in 0..<head.count {
            let slot = i * window + head[i]
            let old = bits[slot]
            let new = newBits[i]
            bits[slot] = new
            if old != new {
                popcount[i] += new ? 1 : -1
            }
            head[i] = (head[i] + 1) % window
        }
    }

    /// Run the Schmitt update for every tile and return the per-tile codec
    /// decision. `enterFraction` > `exitFraction`.
    func updateAndRead(enterFraction: Double, exitFraction: Double) -> [UInt8] {
        let n = popcount.count
        var out = [UInt8](repeating: TileCodec.progressive.rawValue, count: n)
        let denom = Double(window)
        for i in 0..<n {
            let frac = Double(popcount[i]) / denom
            if videoState[i] {
                if frac < exitFraction { videoState[i] = false }
            } else if frac >= enterFraction {
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
    var analysis: Config.TileConfig.AnalysisCadence { cfg.analysis }
    init(cfg: Config.TileConfig.BlobDRConfig) { self.cfg = cfg }
    func reset(grid: TileGrid) {}
    func classify(grid: TileGrid, primed: Bool, dirtyRects: [CGRect]?, pixel: CVPixelBuffer)
        -> (active: [Bool], desired: [UInt8]) {
        let coverage = coverageFromDirtyRects(dirtyRects ?? [], grid: grid)
        let active = activeMask(coverage, primed: primed, threshold: cfg.tileActiveCoverage)
        var desired = [UInt8](repeating: TileCodec.progressive.rawValue, count: grid.tileCount)
        classifyByRegionArea(active: active, grid: grid,
                             largeRegionTiles: cfg.largeRegionTiles, into: &desired)
        return (active, desired)
    }
}

// MARK: - dirtyFreqDR (dirtyRects → per-tile touch-frequency over recent frames)

final class DirtyFreqDRClassifier: TileClassifier {
    let name = "dirtyFreqDR"
    let requiresDirtyRects = true
    private let cfg: Config.TileConfig.DirtyFreqDRConfig
    private let history = BitHistory()
    var analysis: Config.TileConfig.AnalysisCadence { cfg.analysis }
    init(cfg: Config.TileConfig.DirtyFreqDRConfig) { self.cfg = cfg }
    func reset(grid: TileGrid) {
        history.reset(tileCount: grid.tileCount, window: cfg.historyFrames)
    }
    func classify(grid: TileGrid, primed: Bool, dirtyRects: [CGRect]?, pixel: CVPixelBuffer)
        -> (active: [Bool], desired: [UInt8]) {
        // Boolean "touched this frame" per tile — no area magnitude. A tile is
        // active (worth sending) iff it was touched; first frame = full repaint.
        let touched = tilesTouched(by: dirtyRects ?? [], grid: grid)
        let active = primed ? touched : [Bool](repeating: true, count: grid.tileCount)
        // Schmitt runs EVERY analysis on EVERY tile (touched or not). That's
        // how a tile that stops being touched eventually exits H.264 — the
        // window fills with 0s, the fraction decays past videoFractionExit.
        history.push(touched)
        let desired = history.updateAndRead(
            enterFraction: cfg.videoFractionEnter,
            exitFraction:  cfg.videoFractionExit)
        return (active, desired)
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
    /// previous. When `primed` is false this only stores (coverage stays 0,
    /// since there is no prior frame to diff against).
    func coverage(grid: TileGrid, primed: Bool, pixel: CVPixelBuffer,
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

    func coverage(grid g: TileGrid, primed: Bool, pixel: CVPixelBuffer,
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
                if primed {
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
                }
                // Store this frame's row as the new previous (full words; the
                // masked-off X byte is harmless since the next diff masks too).
                memcpy(preRow, curRow, w * 4)
            }
        }

        guard primed else { return }        // first frame: no prior → leave at 0
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
    private let history = BitHistory()
    private let backend: PixelRateBackend
    var analysis: Config.TileConfig.AnalysisCadence { cfg.analysis }

    init(cfg: Config.TileConfig.PixelRateConfig, backend: PixelRateBackend = CPUPixelRateBackend()) {
        self.cfg = cfg
        self.backend = backend
    }

    func reset(grid: TileGrid) {
        backend.reset(grid: grid)
        history.reset(tileCount: grid.tileCount, window: cfg.historyFrames)
    }

    func classify(grid: TileGrid, primed: Bool, dirtyRects: [CGRect]?, pixel: CVPixelBuffer)
        -> (active: [Bool], desired: [UInt8]) {
        var coverage = [Double](repeating: 0, count: grid.tileCount)
        backend.coverage(grid: grid, primed: primed, pixel: pixel, into: &coverage)
        let active = activeMask(coverage, primed: primed, threshold: cfg.tileActiveCoverage)
        // Per-pixel coverage IS a true magnitude, so threshold it into the bit.
        // Schmitt runs every analysis (see DirtyFreqDR for the same rationale).
        history.push(coverage.map { $0 > cfg.perFrameCoverageThreshold })
        let desired = history.updateAndRead(
            enterFraction: cfg.videoFractionEnter,
            exitFraction:  cfg.videoFractionExit)
        return (active, desired)
    }
}
