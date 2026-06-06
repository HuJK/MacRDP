//
//  AnalysisEngine.swift
//  MacRDP
//
//  Background driver for the hybrid codec's per-tile classification. Runs on
//  its own serial queue, off the capture/encode hot path: the hot path hands
//  it the latest frame + dirty rects (no copy); it asks the configured
//  TileClassifier for a per-tile decision and publishes the tile map.
//
//  Tick cadence is `tile.analysis` — shared across the classifier chain,
//  because the engine ticks at one rate regardless of which chain entry
//  wins this tick. Per-classifier thresholds (Schmitt band, history window,
//  coverage cutoffs) come from `tile.<classifier>.*` and are read only by
//  the classifier itself; the engine doesn't own classifier tuning.
//
//  No silent fallback: if the chain has nothing whose data requirements are
//  met this tick (every entry needs dirtyRects, none available), the engine
//  logs a fault and exits so the operator switches `video.tile.classifiers`
//  to one that doesn't (e.g. "pixelRate").
//

import Foundation
@preconcurrency import CoreMedia
@preconcurrency import CoreVideo
import CoreGraphics
import os

final class AnalysisEngine: @unchecked Sendable {
    private let store: TileCodecMapStore
    private let chain: [TileClassifier]     // ordered fallback chain
    private let cadence: Config.TileConfig.AnalysisCadence
    private let queue = DispatchQueue(label: "com.macrdp.analysis", qos: .utility)

    // --- pending input (written on MainActor, drained on `queue`) ---
    private let pendingLock = NSLock()
    private var pendingPixel: CVPixelBuffer?
    private var pendingGrid: TileGrid?
    private var pendingDirty: [CGRect] = []     // accumulated across skipped frames
    private var pendingDirtyValid = true        // false if any frame lacked dirty info
    private var drainScheduled = false

    // --- engine-owned state (touched only on `queue`) ---
    //
    // The engine doesn't decide which codec a tile should use — the
    // classifier's Schmitt does. And it carries no per-tile bookkeeping
    // either: every analysis publishes one codec per tile (no `.skip`
    // sentinel), so the published map always covers the full surface and
    // route() always emits a blit instruction for every tile. That removes
    // the whole class of "client surface stuck on stale pixels because we
    // forgot to publish for a few ticks" bugs that the old
    // active/wasActive/lastPublishedDesired logic existed to paper over.
    private var grid: TileGrid
    private var submitCount: Int = 0

    init(tile: Config.TileConfig, store: TileCodecMapStore) {
        self.store = store
        self.cadence = tile.analysis
        var built: [TileClassifier] = []
        for name in tile.classifiers {
            if let c = makeTileClassifier(named: name, tile: tile) { built.append(c) }
            else { LogTo.encoder.error("Ignoring unknown tile classifier \"\(name)\"") }
        }
        if built.isEmpty {
            LogTo.encoder.fault("video.tile.classifiers has no valid entries \(tile.classifiers); exiting")
            exit(EXIT_FAILURE)
        }
        self.chain = built
        self.grid = store.currentGrid
        for c in built { c.reset(grid: grid) }
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
            self.submitCount = 0
            for c in self.chain { c.reset(grid: newGrid) }
            self.pendingLock.lock()
            self.pendingDirty.removeAll(); self.pendingDirtyValid = true
            self.pendingLock.unlock()
        }
    }

    // MARK: - Drain / cadence
    //
    // Cadence is shared across the chain (`cadence` is set once at init from
    // `tile.analysis`), so the gate is independent of which classifier wins
    // this tick: gate first, then take dirty state, then pick. Skipping the
    // gate leaves the accumulated dirty rects in place for the next real
    // tick — no rect is silently dropped between analyses.

    private func drain() {
        // 1. Dequeue frame pointer. Dirty state stays in `pendingDirty` —
        //    we'll only take it if the cadence gate lets this tick through.
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

        // 2. Cadence gate (CPU throttle, from `tile.analysis.frameInterval`).
        //    Wall-clock alignment is the time-bucket window's job — extra
        //    observations within a bucket OR idempotently, so a brief submit
        //    burst is harmless and we don't need a separate minIntervalMs
        //    backstop.
        let interval = max(1, cadence.frameInterval)
        if submitCount % interval != 0 { return }

        // 3. Take the dirty state. One lock-grab, no peek/take dance — the
        //    cadence decision above doesn't depend on dirtyValid, so there's
        //    nothing to re-evaluate after taking.
        pendingLock.lock()
        let dirty = pendingDirty
        let dirtyValid = pendingDirtyValid
        pendingDirty = []
        pendingDirtyValid = true
        pendingLock.unlock()

        // 4. Pick the active classifier from the chain now that we know the
        //    dirty state. If the chain is exhausted (every entry needs
        //    dirtyRects, none available), fault out — operator must add
        //    "pixelRate" or switch off the hybrid codec.
        guard let active = pickClassifier(dirtyValid: dirtyValid) else {
            faultChainExhausted()
            return
        }

        analyze(pixel, dirty: dirty, dirtyValid: dirtyValid,
                active: active, nowMs: nowMs())
    }

    private func pickClassifier(dirtyValid: Bool) -> TileClassifier? {
        for c in chain where !c.requiresDirtyRects || dirtyValid { return c }
        return nil
    }

    private func faultChainExhausted() -> Never {
        let names = chain.map { $0.name }.joined(separator: ", ")
        LogTo.encoder.fault("""
            Hybrid classifier chain [\(names)] is exhausted: every \
            entry requires ScreenCaptureKit dirtyRects, which are unavailable. Add \
            "pixelRate" to video.tile.classifiers, or set video.codec to a non-hybrid \
            codec. Exiting.
            """)
        exit(EXIT_FAILURE)
    }

    // MARK: - Analyze

    private func analyze(_ pixel: CVPixelBuffer, dirty: [CGRect], dirtyValid: Bool,
                         active classifier: TileClassifier, nowMs: UInt64) {
        guard grid.cols > 0, grid.rows > 0, grid.tileCount > 0 else { return }

        let desired = classifier.classify(
            grid: grid, nowMs: nowMs,
            dirtyRects: dirtyValid ? dirty : nil, pixel: pixel)
        guard desired.count == grid.tileCount else { return }

        // No filter, no .skip — every tile gets its current Schmitt-latched
        // codec published every tick. coalesce() then turns the full map
        // into videoRects + staticRects that together cover the whole
        // surface. The client repaints every tile every frame, so any
        // pixel change in the source surface lands on the client surface
        // on the next .complete regardless of dirty-rect coverage gaps.
        store.publish(grid: grid, tiles: desired)
    }

    // MARK: - Helpers

    private func nowMs() -> UInt64 {
        UInt64(DispatchTime.now().uptimeNanoseconds / 1_000_000)
    }
}
