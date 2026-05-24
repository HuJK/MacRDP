//
//  Config.swift
//  MacRDP
//
//  Loads /etc/macrdp.json or ~/Library/Application Support/MacRDP/config.json.
//  JSON is used in Phase 0 to avoid third-party deps; switch to TOML later if
//  preferred.
//

import Foundation
import os

struct Config: Codable, Sendable {
    var listen: ListenConfig
    var auth: AuthConfig
    var video: VideoConfig
    var display: DisplayConfig
    var input: InputConfig
    var audioOut: AudioOutConfig
    var audioIn: AudioInConfig
    var clipboard: ClipboardConfig
    var rdpdr: RDPDRConfig
    /// Optional so older config files decode without it — see `effectiveCursor`.
    var cursor: CursorConfig?

    /// Cursor config with defaults filled in.
    var effectiveCursor: CursorConfig { cursor ?? .default }

    struct ListenConfig: Codable, Sendable {
        var host: String
        var port: UInt16
    }

    struct AuthConfig: Codable, Sendable {
        var requireNLA: Bool
        var credentialsFile: String?    // path to credentials.json
        var certificateFile: String?    // PEM, auto-generated if nil
        var privateKeyFile: String?
        var certificateValidityDays: Int
        var rsaKeyBits: Int
    }

    struct VideoConfig: Codable, Sendable {
        var bitrateKbps: Int
        var keyframeIntervalFrames: Int
        var hwAcceleration: String   // "required" | "allow" | "disable"
        var maxFps: Int

        /// Adaptive quality presets keyed by RDP connection-type hint
        /// ("lan", "broadband", "modem", "auto"). If a profile is set
        /// it overrides bitrateKbps / maxFps / preferAVC444 for that
        /// link class.
        var profiles: [String: QualityProfile]?

        /// Honor the client-provided TS_UD_CS_CORE.connectionType to
        /// pick an initial profile.
        var useClientHint: Bool

        /// Honor runtime bandwidth autodetect (MS-RDPBCGR § 2.2.14) to
        /// adapt VT bitrate/fps on the fly.
        var useBandwidthAutodetect: Bool

        /// Prefer AVC444 (better chroma fidelity) when the client
        /// advertises support. Falls back to AVC420 otherwise.
        var preferAVC444: Bool

        /// VT data-rate hard cap: averageBitRate * burstMultiplier over
        /// burstSeconds. Smooths bursts (esp. IDRs) so the network
        /// doesn't queue up multiple frames.
        var dataRateBurstMultiplier: Double
        var dataRateBurstSeconds: Int

        /// VT lookahead. 0 = emit each frame immediately (lowest latency).
        var maxFrameDelayCount: Int

        /// ScreenCaptureKit's internal sample-buffer queue. Larger gives
        /// SCK more headroom during stalls; smaller bounds latency.
        var sckQueueDepth: Int

        /// Bound in-flight GFX frames (sent but not yet RDPGFX_FRAME_ACKNOWLEDGE'd
        /// by the client). New captures are dropped while full and the
        /// next survivor is forced to be an IDR.
        var maxOutstandingFrames: Int

        /// Per-frame AVC420 metablock quality hint shipped to the client.
        /// qp = quantization param (0-51, lower = higher quality);
        /// qualityVal = 0-100 hint. These don't drive our encoder — VT
        /// picks its own QP — but the client uses them for QoE reporting.
        var avc420Qp: Int
        var avc420QualityVal: Int

        /// Which RDPGFX codec to emit per frame.
        ///   "avc420"      → H.264 via VideoToolbox hardware encoder.
        ///                   Best for video, smooth full-frame motion.
        ///   "progressive" → RemoteFX Progressive V2 via FreeRDP's CPU codec.
        ///                   Tile-based wavelet — automatic damage tracking,
        ///                   excellent for sparse desktop changes. Higher CPU.
        ///   "hybrid"      → per-tile mix of the two (default). A background
        ///                   analysis thread classifies each tile; video/motion
        ///                   tiles go to H.264, text/static tiles to Progressive,
        ///                   both composed onto one surface per frame. Tunables
        ///                   live in `hybrid`.
        var codec: String

        /// Hybrid-codec tunables. Optional so older config files (and the
        /// non-hybrid codecs) decode without it — see `effectiveHybrid`.
        var hybrid: HybridConfig?

