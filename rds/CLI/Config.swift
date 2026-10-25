//
//  Config.swift
//  MacRDP
//
//  Type definitions for the server config.
//
//  Design rules:
//    * Every field is REQUIRED (non-optional). Missing values in a user
//      config file are filled in by overlaying onto a typed default tree
//      at load time — see DefaultConfig.swift + ConfigLoader.swift.
//      Consumer code never sees a `nil` here and never needs `?? default`
//      or `effectiveXxx` accessors.
//    * Each subsystem lives in its own nested struct, grouped by use.
//      No section reaches into another's fields for a fallback (so e.g.
//      `video.tile.encoder.qp` has its own default, independent of
//      `video.avc420.qp` — the two used to be coupled with `?? avc420Qp`).
//    * Per-tile hybrid classifiers each have their own nested sub-config
//      (`blobDR`, `dirtyFreqDR`, `pixelRate`). Shared knob *names* live
//      under the classifier that owns them — no flattening, no implicit
//      sharing across classifier choices.
//

import Foundation

struct Config: Codable, Sendable {
    var listen: ListenConfig
    var auth: AuthConfig
    var video: VideoConfig
    var display: DisplayConfig
    var input: InputConfig
    var cursor: CursorConfig
    var tray: TrayConfig
    var audioOut: AudioOutConfig
    var audioIn: AudioInConfig
    var clipboard: ClipboardConfig
    var rdpdr: RDPDRConfig
    var log: LogConfig

    // MARK: - listen

    struct ListenConfig: Codable, Sendable {
        var host: String
        var port: UInt16
    }

    // MARK: - auth

    struct AuthConfig: Codable, Sendable {
        /// Which OS identity a login is for (the username clients authenticate
        /// as). Independent of how the password is checked (`passwordPolicy`).
        ///   "self"  — the user MacRDP runs as, i.e. `NSUserName()`.
        ///   "fixed" — the configured `username`.
        var authUserPolicy: String
        /// Username for `authUserPolicy == "fixed"` (ignored for "self").
        /// Empty string when unset.
        var username: String

        /// How the password is verified.
        ///   "none"   — accept anyone (NLA off). DANGEROUS; explicit opt-in.
        ///   "serial" — NLA against the Mac's serial number. Log in with the
        ///              serial as the password.
        ///   "nthash" — NLA against a configured NT-hash (`ntHash`). Generate
        ///              it with `rds nthash` so no plaintext lives in config.
        ///   "local"  — verify the password against the local macOS account
        ///              via OpenDirectory (`opendirectoryd`); caches the
        ///              NT-hash for NLA on subsequent connections.
        var passwordPolicy: String

        /// NLA domain. Empty string → bare username (no domain).
        var domain: String
        /// NT-hash hex (32 chars) for `passwordPolicy == "nthash"`. Produce
        /// with `rds nthash`. Empty when unused.
        var ntHash: String

        /// TLS server-certificate settings.
        var tls: TLSConfig

        struct TLSConfig: Codable, Sendable {
            /// Empty string → auto-generate a self-signed cert at startup
            /// (`TLSCertificateGenerator`).
            var certificateFile: String
            var privateKeyFile: String
            var certificateValidityDays: Int
            var rsaKeyBits: Int
        }
    }

    // MARK: - video

    struct VideoConfig: Codable, Sendable {
        var bitrateKbps: Int
        var keyframeIntervalFrames: Int
        var hwAcceleration: String          // "required" | "allow" | "disable"
        var maxFps: Int

        /// Honor the client-provided TS_UD_CS_CORE.connectionType to pick an
        /// initial profile from `profiles`.
        var useClientHint: Bool
        /// Honor runtime bandwidth autodetect (MS-RDPBCGR § 2.2.14) to adapt
        /// VT bitrate/fps on the fly.
        var useBandwidthAutodetect: Bool

        /// VT data-rate cap: averageBitRate * burstMultiplier over
        /// burstSeconds. Smooths bursts (esp. IDRs).
        var dataRate: DataRateConfig

