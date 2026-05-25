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
    /// Per-tile decision for one frame. `dirtyRects` is guaranteed non-nil when
    /// `requiresDirtyRects`. `pixel` is used only by pixel-based classifiers
    /// (they lock it themselves). Returns parallel arrays of length tileCount.
    func classify(grid: TileGrid, primed: Bool,
                  dirtyRects: [CGRect]?, pixel: CVPixelBuffer)
        -> (active: [Bool], desired: [UInt8])
}

/// Build one classifier by name, or nil if the name is unknown.
func makeTileClassifier(named name: String, cfg: Config.HybridConfig) -> TileClassifier? {
    switch name.lowercased() {
    case "blobdr":      return BlobDRClassifier(cfg: cfg)
    case "dirtyfreqdr": return DirtyFreqDRClassifier(cfg: cfg)
    case "pixelrate":   return PixelRateClassifier(cfg: cfg)
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

/// Rolling per-tile bit history → windowed set-bit fraction, turned into a
/// codec decision via a Schmitt trigger (dual threshold). dirtyFreqDR feeds
/// "tile was touched this frame"; pixelRate feeds "real pixel-coverage was
/// high this frame". The set-bit fraction over the recent window is the video
/// signal; the enter/exit band stops it flickering when the fraction hovers
/// around a single cutoff (e.g. bouncing 0.3↔0.5 around 0.4).
private final class BitHistory {
    private var hist: [UInt32] = []
    private var videoState: [Bool] = []     // last Schmitt decision per tile
    func reset(_ n: Int) {
        hist = [UInt32](repeating: 0, count: max(0, n))
        videoState = [Bool](repeating: false, count: max(0, n))
    }
    func push(_ bits: [Bool]) {
        if hist.count != bits.count { hist = [UInt32](repeating: 0, count: bits.count) }
        for i in bits.indices {
            hist[i] = (hist[i] << 1) | (bits[i] ? 1 : 0)
        }
    }
    /// `enterFraction` > `exitFraction`. A tile becomes video once its windowed
    /// set-bit fraction reaches `enterFraction`, and reverts to non-video only
    /// once it drops below `exitFraction`; in between it holds its last state.
    func desired(active: [Bool], windowFrames: Int,
                 enterFraction: Double, exitFraction: Double) -> [UInt8] {
        let window = min(32, max(1, windowFrames))
        let mask: UInt32 = window >= 32 ? .max : ((1 << UInt32(window)) - 1)
        if videoState.count != hist.count { videoState = [Bool](repeating: false, count: hist.count) }
        var out = [UInt8](repeating: TileCodec.progressive.rawValue, count: hist.count)
        for i in hist.indices {
            if i < active.count && active[i] {
                let frac = Double((hist[i] & mask).nonzeroBitCount) / Double(window)
                if videoState[i] {
                    if frac < exitFraction { videoState[i] = false }
                } else if frac >= enterFraction {
                    videoState[i] = true
                }
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
    private let cfg: Config.HybridConfig
    init(cfg: Config.HybridConfig) { self.cfg = cfg }
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
    private let cfg: Config.HybridConfig
    private let history = BitHistory()
    init(cfg: Config.HybridConfig) { self.cfg = cfg }
    func reset(grid: TileGrid) { history.reset(grid.tileCount) }
    func classify(grid: TileGrid, primed: Bool, dirtyRects: [CGRect]?, pixel: CVPixelBuffer)
        -> (active: [Bool], desired: [UInt8]) {
        // Boolean "touched this frame" per tile — no area magnitude. A tile is
        // active (worth sending) iff it was touched; first frame = full repaint.
        let touched = tilesTouched(by: dirtyRects ?? [], grid: grid)
        let active = primed ? touched : [Bool](repeating: true, count: grid.tileCount)
        history.push(touched)
        let desired = history.desired(active: active,
                                      windowFrames: cfg.coverageHistoryFrames,
                                      enterFraction: cfg.videoFractionEnter,
                                      exitFraction: cfg.videoFractionExit)
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
    private let cfg: Config.HybridConfig
    private let history = BitHistory()
    private let backend: PixelRateBackend

    init(cfg: Config.HybridConfig, backend: PixelRateBackend = CPUPixelRateBackend()) {
        self.cfg = cfg
        self.backend = backend
    }

    func reset(grid: TileGrid) {
        backend.reset(grid: grid)
        history.reset(grid.tileCount)
    }

    func classify(grid: TileGrid, primed: Bool, dirtyRects: [CGRect]?, pixel: CVPixelBuffer)
        -> (active: [Bool], desired: [UInt8]) {
        var coverage = [Double](repeating: 0, count: grid.tileCount)
        backend.coverage(grid: grid, primed: primed, pixel: pixel, into: &coverage)
        let active = activeMask(coverage, primed: primed, threshold: cfg.tileActiveCoverage)
        // Per-pixel coverage IS a true magnitude, so threshold it into the bit.
        history.push(coverage.map { $0 > cfg.coverageHighThreshold })
        let desired = history.desired(active: active,
                                      windowFrames: cfg.coverageHistoryFrames,
                                      enterFraction: cfg.videoFractionEnter,
                                      exitFraction: cfg.videoFractionExit)
        return (active, desired)
    }
}