        /// Hybrid config with defaults filled in. Use this everywhere the
        /// hybrid path needs a value so `codec:"hybrid"` works even when the
        /// config omits the `hybrid` block.
        var effectiveHybrid: HybridConfig { hybrid ?? .default }
    }

    /// Per-tile hybrid-encoding tunables. Every threshold here is a knob,
    /// never a literal baked into the analysis/encode code.
    struct HybridConfig: Codable, Sendable {
        // --- tile grid ---
        /// Square tile edge in pixels. The grid is cols×rows where
        /// cols = ceil(width/tileSize), rows = ceil(height/tileSize).
        var tileSize: Int

        // --- analysis cadence (抽幀) ---
        /// Analyze only every Nth submitted frame (1 = every frame).
        var analysisFrameInterval: Int
        /// Floor between two analyses, milliseconds (rate limit under load).
        var analysisMinIntervalMs: Int
        /// Pixel subsample stride inside a tile (1 = every pixel).
        var spatialSampleStride: Int

        // --- change detection (temporal) ---
        // Classification is driven by the *character of the change*, not static
        // content. `classifiers` is an ordered FALLBACK CHAIN: each frame uses
        // the first classifier whose data requirements are met; if every
        // classifier in the chain needs dirtyRects and they're unavailable, the
        // chain is exhausted and the server exits (telling you to fix the chain).
        //   "region"          — connected-component AREA of changed tiles
        //                        (large region → H.264, small → Progressive).
        //                        Needs dirtyRects.
        //   "coverageHistory" — per-tile: over the last `coverageHistoryFrames`
        //                        analyses, the fraction whose change-coverage
        //                        exceeded `coverageHighThreshold`; ≥
        //                        `coverageVideoFraction` → H.264. Captures
        //                        "video = repeatedly changes a large FRACTION
        //                        of the tile (small magnitude ok); UI = changes
        //                        a small fraction (large magnitude ok)".
        //                        Needs dirtyRects.
        //   "luma"            — same coverage-history rule but coverage comes
        //                        from per-pixel luma deltas. Needs NO dirtyRects
        //                        (good as a last-resort fallback).
        var classifiers: [String]

        /// Per-pixel |Δluma| above which a sampled pixel counts as changed.
        /// Filters compression shimmer / gradient banding.
        var pixelNoiseThreshold: Double
        /// Fraction of a tile's sampled pixels that must be changed for the
        /// tile to count as "active" (i.e. it gets sent at all, vs skipped).
        var tileActiveCoverage: Double

        // -- "region" classifier --
        /// Connected changed-tile blobs with area (in tiles) ≥ this go to
        /// H.264; smaller blobs go to Progressive.
        var largeRegionTiles: Int

        // -- "coverageHistory" classifier --
        /// Window length (analyses) of the per-tile coverage history.
        var coverageHistoryFrames: Int
        /// Per-frame change-coverage above which a tile's frame counts as
        /// "high-change" (fraction 0–1).
        var coverageHighThreshold: Double
        /// Fraction (0–1) of the windowed frames that must be "high-change"
        /// for the tile to be classified video → H.264.
        var coverageVideoFraction: Double

        /// A tile only adopts a *new* codec after the new decision persists
        /// this many consecutive analyses (anti-flap at region edges).
        var codecSwitchHysteresisFrames: Int
        /// When a tile that was H.264 stops changing, send it once via
        /// Progressive (crisp re-render) before going idle — keeps text sharp
        /// after a window drag / video stops.
        var settleRepaint: Bool

        // --- H.264 bit-waste masking ---
        /// Paint non-video tiles a flat colour before VT encode so the
        /// ignored regions compress to ~nothing. Toggleable.
        var maskNonVideoTiles: Bool
        /// Flat colour written into masked tiles, as the 32-bit little-endian
        /// word laid down in a BGRX32 pixel (0xFF000000 = opaque black).
        var maskColorBGRA: UInt32
        /// Keep this many tiles of REAL pixels as a halo around the video
        /// region in the encoder input (they're kept real but NOT blitted —
        /// they stay out of the AVC420 regionRects). This keeps the H.264
        /// decoder's references realistic at the video↔static seam, so a tile
        /// *entering* video doesn't decode a large delta-from-mask and flash
        /// black on the transition frame. 0 = mask right up to the video edge
        /// (max savings, more seam flicker).
        var maskHaloTiles: Int

