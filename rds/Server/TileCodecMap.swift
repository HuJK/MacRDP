//
//  TileCodecMap.swift
//  MacRDP
//
//  Shared, bridge-agnostic types for the hybrid per-tile codec.
//
//  A frame is divided into a grid of square tiles. A background analysis
//  thread classifies each tile (skip / progressive / h264) and publishes a
//  flat byte map into `TileCodecMapStore`. The capture/encode/send path reads
//  the latest published map (a value snapshot under a short lock — never
//  blocks on analysis) and `coalesce`s same-codec tiles into rectangles to
//  drive the two RDPGFX surface commands.
//
//  Nothing here depends on the FreeRDP bridge, so it always compiles. The
//  bridge-side glue lives in HybridCoordinator.swift (guarded by
//  MACRDP_BRIDGE_AVAILABLE).
//

import Foundation
@preconcurrency import CoreMedia
@preconcurrency import CoreVideo
import CoreGraphics

/// Per-tile codec decision. Stored as the raw `UInt8` in the map buffer.
enum TileCodec: UInt8 {
    case skip        = 0   // unchanged since last frame → send via neither codec
    case progressive = 1   // text / static / UI → RemoteFX Progressive
    case h264        = 2   // video / photographic / motion → AVC420
}

/// A rectangle in surface pixel coordinates. Field order matches the C
/// `macrdp_rect16` so HybridCoordinator can convert with a plain init.
struct Rect16: Sendable, Equatable {
    var left: UInt16
    var top: UInt16
    var right: UInt16
    var bottom: UInt16
}

/// Tile geometry derived from the capture resolution. Rebuilt on every
/// resolution change — never hardcoded.
struct TileGrid: Sendable, Equatable {
    let width: Int
    let height: Int
    let tileSize: Int
    let cols: Int
    let rows: Int

    init(width: Int, height: Int, tileSize: Int) {
        let ts = max(1, tileSize)
        self.width = max(0, width)
        self.height = max(0, height)
        self.tileSize = ts
        self.cols = self.width  > 0 ? (self.width  + ts - 1) / ts : 0
        self.rows = self.height > 0 ? (self.height + ts - 1) / ts : 0
    }

    var tileCount: Int { cols * rows }

    /// Pixel rect of a tile, clamped to the surface on the right/bottom edge.
    func rect(col: Int, row: Int) -> Rect16 {
        let x = col * tileSize
        let y = row * tileSize
        let r = min(x + tileSize, width)
        let b = min(y + tileSize, height)
        return Rect16(left: UInt16(clamping: x), top: UInt16(clamping: y),
                      right: UInt16(clamping: r), bottom: UInt16(clamping: b))
    }
}

/// Single-writer (analysis thread) / single-reader (encode path) holder for
/// the published tile map. The lock is held only for the pointer/array swap
/// and the snapshot read; reads return a COW value snapshot so the reader
/// never sees a torn map and the writer never blocks the encode path.
final class TileCodecMapStore: @unchecked Sendable {
    private let lock = NSLock()
    private var grid: TileGrid
    private var tiles: [UInt8]

    init(initialGrid: TileGrid) {
        self.grid = initialGrid
        self.tiles = [UInt8](repeating: TileCodec.progressive.rawValue,
                             count: max(0, initialGrid.tileCount))
    }

    /// The most recently published grid.
    var currentGrid: TileGrid {
        lock.lock(); defer { lock.unlock() }
        return grid
    }

    /// Writer: publish a freshly classified map for `grid`. Ignored if the
    /// grid no longer matches the published one (a resize raced ahead).
    func publish(grid newGrid: TileGrid, tiles newTiles: [UInt8]) {
        lock.lock(); defer { lock.unlock() }
        guard newGrid == grid, newTiles.count == grid.tileCount else { return }
        tiles = newTiles
    }

    /// Reader: a consistent snapshot. The returned array is a COW copy — the
    /// writer's next `publish` assigns a new array and leaves this one intact.
    func latest() -> (grid: TileGrid, tiles: [UInt8]) {
        lock.lock(); defer { lock.unlock() }
        return (grid, tiles)
    }

    /// Resolution change: re-grid and seed every tile to `.progressive`
    /// (always visually correct until the analysis thread catches up).
    func rebuild(to newGrid: TileGrid) {
        lock.lock(); defer { lock.unlock() }
        grid = newGrid
        tiles = [UInt8](repeating: TileCodec.progressive.rawValue,
                        count: max(0, newGrid.tileCount))
    }
}

/// Result of routing one frame: which tiles go to which codec, plus an
/// optional masked copy to feed VideoToolbox. Used on MainActor only.
struct HybridRouting {
    var videoRects: [Rect16]
    var staticRects: [Rect16]
    var grid: TileGrid
    /// Non-nil when masking is enabled and there are video tiles: feed this
    /// to the H.264 encoder instead of the original frame.
    var maskedBuffer: CVPixelBuffer?
    /// Monotonic per-frame token assigned by `route()` in capture order. Used
    /// by `send()` to keep paint ordering capture-correct even when the H.264
    /// encoder runs late and a newer Progressive-only frame already painted
    /// some of this frame's intended video tiles — those tiles get filtered
    /// out of the AVC blit so the newer Progressive content isn't stomped.
    var captureToken: Int64
}