        /// VT lookahead. 0 = emit each frame immediately (lowest latency).
        var maxFrameDelayCount: Int
        /// ScreenCaptureKit's internal sample-buffer queue.
        var sckQueueDepth: Int
        /// Force a window-server composite this often (ms) so SCK hands over
        /// a lone change instead of holding it until the next one; 0 = off.
        /// See CompositorNudge.
        var compositorNudgeMs: Int
        /// Bound in-flight GFX frames (sent but not yet RDPGFX_FRAME_ACK'd).
        var maxOutstandingFrames: Int

        /// Per-frame AVC420 quant hint shipped to the client for QoE reporting.
        /// Doesn't drive our encoder — VT picks its own QP.
        var avc420: AVC420Hint

        /// Which RDPGFX codec to emit.
        ///   "avc420"      → H.264 via VideoToolbox.
        ///   "progressive" → RemoteFX Progressive V2 (FreeRDP wavelet).
        ///   "hybrid"      → per-tile mix; tunables live in `hybrid`.
        var codec: String

        /// Adaptive quality presets keyed by connection-type hint
        /// ("lan", "broadband", "modem", "auto"). Empty dict disables.
        var profiles: [String: QualityProfile]

        /// Tile-level config for the hybrid codec (`codec: "hybrid"`):
        /// grid partition, classifier chain + per-classifier tunings, tile
        /// masking, and the encoder hint for the tile-video region.
        var tile: TileConfig

        struct DataRateConfig: Codable, Sendable {
            var burstMultiplier: Double
            var burstSeconds: Int
        }

        struct AVC420Hint: Codable, Sendable {
            /// 0-51, lower = higher quality.
            var qp: Int
            /// 0-100.
            var qualityVal: Int
        }

        struct QualityProfile: Codable, Sendable {
            var bitrateKbps: Int
            var maxFps: Int
        }
    }

    // MARK: - hybrid

    /// Per-tile hybrid-codec tunables.
    ///
    /// Three kinds of knobs sit at top level:
    ///   * **Structural invariants** — the grid partition (`tileSize`) and the
    ///     classifier chain selector (`classifiers`). Both are shared by
    ///     construction, not by accident: there's exactly one tile grid in
    ///     play at a time, and the chain IS the choice of which classifier to
    ///     run; neither is a per-classifier tuning.
    ///   * **Engine cadence** (`analysis`) — when AnalysisEngine ticks. The
    ///     engine runs one tile classification per tick regardless of which
    ///     chain entry wins; the cadence describes the engine, not any
    ///     particular classifier. (Earlier this lived in three identical
    ///     copies under each classifier; that was indirection without payoff.)
    ///   * **Encoder-side concerns** (`mask`, `encoder`) — applied to the
    ///     classifier's OUTPUT regardless of which classifier produced it.
    ///
    /// Everything else lives under exactly ONE classifier's sub-block. When
    /// AnalysisEngine runs classifier X for a tick, only the classifier-
    /// specific thresholds (Schmitt band, history window, coverage cutoffs)
    /// come from `hybrid.X.*` — tuning two classifiers can never collide.
    struct TileConfig: Codable, Sendable {
        /// Square tile edge in pixels. The grid is cols×rows where
        /// cols = ceil(width/tileSize), rows = ceil(height/tileSize).
        /// Shared because there's one tile grid the masker and encoder both
        /// have to agree on — not a tuning the classifiers compete over.
        var tileSize: Int

        /// Ordered fallback chain: each frame uses the first classifier whose
        /// data requirements are met (e.g. dirtyRects available). If every
        /// entry needs dirtyRects and they're unavailable, the engine logs a
        /// fault and exits — see AnalysisEngine.
        ///
        /// Recognized entries: "blobDR", "dirtyFreqDR", "pixelRate".
        var classifiers: [String]

        /// When + how often the engine ticks an analysis. Shared across the
        /// chain: the engine runs one classification per tick whichever
        /// classifier the chain picks. Decoupled from the Schmitt window —
        /// window-based classifiers (dirtyFreqDR / pixelRate) bucket
        /// observations by wall-clock (see their `bucketMs` / `bucketCount`),
        /// so this cadence only controls CPU cost, NOT how long the window
        /// covers. Lower `frameInterval` to react faster; raise it to spend
        /// less CPU.
        var analysis: AnalysisCadence