        // --- AVC420 quant hints for the hybrid video region ---
        /// nil → fall back to video.avc420Qp / video.avc420QualityVal.
        var videoQp: Int?
        var videoQualityVal: Int?

        static var `default`: HybridConfig {
            HybridConfig(
                tileSize: 64,
                analysisFrameInterval: 2,
                analysisMinIntervalMs: 33,
                spatialSampleStride: 4,
                classifiers: ["coverageHistory", "luma"],
                pixelNoiseThreshold: 8.0,
                tileActiveCoverage: 0.02,
                largeRegionTiles: 12,
                coverageHistoryFrames: 5,
                coverageHighThreshold: 0.4,
                coverageVideoFraction: 0.2,
                codecSwitchHysteresisFrames: 3,
                settleRepaint: true,
                maskNonVideoTiles: false,
                maskColorBGRA: 0xFF00_0000,
                maskHaloTiles: 2,
                videoQp: nil,
                videoQualityVal: nil)
        }
    }

    struct QualityProfile: Codable, Sendable {
        var bitrateKbps: Int
        var maxFps: Int
        var preferAVC444: Bool
    }

    struct DisplayConfig: Codable, Sendable {
        var resizeHook: String?      // e.g. "/usr/local/bin/setmode {width} {height} {refresh}"
        var resizeTimeoutSeconds: Double

        /// Legacy single-monitor shorthand. 0 = main. Ignored if
        /// `monitors` is non-empty (use that instead).
        var captureDisplayID: UInt32

        /// Explicit RDP-slot ↔ macOS-display bindings. If empty/nil we
        /// auto-bind from the available displays in deterministic order
        /// (primary first, then by displayID ascending), capped at the
        /// negotiated client monitor count.
        var monitors: [MonitorBinding]?

        /// How to react to a client desktop-resize (DISP) request. One of:
        ///   "none"        — ignore resize events.
        ///   "resize"      — GPU-resample the captured frame to the client
        ///                   size (aspect-preserving) before encoding; skips
        ///                   when the fit is already exact (lowest latency).
        ///   "setOnServer" — change the macOS display to the largest available
        ///                   mode that fits the client pixels, DPI-aware (uses
        ///                   the client's DesktopScaleFactor to pick HiDPI vs
        ///                   1× and the point size). Auto-reverts on exit.
        ///   "cliCommand"  — run `resizeHook` (e.g. a virtual-display driver
        ///                   command), then resample to the result.
        var resizePolicy: String

        /// Per-RDP-screen overrides, keyed by rdp screen id (slot) as a string
        /// (e.g. {"0":"setOnServer","1":"resize"}). Slots without an entry use
        /// `resizePolicy`.
        var resizePolicies: [String: String]?

        /// HiDPI selection for "setOnServer":
        ///   "client" — honor the client's DesktopScaleFactor (default).
        ///   "force"  — always prefer 2× HiDPI modes.
        ///   "off"    — always prefer 1× modes (max real estate).
        var resizeHiDPIPolicy: String

        /// Effective resize policy for an rdp screen id (slot).
        func effectiveResizePolicy(slot: Int) -> String {
            resizePolicies?[String(slot)] ?? resizePolicy
        }
    }

    /// One entry in `DisplayConfig.monitors`. Both fields are required.
    /// `macDisplay` is a `MacDisplaySpec` rendered as a JSON value:
    ///   - integer N        → CGDirectDisplayID N
    ///   - the string "main" → CGMainDisplayID() at session-start time
    ///   - the string "$K"   → the K-th display in the auto-ordered list
    struct MonitorBinding: Codable, Sendable {
        var rdpSlot: Int
        var macDisplay: MacDisplaySpec
    }

