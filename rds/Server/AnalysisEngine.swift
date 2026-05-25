//
//  AnalysisEngine.swift
//  MacRDP
//
//  Background driver for the hybrid codec's per-tile classification. Runs on
//  its own serial queue, off the capture/encode hot path: the hot path hands
//  it the latest frame + dirty rects (no copy); it asks the configured
//  TileClassifier for a per-tile decision, applies the shared skip/settle/
//  hysteresis pass, and publishes the tile map.
//
//  No silent fallback: if the selected classifier requires dirtyRects and they
//  are unavailable, the engine logs a fault and exits so the operator switches
//  `video.hybrid.classifier` to one that doesn't (e.g. "pixelRate").
//

import Foundation
@preconcurrency import CoreMedia
@preconcurrency import CoreVideo
import CoreGraphics
import os

final class AnalysisEngine: @unchecked Sendable {
    private let cfg: Config.HybridConfig
    private let store: TileCodecMapStore
    private let chain: [TileClassifier]     // ordered fallback chain
    private let queue = DispatchQueue(label: "com.macrdp.analysis", qos: .utility)

    // --- pending input (written on MainActor, drained on `queue`) ---
    private let pendingLock = NSLock()
    private var pendingPixel: CVPixelBuffer?
    private var pendingGrid: TileGrid?
    private var pendingDirty: [CGRect] = []     // accumulated across skipped frames
    private var pendingDirtyValid = true        // false if any frame lacked dirty info
    private var drainScheduled = false

    // --- engine-owned finalize state (touched only on `queue`) ---
    private var grid: TileGrid
    private var primed = false
    private var lastCodec: [UInt8] = []         // last {progressive,h264} decision per tile
    private var wasActive: [Bool] = []          // was the tile changing last analysis?
    private var candCodec: [UInt8] = []         // hysteresis candidate
    private var candRun: [Int] = []             // consecutive analyses the candidate held
    private var submitCount: Int = 0
    private var lastAnalysisMs: UInt64 = 0

    init(hybrid: Config.HybridConfig, store: TileCodecMapStore) {
        self.cfg = hybrid
        self.store = store
        var built: [TileClassifier] = []
        for name in hybrid.classifiers {
            if let c = makeTileClassifier(named: name, cfg: hybrid) { built.append(c) }
            else { Log.encoder.error("Ignoring unknown hybrid classifier \"\(name, privacy: .public)\"") }
        }
        if built.isEmpty {
            Log.encoder.fault("video.hybrid.classifiers has no valid entries \(hybrid.classifiers, privacy: .public); exiting")
            exit(EXIT_FAILURE)
        }
        self.chain = built
        self.grid = store.currentGrid
        for c in built { c.reset(grid: grid) }
        allocState(for: grid)
    }

    // MARK: - Hot-path entry (MainActor)

    /// Hand over the freshest frame + its dirty rects (surface pixel coords;
    /// nil = unavailable). Non-blocking: retains the buffer, unions dirty
    /// rects, and schedules a drain if none pending.
    func submit(frame: CVPixelBuffer, grid: TileGrid, dirtyRects: [CGRect]?) {
        pendingLock.lock()
        pendingPixel = frame
        pendingGrid = grid
        if let dr = dirtyRects { pendingDirty.append(contentsOf: dr) }
        else { pendingDirtyValid = false }
        let needSchedule = !drainScheduled
        if needSchedule { drainScheduled = true }
        pendingLock.unlock()
        guard needSchedule else { return }
        queue.async { [weak self] in self?.drain() }
    }

    /// Resolution change: re-grid and drop stale state.
    func rebuildGrid(_ newGrid: TileGrid) {
        queue.async { [weak self] in
            guard let self else { return }
            self.grid = newGrid
            self.primed = false
            for c in self.chain { c.reset(grid: newGrid) }
            self.allocState(for: newGrid)
            self.pendingLock.lock()
            self.pendingDirty.removeAll(); self.pendingDirtyValid = true
            self.pendingLock.unlock()
        }
    }

    // MARK: - Drain / cadence