        /// Per-classifier sub-configs. Each holds only its classifier's
        /// thresholds (Schmitt band, history window, coverage cutoffs);
        /// cadence is shared above.
        var blobDR: BlobDRConfig
        var dirtyFreqDR: DirtyFreqDRConfig
        var pixelRate: PixelRateConfig

        /// H.264 bit-waste masking (paint non-video tiles flat so the encoder
        /// spends ~no bits on them).
        var mask: MaskConfig

        /// Encoder integration (color range + AVC420 hint for the hybrid
        /// video region).
        var encoder: EncoderConfig

        /// Reusable per-classifier sub-types. Each classifier's sub-config
        /// embeds its OWN instances of these (no sharing across classifiers).

        struct AnalysisCadence: Codable, Sendable {
            /// Analyze only every Nth submitted frame (1 = every frame).
            /// Single CPU knob — wall-clock alignment is the time-bucket
            /// window's job. SCK pre-filters .idle frames so submits already
            /// track real content change, and within a bucket multiple
            /// observations OR idempotently, so an occasional submit burst
            /// is harmless. Raise (e.g. 4) when pixelRate is the active
            /// classifier and per-pixel diff dominates CPU.
            var frameInterval: Int
        }

        // No post-classification "switching" layer: the only enter/exit
        // mechanism is each classifier's own Schmitt-trigger band
        // (videoFramesEnter / videoFramesExit) running over its time-
        // bucketed window. There is no engine-side hysteresisFrames and no
        // "settle on idle" repaint path; when a tile stops being touched,
        // its buckets scroll out, popcount falls past videoFramesExit, and
        // the Schmitt flips to Progressive on its own.

        /// "blobDR" — dirtyRects → connected-component AREA of touched tiles.
        /// This classifier has no temporal smoothing of its own — it's an
        /// area heuristic per analysis, prone to flap. Suitable when you want
        /// a deterministic per-frame rule and accept the trade-off.
        struct BlobDRClassifierConfig: Codable, Sendable {
            /// Fraction of a tile's sampled pixels that must be "changed" for
            /// the tile to count as "active" (worth sending at all).
            var tileActiveCoverage: Double
            /// Connected changed-tile blobs with area (in tiles) ≥ this go to
            /// H.264; smaller blobs → Progressive.
            var largeRegionTiles: Int
        }
        typealias BlobDRConfig = BlobDRClassifierConfig

        /// "dirtyFreqDR" — per-tile presence in dirtyRects across the recent
        /// wall-clock window (true touched/not boolean per analysis tick,
        /// OR'd into the current time bucket).
        struct DirtyFreqDRClassifierConfig: Codable, Sendable {
            /// Width of one bucket in the time-bucketed history (ms). A
            /// single bucket is the finest "was the tile touched at all
            /// during this slice?" question — pick close to one expected
            /// capture-frame's worth (e.g. 17 ms at 60 fps, 33 ms at 30 fps).
            var bucketMs: Int
            /// Number of buckets in the window. Total wall-clock window =
            /// `bucketMs × bucketCount`. Memory: ~tileCount × bucketCount
            /// bytes (a few hundred KB at 4K/64).
            var bucketCount: Int
            /// Schmitt-trigger band on the absolute count of buckets that
            /// were marked "touched" inside the window (Int, not fraction).
            ///   * enter ≥ flips to H.264
            ///   * exit  < flips back to Progressive (including the case
            ///            where the tile fully stops being touched: buckets
            ///            scroll out, popcount drops past exit)
            /// Require enter > exit, both in [0, bucketCount]. This is the
            /// ONLY enter/exit gate.
            var videoFramesEnter: Int
            var videoFramesExit: Int
        }
        typealias DirtyFreqDRConfig = DirtyFreqDRClassifierConfig

        /// "pixelRate" — full-frame per-pixel RGB comparison, then the same
        /// time-bucketed Schmitt as dirtyFreqDR (but the per-analysis bit
        /// is a real coverage threshold, not a boolean touch).
        struct PixelRateClassifierConfig: Codable, Sendable {
            /// Per-analysis changed-pixel coverage above which the tile's
            /// frame counts as "high-change" (fraction 0–1).
            var perFrameCoverageThreshold: Double
            var bucketMs: Int
            var bucketCount: Int
            var videoFramesEnter: Int
            var videoFramesExit: Int
        }
        typealias PixelRateConfig = PixelRateClassifierConfig