    enum MacDisplaySpec: Codable, Sendable, Equatable {
        case main
        case displayID(UInt32)
        case orderedIndex(Int)

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let n = try? c.decode(UInt32.self) {
                self = .displayID(n); return
            }
            if let s = try? c.decode(String.self) {
                if s == "main" { self = .main; return }
                if s.hasPrefix("$"), let k = Int(s.dropFirst()) {
                    self = .orderedIndex(k); return
                }
                throw DecodingError.dataCorruptedError(
                    in: c, debugDescription:
                        "macDisplay string must be \"main\" or \"$<index>\", got \(s)")
            }
            throw DecodingError.dataCorruptedError(
                in: c, debugDescription:
                    "macDisplay must be UInt32, \"main\", or \"$<index>\"")
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .main:                  try c.encode("main")
            case .displayID(let id):     try c.encode(id)
            case .orderedIndex(let i):   try c.encode("$\(i)")
            }
        }
    }

    struct InputConfig: Codable, Sendable {
        /// Pixels of scroll per wheel notch (RDP WHEEL_DELTA = 120 magnitude
        /// units in the wire format). 50 px ≈ a Mac wheel-mouse one-notch feel.
        var wheelPixelsPerNotch: Int
    }

    /// Hardware-cursor (RDP pointer channel) settings.
    struct CursorConfig: Codable, Sendable {
        /// When true, capture with `showsCursor=false` and send the cursor's
        /// position + shape out-of-band via RDP pointer updates so the client
        /// renders it locally (removes mouse-move churn from the frame).
        var hardwareCursor: Bool
        /// Poll interval (ms) for cursor shape-change detection.
        var pollIntervalMs: Int
        /// Allow POINTER_LARGE (up to 384²) for big/Retina cursors; otherwise
        /// large cursors are downscaled to the 96² color-pointer limit.
        var allowLargePointer: Bool
        /// Stream cursor *position* to the client. Off by default: RDP clients
        /// render the cursor at their own (local) mouse position, so streaming
        /// the server position adds a latency-lagged correction that can feel
        /// jittery. Enable only if you need server-initiated cursor moves to
        /// reflect on the client.
        var streamPosition: Bool

        static var `default`: CursorConfig {
            CursorConfig(hardwareCursor: true, pollIntervalMs: 16,
                         allowLargePointer: true, streamPosition: false)
        }
    }

    struct AudioOutConfig: Codable, Sendable {
        var enabled: Bool
        var preferAAC: Bool

        /// Control whether captured system audio also plays on the
        /// physical Mac speakers. Maps to CATapDescription.muteBehavior:
        ///   "never"      → .unmuted        (Mac AND client hear audio)
        ///   "whileTapped" → .mutedWhenTapped (Mac silent for the
        ///                                    duration of an active RDP
        ///                                    session, restored on
        ///                                    disconnect — recommended)
        ///   "always"     → .muted          (Mac silent regardless;
        ///                                    rarely useful)
        var muteLocalOutput: String   // "never" | "whileTapped" | "always"
    }

    struct AudioInConfig: Codable, Sendable {
        var enabled: Bool
        var outputDeviceUID: String?  // e.g. "BlackHole2ch_UID"
    }

    struct ClipboardConfig: Codable, Sendable {
        var text: Bool
        var image: Bool
        var files: Bool
        var maxFileSizeMiB: Int
        /// NSPasteboard polling interval (Cocoa has no change notifications).
        var pollIntervalMs: Int
        /// Controls when the FileGroupDescriptorW is fetched from the
        /// client after a Windows-side file copy event.
        ///
        ///   - "eager" — fetch immediately on `CB_FORMAT_LIST` and claim
        ///     the pasteboard with the real top-level item URLs. Best
        ///     UX (Finder shows "Paste 5 Items" with real names), but
        ///     mstsc must enumerate the whole selection before
        ///     responding, which blocks the cliprdr channel for any
        ///     subsequent Windows-side clipboard activity (including
        ///     copies the user never intended to send to the Mac).
        ///     Painful for big selections (≥10k entries).
        ///   - "lazy" — on `CB_FORMAT_LIST`, claim the pasteboard with
        ///     a single placeholder folder (`MacRDP_<UUID>`). Defer the
        ///     `CB_FORMAT_DATA_REQUEST` until Finder enumerates the
        ///     placeholder (i.e. the user actually pastes). Channel
        ///     stays responsive; cost is that every paste lands as a
        ///     wrapper folder named after the session UUID.
        ///
        /// Default "eager" matches existing behaviour. Set to "lazy"
        /// if you commonly copy huge folders or want Windows-side
        /// Ctrl+C activity to never touch the Mac.
        ///
        /// Optional in JSON so older config files without the field
        /// keep working — nil is treated as "eager".
        var fileFetchMode: String?
        /// Window (seconds) over which the copy-progress "realtime speed"
        /// is averaged. Larger = smoother (small/fast files won't spike
        /// the number); smaller = more responsive. nil → 4s.
        var speedStatsWindowSec: Double?
        /// Whether the clipboard FileProvider domain appears in Finder's
        /// sidebar. The domain is a transient paste-staging area the user
        /// never needs to browse, so it's hidden by default (registered +
        /// functional, just not user-visible). nil → false (hidden).
        var showInFinder: Bool?
    }

    /// Device redirection (MS-RDPEFS / RDPDR). Phase 1 of this feature
    /// only logs incoming drive announces — later phases will publish
    /// each redirected drive as its own FileProvider domain.
    struct RDPDRConfig: Codable, Sendable {
        var enabled: Bool
    }

    static var `default`: Config {
        Config(
            listen: .init(host: "0.0.0.0", port: 3389),
            auth: .init(requireNLA: true, credentialsFile: nil,
                        certificateFile: nil, privateKeyFile: nil,
                        certificateValidityDays: 3650,
                        rsaKeyBits: 2048),
            video: .init(bitrateKbps: 25_000, keyframeIntervalFrames: 120,
                         hwAcceleration: "required", maxFps: 60,
                         profiles: [
                            "lan":       .init(bitrateKbps: 25_000, maxFps: 60, preferAVC444: true),
                            "broadband": .init(bitrateKbps: 10_000, maxFps: 30, preferAVC444: false),
                            "modem":     .init(bitrateKbps: 1_500,  maxFps: 15, preferAVC444: false),
                         ],
                         useClientHint: true,
                         useBandwidthAutodetect: true,
                         preferAVC444: true,
                         dataRateBurstMultiplier: 1.5,
                         dataRateBurstSeconds: 1,
                         maxFrameDelayCount: 0,
                         sckQueueDepth: 5,
                         maxOutstandingFrames: 2,
                         avc420Qp: 22,
                         avc420QualityVal: 100,
                         codec: "hybrid",
                         hybrid: .default),
            display: .init(resizeHook: nil, resizeTimeoutSeconds: 3.0,
                           captureDisplayID: 0, monitors: nil,
                           resizePolicy: "resize", resizePolicies: nil,
                           resizeHiDPIPolicy: "client"),
            input: .init(wheelPixelsPerNotch: 50),
            audioOut: .init(enabled: true, preferAAC: true,
                            muteLocalOutput: "always"),
            audioIn: .init(enabled: true, outputDeviceUID: nil),
            clipboard: .init(text: true, image: true, files: true,
                             maxFileSizeMiB: 4096, pollIntervalMs: 200,
                             fileFetchMode: "lazy", showInFinder: false),
            rdpdr: .init(enabled: true),
            cursor: .default
        )
    }
}

