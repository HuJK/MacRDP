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

    /// Menu-bar status item. Optional for older config files.
    var tray: TrayConfig?
    var effectiveTray: TrayConfig { tray ?? .default }

    struct ListenConfig: Codable, Sendable {
        var host: String
        var port: UInt16
    }

    struct AuthConfig: Codable, Sendable {
        /// Which OS identity a login is for (the username clients authenticate
        /// as). Independent of how the password is checked (`passwordPolicy`).
        ///   "self"  — the user MacRDP runs as, i.e. `NSUserName()` (default).
        ///   "fixed" — the configured `username`.
        var authUserPolicy: String
        /// Username for `authUserPolicy == "fixed"` (ignored for "self").
        var username: String?

        /// How the password is verified. Secure by default — passwordless must
        /// be chosen explicitly.
        ///   "none"   — accept anyone (NLA off). DANGEROUS; explicit opt-in.
        ///   "serial" — NLA against the Mac's serial number (default). Log in
        ///              with the serial as the password.
        ///   "nthash" — NLA against a configured NT-hash (`ntHash`). Generate
        ///              it with `rds nthash` so no plaintext lives in config.
        ///   "local"  — verify the password against the local macOS account
        ///              via OpenDirectory (`opendirectoryd`); caches the
        ///              NT-hash for NLA on subsequent connections.
        var passwordPolicy: String

        /// NLA domain. nil → empty (log in with a bare username, no domain).
        var domain: String?
        /// NT-hash hex (32 chars) for `passwordPolicy == "nthash"`. Produce
        /// with `rds nthash`.
        var ntHash: String?

        // --- "local" policy ---
        // First login is verified via OpenDirectory; the resulting NT-hash is
        // cached so later connections use NLA. The cache stays valid exactly
        // while the account's passwordLastSetTime is unchanged (no expiry). If
        // that time can't be read (a different user, needs root) the hash isn't
        // cached and every connection re-verifies via OpenDirectory.

        // --- TLS server certificate (auto-generated if files are nil) ---
        var certificateFile: String?
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

        // --- change detection (temporal) ---
        // Classification is driven by the *character of the change*, not static
        // content. `classifiers` is an ordered FALLBACK CHAIN: each frame uses
        // the first classifier whose data requirements are met; if every
        // classifier in the chain needs dirtyRects and they're unavailable, the
        // chain is exhausted and the server exits (telling you to fix the chain).
        // Naming: "DR" suffix = signal from dirtyRects (changed *rectangles*,
        // region-level, no per-pixel magnitude); no suffix = from a true
        // per-pixel comparison. "Blob" = connected-component area rule.
        //   "blobDR"      — connected-component AREA of touched tiles
        //                   (large blob → H.264, small → Progressive).
        //                   Needs dirtyRects.
        //   "dirtyFreqDR" — per-tile: over the last `coverageHistoryFrames`
        //                   analyses, the FREQUENCY the tile was touched by any
        //                   dirty rect (boolean per frame). Through the
        //                   videoFractionEnter/Exit band → H.264. Captures
        //                   "video = touched nearly every frame; UI = touched
        //                   only occasionally". Needs dirtyRects.
        //   "pixelRate"   — SAME windowed-fraction + Schmitt band, but the
        //                   per-frame bit is "real changed-pixel coverage >
        //                   coverageHighThreshold" from a full-frame vectorized
        //                   RGB comparison. Needs NO dirtyRects (last-resort
        //                   fallback).
        var classifiers: [String]

        /// Fraction of a tile's sampled pixels that must be changed for the
        /// tile to count as "active" (i.e. it gets sent at all, vs skipped).
        var tileActiveCoverage: Double

        // -- "blobDR" classifier --
        /// Connected changed-tile blobs with area (in tiles) ≥ this go to
        /// H.264; smaller blobs go to Progressive.
        var largeRegionTiles: Int

        // -- "dirtyFreqDR" / "pixelRate" classifiers (shared rate rule) --
        /// Window length (analyses) of the per-tile bit history.
        var coverageHistoryFrames: Int
        /// pixelRate ONLY: per-frame changed-pixel coverage above which the
        /// tile's frame counts as "high-change" (fraction 0–1). Unused by
        /// dirtyFreqDR, whose per-frame bit is a plain touched/not boolean.
        var coverageHighThreshold: Double
        /// Schmitt-trigger band on the windowed set-bit fraction (anti-flicker).
        /// A tile flips to video → H.264 once the fraction reaches
        /// `videoFractionEnter`, and back to Progressive only once it drops
        /// below `videoFractionExit`; in between it holds its last decision.
        /// Require enter > exit.
        var videoFractionEnter: Double
        var videoFractionExit: Double

        /// A tile only adopts a *new* codec after the new decision persists
        /// this many consecutive analyses (anti-flap at region edges).
        var codecSwitchHysteresisFrames: Int
        /// When a tile that was H.264 stops changing, send it once via
        /// Progressive (crisp re-render) before going idle — keeps text sharp
        /// after a window drag / video stops.
        var settleRepaint: Bool

        /// Convert the hybrid H.264 input to full-range YUV so its whites/blacks
        /// match the Progressive tiles (see NV12Converter). Turn OFF to feed
        /// BGRA straight to VideoToolbox (limited range): H.264 tiles then
        /// render visibly darker — a handy DEBUG view of which tiles use which
        /// codec, since brightness reveals the codec map at a glance.
        var fullRangeVideo: Bool

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
                classifiers: ["dirtyFreqDR"],
                tileActiveCoverage: 0.02,
                largeRegionTiles: 12,
                coverageHistoryFrames: 30,
                coverageHighThreshold: 0.1,
                videoFractionEnter: 0.9,
                videoFractionExit: 0.4,
                codecSwitchHysteresisFrames: 3,
                settleRepaint: true,
                fullRangeVideo: true,
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
    /// macOS menu-bar status item (the top-right area where VPN/Wi-Fi icons
    /// live), showing connected sessions + restart/quit controls.
    struct TrayConfig: Codable, Sendable {
        var enabled: Bool
        static var `default`: TrayConfig { TrayConfig(enabled: true) }
    }

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

        /// System-audio-out codec advertised to the client:
        ///   "none" — don't send audio at all.
        ///   "pcm"  — uncompressed 16-bit PCM (lossless, highest bandwidth,
        ///            largest client jitter buffer).
        ///   "aac"  — AAC-LC (HW-encoded; broad client support incl. mstsc).
        ///   "opus" — Opus (HW/SW-encoded via AudioToolbox). Only FreeRDP
        ///            clients decode it; others fall back to PCM in negotiation.
        /// PCM is always advertised as a fallback for "aac"/"opus".
        var codec: String

        /// True when audio out should run at all.
        var effectivelyEnabled: Bool { enabled && codec.lowercased() != "none" }

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

        /// Opus frame size in ms (2.5/5/10/20/40/60). Smaller = lower latency,
        /// more overhead. 10 is a good low-latency default.
        var opusFrameMs: Int
        /// Opus target bitrate, kbps.
        var opusBitrateKbps: Int

        // --- drop-to-recover (bounds buffered audio latency) ---
        // Latency is estimated from RDPSND block confirms (sent-vs-played
        // timestamp gap). To tell *sustained* latency (a stall that won't
        // drain, or clock skew) from harmless *jitter*, we track the windowed
        // MINIMUM of that gap: jitter raises the max but not the floor, while
        // accumulation raises the floor itself. We drop (skip sending) when the
        // short-window floor drifts above the long-window floor — never on
        // jitter. Codec-independent (PCM/AAC/Opus). All windows in ms.
        /// Short window: the "current" latency floor.
        var lagShortWindowMs: Int
        /// Reference window: the best achievable floor to compare against.
        var lagRefWindowMs: Int
        /// Drop while (shortFloor − refFloor) exceeds this. 0 disables drift
        /// detection.
        var lagDriftAllowanceMs: Int
        /// Hard backstop on the absolute short-window floor (ms). Catches very
        /// slow clock skew that rises slower than the reference window forgets
        /// (so drift stays small). 0 disables the backstop.
        var maxLagMs: Int
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
        /// Echo-suppression window (milliseconds). After the Mac pasteboard
        /// changes locally we advertise it to the client; the client then
        /// echoes that same clipboard back as a format list, which would
        /// clobber the user's own copy (Finder loses "Paste"). Client format
        /// lists arriving within this window of a local change are ignored as
        /// echoes. nil → 500.
        var echoSuppressMs: Int?
        /// After the user cancels a Win→Mac paste, keep failing the client's
        /// retries until it has been quiet this long; then a fresh request is
        /// treated as a NEW paste and allowed (so the clipboard stays
        /// re-pasteable). nil → 3000.
        var cancelReleaseMs: Int?
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
            auth: .init(authUserPolicy: "self", username: nil,
                        passwordPolicy: "none", domain: nil,
                        ntHash: nil,
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
            audioOut: .init(enabled: true, codec: "aac",
                            muteLocalOutput: "always",
                            opusFrameMs: 10, opusBitrateKbps: 96,
                            lagShortWindowMs: 1000, lagRefWindowMs: 20000,
                            lagDriftAllowanceMs: 80, maxLagMs: 500),
            audioIn: .init(enabled: true, outputDeviceUID: nil),
            clipboard: .init(text: true, image: true, files: true,
                             maxFileSizeMiB: 4096, pollIntervalMs: 200,
                             fileFetchMode: "lazy", showInFinder: false),
            rdpdr: .init(enabled: true),
            cursor: .default,
            tray: .default
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