        struct MaskConfig: Codable, Sendable {
            /// Paint non-video tiles a flat colour before VT encode.
            var enable: Bool
            /// Flat colour written into masked tiles, as the 32-bit
            /// little-endian word laid down in a BGRX32 pixel
            /// (4278190080 = 0xFF000000 = opaque black).
            var colorBGRA: UInt32
            /// Keep this many tiles of REAL pixels as a halo around the video
            /// region in the encoder input (kept real but NOT in the AVC420
            /// regionRects). Prevents seam flash when a tile enters video.
            var haloTiles: Int
        }

        struct EncoderConfig: Codable, Sendable {
            /// Convert the hybrid H.264 input to full-range YUV so its
            /// whites/blacks match the Progressive tiles. Off = visibly
            /// darker H.264 tiles (a debug view of the codec map).
            var fullRangeVideo: Bool
            /// AVC420 quant hint shipped for the hybrid video region.
            /// Independent of `video.avc420.qp`.
            var qp: Int
            var qualityVal: Int
        }
    }

    // MARK: - display

    struct DisplayConfig: Codable, Sendable {
        var resize: ResizeConfig
        /// Legacy single-monitor shorthand. 0 = main. Ignored if `monitors`
        /// is non-empty.
        var captureDisplayID: UInt32
        /// Explicit RDP-slot ↔ macOS-display bindings. Empty list →
        /// auto-bind from available displays (primary first, then by
        /// displayID ascending).
        var monitors: [MonitorBinding]

        struct ResizeConfig: Codable, Sendable {
            /// How to react to a client desktop-resize (DISP) request:
            ///   "none"        — ignore.
            ///   "resize"      — GPU-resample the capture (aspect-preserving).
            ///   "setOnServer" — change the macOS display mode, DPI-aware.
            ///   "cliCommand"  — run `hook`, then resample to the result.
            var policy: String
            /// Per-RDP-screen overrides, keyed by slot as a string
            /// (e.g. {"0":"setOnServer","1":"resize"}). Slots without an
            /// entry use `policy`.
            var perSlot: [String: String]
            /// Shell command template for "cliCommand" (e.g.
            /// "/usr/local/bin/setmode {width} {height} {refresh}").
            /// Empty string → no hook configured.
            var hook: String
            var timeoutSeconds: Double
            /// HiDPI selection for "setOnServer":
            ///   "client" — honor the client's DesktopScaleFactor.
            ///   "force"  — always prefer 2× HiDPI modes.
            ///   "off"    — always prefer 1× modes.
            var hiDPIPolicy: String

            /// Effective resize policy for one slot (per-slot override, else
            /// the default `policy`). Sparse lookup with default — not a
            /// "missing config field" fallback.
            func policy(forSlot slot: Int) -> String {
                perSlot[String(slot)] ?? policy
            }
        }
    }

