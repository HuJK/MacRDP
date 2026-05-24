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
        ///   "avc420"      → H.264 via VideoToolbox hardware encoder (default).
        ///                   Best for video, smooth full-frame motion.
        ///   "progressive" → RemoteFX Progressive V2 via FreeRDP's CPU codec.
        ///                   Tile-based wavelet — automatic damage tracking,
        ///                   excellent for sparse desktop changes. Higher CPU.
        var codec: String
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
                         codec: "progressive"),
            display: .init(resizeHook: nil, resizeTimeoutSeconds: 3.0,
                           captureDisplayID: 0, monitors: nil),
            input: .init(wheelPixelsPerNotch: 50),
            audioOut: .init(enabled: true, preferAAC: true,
                            muteLocalOutput: "always"),
            audioIn: .init(enabled: true, outputDeviceUID: nil),
            clipboard: .init(text: true, image: true, files: true,
                             maxFileSizeMiB: 4096, pollIntervalMs: 200,
                             fileFetchMode: "lazy", showInFinder: false),
            rdpdr: .init(enabled: true)
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
