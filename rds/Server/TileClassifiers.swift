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
//  user switches to a classifier that doesn't need it (e.g. "luma").
//
//    "region"          — dirtyRects coverage → connected-component AREA.
//    "coverageHistory" — dirtyRects coverage → fraction of recent frames whose
//                        coverage was high.
//    "luma"            — per-pixel luma-delta coverage → same coverage-history
//                        rule, but needs no dirtyRects.
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
    case "region":          return RegionClassifier(cfg: cfg)
    case "coveragehistory": return CoverageHistoryClassifier(cfg: cfg)
    case "luma":            return LumaClassifier(cfg: cfg)
    default:                return nil
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

/// Rolling per-tile "high-coverage" bit history → coverage-history decision.
private final class CoverageHistory {
    private var hist: [UInt32] = []
    func reset(_ n: Int) { hist = [UInt32](repeating: 0, count: max(0, n)) }
    func push(_ coverage: [Double], highThreshold: Double) {
        if hist.count != coverage.count { hist = [UInt32](repeating: 0, count: coverage.count) }
        for i in coverage.indices {
            hist[i] = (hist[i] << 1) | (coverage[i] > highThreshold ? 1 : 0)
        }
    }
    func desired(active: [Bool], windowFrames: Int, videoFraction: Double) -> [UInt8] {
        let window = min(32, max(1, windowFrames))
        let mask: UInt32 = window >= 32 ? .max : ((1 << UInt32(window)) - 1)
        var out = [UInt8](repeating: TileCodec.progressive.rawValue, count: hist.count)
        for i in hist.indices where i < active.count && active[i] {
            let frac = Double((hist[i] & mask).nonzeroBitCount) / Double(window)
            out[i] = frac >= videoFraction ? TileCodec.h264.rawValue : TileCodec.progressive.rawValue
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

// MARK: - region

final class RegionClassifier: TileClassifier {
    let name = "region"
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

// MARK: - coverageHistory

final class CoverageHistoryClassifier: TileClassifier {
    let name = "coverageHistory"
    let requiresDirtyRects = true
    private let cfg: Config.HybridConfig
    private let history = CoverageHistory()
    init(cfg: Config.HybridConfig) { self.cfg = cfg }
    func reset(grid: TileGrid) { history.reset(grid.tileCount) }
    func classify(grid: TileGrid, primed: Bool, dirtyRects: [CGRect]?, pixel: CVPixelBuffer)
        -> (active: [Bool], desired: [UInt8]) {
        let coverage = coverageFromDirtyRects(dirtyRects ?? [], grid: grid)
        let active = activeMask(coverage, primed: primed, threshold: cfg.tileActiveCoverage)
        history.push(coverage, highThreshold: cfg.coverageHighThreshold)
        let desired = history.desired(active: active,
                                      windowFrames: cfg.coverageHistoryFrames,
                                      videoFraction: cfg.coverageVideoFraction)
        return (active, desired)
    }
}

// MARK: - luma (no dirtyRects needed)

final class LumaClassifier: TileClassifier {
    let name = "luma"
    let requiresDirtyRects = false
    private let cfg: Config.HybridConfig
    private let history = CoverageHistory()
    private var prev: [UInt8] = []
    private var cur: [UInt8] = []
    private var sampledW = 0
    private var sampledH = 0

    init(cfg: Config.HybridConfig) { self.cfg = cfg }

    func reset(grid: TileGrid) {
        let step = max(1, cfg.spatialSampleStride)
        sampledW = grid.width  > 0 ? (grid.width  + step - 1) / step : 0
        sampledH = grid.height > 0 ? (grid.height + step - 1) / step : 0
        let n = max(0, sampledW * sampledH)
        prev = [UInt8](repeating: 0, count: n)
        cur  = [UInt8](repeating: 0, count: n)
        history.reset(grid.tileCount)
    }

    func classify(grid: TileGrid, primed: Bool, dirtyRects: [CGRect]?, pixel: CVPixelBuffer)
        -> (active: [Bool], desired: [UInt8]) {
        var coverage = [Double](repeating: 0, count: grid.tileCount)
        computeLumaCoverage(grid: grid, primed: primed, pixel: pixel, into: &coverage)
        let active = activeMask(coverage, primed: primed, threshold: cfg.tileActiveCoverage)
        history.push(coverage, highThreshold: cfg.coverageHighThreshold)
        let desired = history.desired(active: active,
                                      windowFrames: cfg.coverageHistoryFrames,
                                      videoFraction: cfg.coverageVideoFraction)
        return (active, desired)
    }

    private func computeLumaCoverage(grid g: TileGrid, primed: Bool,
                                     pixel: CVPixelBuffer, into coverage: inout [Double]) {
        CVPixelBufferLockBaseAddress(pixel, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
        let w = g.width, h = g.height, ts = g.tileSize, cols = g.cols
        guard let base = CVPixelBufferGetBaseAddress(pixel),
              CVPixelBufferGetWidth(pixel) == w, CVPixelBufferGetHeight(pixel) == h,
              sampledW > 0, sampledH > 0, prev.count == sampledW * sampledH else { return }
        let stride = CVPixelBufferGetBytesPerRow(pixel)
        let px = base.assumingMemoryBound(to: UInt8.self)
        let step = max(1, cfg.spatialSampleStride)
        let noise = Int(cfg.pixelNoiseThreshold)
        var changed = [Int](repeating: 0, count: grid_tileCount(g))
        var samples = [Int](repeating: 0, count: grid_tileCount(g))
        for sy in 0..<sampledH {
            let y = sy * step
            if y >= h { break }
            let rowBase = y * stride
            let tileRow = y / ts
            for sx in 0..<sampledW {
                let x = sx * step
                if x >= w { break }
                let p = rowBase + x * 4
                let b = Int(px[p]); let gg = Int(px[p + 1]); let r = Int(px[p + 2])
                let luma = UInt8(truncatingIfNeeded: (r * 77 + gg * 150 + b * 29) >> 8)
                let fIdx = sy * sampledW + sx
                cur[fIdx] = luma
                let t = tileRow * cols + (x / ts)
                samples[t] += 1
                if primed && abs(Int(luma) - Int(prev[fIdx])) > noise { changed[t] += 1 }
            }
        }
        for i in coverage.indices {
            coverage[i] = samples[i] > 0 ? Double(changed[i]) / Double(samples[i]) : 0
        }
        swap(&prev, &cur)
    }

    private func grid_tileCount(_ g: TileGrid) -> Int { g.tileCount }
}