    private func drain() {
        pendingLock.lock()
        let pixel = pendingPixel
        let submittedGrid = pendingGrid
        pendingPixel = nil
        pendingGrid = nil
        drainScheduled = false
        pendingLock.unlock()

        guard let pixel, let submittedGrid else { return }
        guard submittedGrid == grid else { return }   // resize raced ahead

        submitCount &+= 1
        let interval = max(1, cfg.analysisFrameInterval)
        // Skipping for cadence/rate keeps the accumulated dirty rects so the
        // next real analysis sees every change since the last one.
        if submitCount % interval != 0 { return }
        let now = nowMs()
        if cfg.analysisMinIntervalMs > 0,
           now &- lastAnalysisMs < UInt64(cfg.analysisMinIntervalMs) {
            return
        }

        pendingLock.lock()
        let dirty = pendingDirty
        let dirtyValid = pendingDirtyValid
        pendingDirty = []
        pendingDirtyValid = true
        pendingLock.unlock()

        lastAnalysisMs = now
        analyze(pixel, dirty: dirty, dirtyValid: dirtyValid)
    }

    // MARK: - Analyze

    private func analyze(_ pixel: CVPixelBuffer, dirty: [CGRect], dirtyValid: Bool) {
        guard grid.cols > 0, grid.rows > 0, grid.tileCount == lastCodec.count else { return }

        // Walk the fallback chain: first classifier whose requirements are met.
        var chosen: TileClassifier?
        for c in chain where !c.requiresDirtyRects || dirtyValid { chosen = c; break }
        guard let classifier = chosen else {
            // Chain exhausted — every classifier needs dirtyRects, none available.
            let names = chain.map { $0.name }.joined(separator: ", ")
            Log.encoder.fault("""
                Hybrid classifier chain [\(names, privacy: .public)] is exhausted: every \
                entry requires ScreenCaptureKit dirtyRects, which are unavailable. Add \
                "pixelRate" to video.hybrid.classifiers, or set video.codec to a non-hybrid \
                codec. Exiting.
                """)
            exit(EXIT_FAILURE)
        }

        let (active, desired) = classifier.classify(
            grid: grid, primed: primed,
            dirtyRects: dirtyValid ? dirty : nil, pixel: pixel)
        guard active.count == grid.tileCount, desired.count == grid.tileCount else { return }

        // Shared finalize: skip / settle for inactive tiles, hysteresis on switches.
        let H = max(1, cfg.codecSwitchHysteresisFrames)
        var newTiles = [UInt8](repeating: TileCodec.skip.rawValue, count: grid.tileCount)
        for i in 0..<grid.tileCount {
            if active[i] {
                let want = desired[i]
                let final: UInt8
                if want == lastCodec[i] {
                    final = want; candRun[i] = 0
                } else {
                    if candCodec[i] == want { candRun[i] += 1 }
                    else { candCodec[i] = want; candRun[i] = 1 }
                    if candRun[i] >= H { final = want; lastCodec[i] = want; candRun[i] = 0 }
                    else { final = lastCodec[i] }
                }
                newTiles[i] = final
                wasActive[i] = true
            } else {
                if wasActive[i] && cfg.settleRepaint && lastCodec[i] == TileCodec.h264.rawValue {
                    newTiles[i] = TileCodec.progressive.rawValue
                    lastCodec[i] = TileCodec.progressive.rawValue
                } else {
                    newTiles[i] = TileCodec.skip.rawValue
                }
                candRun[i] = 0
                wasActive[i] = false
            }
        }

        primed = true
        store.publish(grid: grid, tiles: newTiles)
    }

    // MARK: - Helpers

    private func allocState(for g: TileGrid) {
        let n = max(0, g.tileCount)
        lastCodec = [UInt8](repeating: TileCodec.progressive.rawValue, count: n)
        wasActive = [Bool](repeating: false, count: n)
        candCodec = [UInt8](repeating: TileCodec.progressive.rawValue, count: n)
        candRun   = [Int](repeating: 0, count: n)
        submitCount = 0
    }

    private func nowMs() -> UInt64 {
        UInt64(DispatchTime.now().uptimeNanoseconds / 1_000_000)
    }
}