    /// One entry in `DisplayConfig.monitors`. Both fields required.
    /// `macDisplay` is a `MacDisplaySpec` rendered as a YAML/JSON value:
    ///   - integer N         → CGDirectDisplayID N
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
            case .main:                try c.encode("main")
            case .displayID(let id):   try c.encode(id)
            case .orderedIndex(let i): try c.encode("$\(i)")
            }
        }
    }

    // MARK: - input

    struct InputConfig: Codable, Sendable {
        /// Pixels of scroll per wheel notch (RDP WHEEL_DELTA = 120 magnitude
        /// units on the wire). 50 px ≈ a Mac wheel-mouse one-notch feel.
        var wheelPixelsPerNotch: Int
    }

    // MARK: - cursor

    /// Hardware-cursor (RDP pointer channel) settings.
    struct CursorConfig: Codable, Sendable {
        /// True → capture with `showsCursor=false` and send the cursor's
        /// position + shape out-of-band via RDP pointer updates so the client
        /// renders it locally (removes mouse-move churn from the frame).
        var hardwareCursor: Bool
        /// Poll interval (ms) for cursor shape-change detection.
        var pollIntervalMs: Int
        /// Allow POINTER_LARGE (up to 384²) for big/Retina cursors; otherwise
        /// large cursors are downscaled to the 96² color-pointer limit.
        var allowLargePointer: Bool
        /// Stream cursor *position* to the client. Off by default: RDP
        /// clients render the cursor at their own (local) mouse position, so
        /// streaming the server position adds a latency-lagged correction.
        var streamPosition: Bool
    }

    // MARK: - tray

    /// macOS menu-bar status item (the top-right area where VPN/Wi-Fi icons
    /// live), showing connected sessions + restart/quit controls.
    struct TrayConfig: Codable, Sendable {
        var enabled: Bool
    }

    // MARK: - audio out

    struct AudioOutConfig: Codable, Sendable {
        var enabled: Bool

        /// System-audio-out codec advertised to the client:
        ///   "none" — don't send audio at all.
        ///   "pcm"  — uncompressed 16-bit PCM (lossless, highest bandwidth).
        ///   "aac"  — AAC-LC (HW-encoded; broad client support incl. mstsc).
        ///   "opus" — Opus (HW/SW via AudioToolbox; only FreeRDP clients
        ///            decode it; others fall back to PCM in negotiation).
        /// PCM is always advertised as a fallback for "aac"/"opus".
        var codec: String

        /// Control whether captured system audio also plays on the physical
        /// Mac speakers. Maps to CATapDescription.muteBehavior:
        ///   "never"       → .unmuted        (Mac AND client hear audio)
        ///   "whileTapped" → .mutedWhenTapped (Mac silent for the duration
        ///                                     of an active RDP session,
        ///                                     restored on disconnect)
        ///   "always"      → .muted          (Mac silent regardless)
        var muteLocalOutput: String

        var opus: OpusConfig
        var lag: LagConfig

        struct OpusConfig: Codable, Sendable {
            /// Opus frame size in ms (2.5/5/10/20/40/60). Smaller = lower
            /// latency, more overhead.
            var frameMs: Int
            var bitrateKbps: Int
        }

        /// Drop-to-recover (bounds buffered audio latency). All windows in ms.
        ///
        /// Latency is estimated from RDPSND block confirms (sent-vs-played
        /// timestamp gap). To tell *sustained* latency (a stall that won't
        /// drain, or clock skew) from harmless *jitter*, we track the
        /// windowed MINIMUM of that gap. We drop (skip sending) a share of
        /// packets that grows with how far the short-window floor drifts
        /// above the long-window floor — never on jitter, and never into
        /// lasting silence: once confirms stop for 1.5 s, packets go out
        /// again to re-measure. Codec-independent (PCM/AAC/Opus).
        struct LagConfig: Codable, Sendable {
            /// Short window: the "current" latency floor.
            var shortWindowMs: Int
            /// Reference window: best achievable floor to compare against.
            var refWindowMs: Int
            /// Drift (shortFloor − refFloor) tolerated before dropping.
            /// Beyond it the dropped share rises linearly, from none at the
            /// allowance to every packet at 5× it. 0 disables drift
            /// detection.
            var driftAllowanceMs: Int
            /// Hard backstop on the absolute short-window floor (ms).
            /// 0 disables the backstop.
            var maxMs: Int
        }

        /// Derived: true when audio out should actually run (the `codec=none`
        /// flag is conventionally how to disable codec selection without
        /// flipping `enabled`).
        var effectivelyEnabled: Bool { enabled && codec.lowercased() != "none" }
    }

    // MARK: - audio in

    struct AudioInConfig: Codable, Sendable {
        var enabled: Bool
        /// Loopback device UID (e.g. "BlackHole2ch_UID"). Empty string →
        /// play through the default output (proves the wire, not very
        /// useful as a virtual mic).
        var outputDeviceUID: String
    }

    // MARK: - clipboard

    struct ClipboardConfig: Codable, Sendable {
        var text: Bool
        var image: Bool
        var files: Bool
        var maxFileSizeMiB: Int
        /// NSPasteboard polling interval (Cocoa has no change notifications).
        var pollIntervalMs: Int

        /// When to fetch the FileGroupDescriptorW after a Windows-side file
        /// copy event:
        ///   "eager" — fetch immediately on CB_FORMAT_LIST and claim the
        ///             pasteboard with real file URLs (best Finder UX, but
        ///             mstsc must enumerate the whole selection before
        ///             responding — painful for big selections).
        ///   "lazy"  — claim the pasteboard with a single placeholder folder
        ///             (`MacRDP_<UUID>`). Defer the data request until Finder
        ///             enumerates it (the user actually pastes).
        var fileFetchMode: String

        /// Window (seconds) over which the copy-progress "realtime speed"
        /// is averaged.
        var speedStatsWindowSec: Double
        /// Whether the clipboard FileProvider domain appears in Finder's
        /// sidebar. The domain is a transient paste-staging area, hidden
        /// by default.
        var showInFinder: Bool

        var echo: EchoConfig

        struct EchoConfig: Codable, Sendable {
            /// Echo-suppression window. After the Mac pasteboard changes
            /// locally we advertise it to the client; the client then echoes
            /// the same clipboard back as a format list. Client format lists
            /// arriving within this window of a local change are ignored.
            var suppressMs: Int
            /// After the user cancels a Win→Mac paste, keep failing the
            /// client's retries until it has been quiet this long; then a
            /// fresh request is treated as a NEW paste and allowed.
            var cancelReleaseMs: Int
        }
    }

    // MARK: - rdpdr

    /// Device redirection (MS-RDPEFS / RDPDR).
    struct RDPDRConfig: Codable, Sendable {
        var enabled: Bool
    }

    // MARK: - log

    /// Per-source log gating. Each LogTo source has a minimum level;
    /// anything below is short-circuited (no Logger call).
    ///
    /// Recognized levels: "debug" < "info" < "notice" < "warning" < "error"
    ///                    < "fault".
    /// Recognized source names match the `LogTo.<name>` symbols
    /// (server, listener, session, display, encoder, audio.out, audio.in,
    ///  clipboard, input, resize, config). The full list with default levels
    /// lives in `DefaultConfig.logSourcesDefault` so the source roster is
    /// discoverable from one file.
    struct LogConfig: Codable, Sendable {
        /// Fallback level for any source not present in `sources`.
        var `default`: String
        /// Global message-formatting knobs. Apply to every source.
        var format: FormatConfig
        /// Per-source levels. The defaults include every known source name
        /// at the same level as `default` so an operator copying defaults
        /// can see what's tunable.
        var sources: [String: String]
        /// FreeRDP's own WLog tree. Lives inside libfreerdp-c and uses its
        /// own level naming (OFF / FATAL / ERROR / WARN / INFO / DEBUG /
        /// TRACE) and channel namespace (`com.freerdp.…`), separate from
        /// the `sources` above. We drive it through env vars at boot.
        var freerdp: FreeRDPConfig

        /// What to prepend to each emitted message. Both knobs default off;
        /// they're useful when piping the unified log out to a plain-text
        /// stream where Console.app's metadata columns aren't visible.
        struct FormatConfig: Codable, Sendable {
            /// Prepend a wall-clock timestamp (`HH:mm:ss.SSS `) to every
            /// message. The unified-log entry already carries an absolute
            /// timestamp; this is for self-contained text streaming only.
            var timestamp: Bool
            /// Prepend `[<source>] ` to every message. Same rationale as
            /// `timestamp`: redundant in Console.app (it shows the category
            /// in its own column), useful in compact text dumps.
            var prefix: Bool
        }

        /// WLog gates applied via env vars before the FreeRDP bridge spins
        /// up. Env vars set on the process win, so a one-shot
        /// `WLOG_LEVEL=… WLOG_FILTER=… MacRDP` still overrides yaml for a
        /// single run. Level names follow WLog's own convention (OFF /
        /// FATAL / ERROR / WARN / INFO / DEBUG / TRACE) — NOT the
        /// `LogLevel.parse` set used by `sources`.
        struct FreeRDPConfig: Codable, Sendable {
            /// Fallback WLog level for channels not matched by `filters`.
            /// Maps to `WLOG_LEVEL`.
            var `default`: String
            /// Per-channel WLog level. Keys are WLog channel names like
            /// `com.freerdp.channels.audin.server`; glob suffixes are
            /// honored by WLog itself (e.g. `com.freerdp.channels.audin.*`).
            /// Joined into `WLOG_FILTER` as `channel:level,…`.
            var filters: [String: String]
        }
    }
}