/// Per-frame payload threaded from the encode call back to the send path so
/// the encoded H.264 bytes can be correlated with their tile rects and the
/// original (unmasked) frame used for the Progressive region.
final class HybridFramePayload: @unchecked Sendable {
    let captureToken: Int64
    let videoRects: [Rect16]
    let staticRects: [Rect16]
    let grid: TileGrid
    let pixel: CVPixelBuffer
    init(captureToken: Int64,
         videoRects: [Rect16], staticRects: [Rect16],
         grid: TileGrid, pixel: CVPixelBuffer) {
        self.captureToken = captureToken
        self.videoRects = videoRects
        self.staticRects = staticRects
        self.grid = grid
        self.pixel = pixel
    }
}

/// Bridge-agnostic seam so DisplayPipeline can drive the hybrid path without
/// importing the FreeRDP bridge. HybridCoordinator conforms.
protocol HybridFrameSink: AnyObject, Sendable {
    /// Submit the frame for analysis and read the current routing. Called on
    /// MainActor with `pixel` already locked `.readOnly`. `dirtyRects` are the
    /// frame's changed regions in surface pixel coords (nil if unavailable).
    func route(pixel: CVPixelBuffer, width: Int, height: Int, stride: Int,
               dirtyRects: [CGRect]?) -> HybridRouting
    /// Send one composed frame. `annexB == nil` means a Progressive-only frame
    /// (no video tiles this frame). May be called from any thread.
    func send(annexB: Data?, isIDR: Bool, pts: CMTime, payload: HybridFramePayload)
    /// Convergence: on a non-`.complete` (idle) frame, if the last sent frame
    /// painted an H.264 region, deliver ONE crisp Progressive repaint of that
    /// region from `pixel` (the now-static content) so it doesn't stay stuck on
    /// the last lossy H.264 blit. Does NOT run analysis. Called on MainActor.
    func flushSettle(pixel: CVPixelBuffer, width: Int, height: Int, stride: Int)
    /// Consume a pending IDR request, set when a late H.264 send had every one
    /// of its blit rects filtered out (the AVC NAL was therefore dropped to
    /// avoid stomping newer Progressive paints, which leaves the client decoder
    /// DPB one frame behind ours — the next encoded frame must be IDR to
    /// resync). Read on MainActor by DisplayPipeline before each encode.
    func popPendingKeyframe() -> Bool
}

/// Merge same-codec tiles into rectangles. Greedy per-row run-merge followed
/// by a vertical merge of identical horizontal spans in adjacent rows.
/// `.skip` tiles land in neither list (the surface keeps its prior content).
func coalesce(tiles: [UInt8], grid: TileGrid)
    -> (videoRects: [Rect16], staticRects: [Rect16]) {
    guard grid.cols > 0, grid.rows > 0, tiles.count == grid.tileCount else {
        return ([], [])
    }
    func rects(for code: TileCodec) -> [Rect16] {
        // Step 1: horizontal runs per row → (col0, col1, row) spans.
        struct Run { var c0: Int; var c1: Int }
        var out: [Rect16] = []
        // Pending runs from the previous row we might extend downward,
        // keyed by (c0,c1) span → start row.
        var open: [String: (c0: Int, c1: Int, r0: Int, r1: Int)] = [:]
        func flush(_ entry: (c0: Int, c1: Int, r0: Int, r1: Int)) {
            let tl = grid.rect(col: entry.c0, row: entry.r0)
            let br = grid.rect(col: entry.c1, row: entry.r1)
            out.append(Rect16(left: tl.left, top: tl.top,
                              right: br.right, bottom: br.bottom))
        }
        for row in 0..<grid.rows {
            var rowRuns: [Run] = []
            var col = 0
            while col < grid.cols {
                if tiles[row * grid.cols + col] == code.rawValue {
                    var c1 = col
                    while c1 + 1 < grid.cols,
                          tiles[row * grid.cols + (c1 + 1)] == code.rawValue {
                        c1 += 1
                    }
                    rowRuns.append(Run(c0: col, c1: c1))
                    col = c1 + 1
                } else {
                    col += 1
                }
            }
            // Step 2: extend matching spans from the row above, else flush
            // the ones that didn't continue and open the new ones.
            var nextOpen: [String: (c0: Int, c1: Int, r0: Int, r1: Int)] = [:]
            for run in rowRuns {
                let key = "\(run.c0):\(run.c1)"
                if let prev = open[key] {
                    nextOpen[key] = (prev.c0, prev.c1, prev.r0, row)
                    open[key] = nil
                } else {
                    nextOpen[key] = (run.c0, run.c1, row, row)
                }
            }
            // Anything still in `open` ended at the previous row.
            for (_, entry) in open { flush(entry) }
            open = nextOpen
        }
        for (_, entry) in open { flush(entry) }
        return out
    }
    return (rects(for: .h264), rects(for: .progressive))
}