enum ConfigLoader {
    static func defaultSearchPaths() -> [URL] {
        var urls: [URL] = []
        let fm = FileManager.default
        if let appSupport = try? fm.url(for: .applicationSupportDirectory,
                                        in: .userDomainMask,
                                        appropriateFor: nil,
                                        create: false) {
            urls.append(appSupport
                .appendingPathComponent("MacRDP", isDirectory: true)
                .appendingPathComponent("config.json"))
        }
        urls.append(URL(fileURLWithPath: "/etc/macrdp.json"))
        return urls
    }

    static func load(explicitPath: String?) throws -> Config {
        let candidates: [URL]
        if let p = explicitPath {
            candidates = [URL(fileURLWithPath: p)]
        } else {
            candidates = defaultSearchPaths()
        }

        let fm = FileManager.default
        for url in candidates where fm.fileExists(atPath: url.path) {
            Log.config.info("Loading config from \(url.path, privacy: .public)")
            let data = try Data(contentsOf: url)
            do {
                return try JSONDecoder().decode(Config.self, from: data)
            } catch {
                throw MacRDPError.configParseFailure(
                    "\(url.path): \(error.localizedDescription)")
            }
        }

        if let p = explicitPath {
            throw MacRDPError.configNotFound(p)
        }

        Log.config.notice("No config file found; using defaults")
        return .default
    }
}
