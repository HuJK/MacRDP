//
//  AnalysisEngine.swift
//  MacRDP
//
//  Background driver for the hybrid codec's per-tile classification. Runs on
//  its own serial queue, off the capture/encode hot path: the hot path hands
//  it the latest frame + dirty rects (no copy); it asks the configured
//  TileClassifier for a per-tile decision, applies the active classifier's
//  skip/settle/hysteresis pass, and publishes the tile map.
//
//  Every per-tick tunable — cadence (when to run), the dirty-vs-pixel data
//  the classifier needs, and the post-classification stabilization — comes
//  from THE classifier that runs this tick. The engine itself owns no
//  tuning; it only orchestrates. See `Config.TileConfig` for the per-
//  classifier sub-configs.
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
    // classifier's Schmitt does. But the engine DOES need to know the last
    // codec it actually shipped to the client per tile, so it can detect
    // Schmitt-driven transitions (e.g. h264 → progressive after a video
    // pauses): when that happens for a tile that's not active this frame,
    // the engine forces a one-shot publish of the new codec. Without this,
    // the client would keep showing the old codec's frozen frame until the
    // tile became active again.
    private var grid: TileGrid
    private var primed = false
    private var submitCount: Int = 0
    private var lastAnalysisMs: UInt64 = 0
    private var lastPublishedDesired: [UInt8] = []   // per-tile last codec shipped

    init(tile: Config.TileConfig, store: TileCodecMapStore) {
        self.store = store
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
    //
    // Each tick picks the active classifier from the chain BEFORE gating the
    // cadence, because cadence is the active classifier's tuning. Pick uses a
    // peek at `pendingDirtyValid` (lock held, no reset). If gates pass, we
    // re-take the dirty state under lock and re-pick if dirtyValid flipped
    // during the peek→take window (it can only go true→false; a submit doesn't
    // reset it). That keeps the chosen classifier and the data it receives
    // consistent without holding the lock across the gate.

    private func drain() {
        // 1. Dequeue frame pointer; peek dirtyValid (read-only).
        pendingLock.lock()
        let pixel = pendingPixel
        let submittedGrid = pendingGrid
        pendingPixel = nil
        pendingGrid = nil
        drainScheduled = false
        let dirtyValidPeek = pendingDirtyValid
        pendingLock.unlock()

        guard let pixel, let submittedGrid else { return }
        guard submittedGrid == grid else { return }   // resize raced ahead

        submitCount &+= 1

        // 2. Pick active classifier from the chain using the peeked state.
        guard let activePeek = pickClassifier(dirtyValid: dirtyValidPeek) else {
            faultChainExhausted()
            return
        }

        // 3. Cadence gate, using THIS classifier's cadence. Skipping leaves
        //    the accumulated dirty rects in place for the next real tick.
        let interval = max(1, activePeek.analysis.frameInterval)
        if submitCount % interval != 0 { return }
        let now = nowMs()
        if activePeek.analysis.minIntervalMs > 0,
           now &- lastAnalysisMs < UInt64(activePeek.analysis.minIntervalMs) {
            return
        }

        // 4. Take the dirty state for real.
        pendingLock.lock()
        let dirty = pendingDirty
        let dirtyValid = pendingDirtyValid
        pendingDirty = []
        pendingDirtyValid = true
        pendingLock.unlock()

        // 5. If dirtyValid changed between peek and take (only true→false is
        //    possible — submit never re-validates), re-pick. We don't re-gate:
        //    cadence already passed once, and the chosen classifier still
        //    deserves its hysteresis applied to this tick's output.
        let active: TileClassifier
        if dirtyValid == dirtyValidPeek {
            active = activePeek
        } else if let repicked = pickClassifier(dirtyValid: dirtyValid) {
            active = repicked
        } else {
            faultChainExhausted()
            return
        }

        lastAnalysisMs = now
        analyze(pixel, dirty: dirty, dirtyValid: dirtyValid, active: active)
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
                         active classifier: TileClassifier) {
        guard grid.cols > 0, grid.rows > 0, grid.tileCount > 0 else { return }

        let (active, desired) = classifier.classify(
            grid: grid, primed: primed,
            dirtyRects: dirtyValid ? dirty : nil, pixel: pixel)
        guard active.count == grid.tileCount, desired.count == grid.tileCount else { return }

        // Three cases per tile:
        //   1. active[i] = true → send with classifier-desired codec.
        //   2. !active[i] but desired[i] changed since we last shipped a
        //      codec for this tile → Schmitt-driven transition (e.g. video
        //      paused, h264 history decayed, Schmitt exited to progressive).
        //      Force ONE publish so the client redraws this tile in the new
        //      codec; without it the client would keep displaying the old
        //      h264 frozen frame indefinitely.
        //   3. otherwise → skip (no work, no bandwidth).
        var newTiles = [UInt8](repeating: TileCodec.skip.rawValue, count: grid.tileCount)
        for i in 0..<grid.tileCount {
            if active[i] {
                newTiles[i] = desired[i]
                lastPublishedDesired[i] = desired[i]
            } else if desired[i] != lastPublishedDesired[i] {
                newTiles[i] = desired[i]
                lastPublishedDesired[i] = desired[i]
            }
        }

        primed = true
        store.publish(grid: grid, tiles: newTiles)
    }

    // MARK: - Helpers

    private func allocState(for g: TileGrid) {
        // The client starts every (re-)negotiated surface blank → it's
        // showing nothing, which is equivalent to "progressive". Seed
        // lastPublishedDesired to Progressive so a tile's first emit at
        // h264 counts as a transition, and a tile that never leaves
        // Progressive never spuriously force-publishes.
        let n = max(0, g.tileCount)
        lastPublishedDesired = [UInt8](repeating: TileCodec.progressive.rawValue, count: n)
        submitCount = 0
    }

    private func nowMs() -> UInt64 {
        UInt64(DispatchTime.now().uptimeNanoseconds / 1_000_000)
    }
}
