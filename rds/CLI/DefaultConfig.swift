//
//  DefaultConfig.swift
//  MacRDP
//
//  The single source of truth for default config values.
//
//  Every field in `Config` is non-optional. A user YAML file is overlaid
//  onto this default tree at load time (see ConfigLoader.swift), so missing
//  fields in the user file fall back here — typed, type-checked, in one place.
//
//  When you add a field to `Config`, you MUST add a default for it here.
//  The compiler will tell you (struct initializer is non-optional).
//
//  Defaults are broken into per-section helpers (rather than one giant
//  nested literal) because Swift's type-checker cannot handle the deeply
//  nested expression in reasonable time.
//

import Foundation

enum DefaultConfig {
    static let value: Config = Config(
        listen:    listenDefault,
        auth:      authDefault,
        video:     videoDefault,
        display:   displayDefault,
        input:     inputDefault,
        cursor:    cursorDefault,
        tray:      trayDefault,
        audioOut:  audioOutDefault,
        audioIn:   audioInDefault,
        clipboard: clipboardDefault,
        rdpdr:     rdpdrDefault,
        log:       logDefault)

    // MARK: - listen

    static let listenDefault = Config.ListenConfig(
        host: "0.0.0.0",
        port: 3389)

    // MARK: - auth

    static let authDefault = Config.AuthConfig(
        authUserPolicy: "self",
        username: "",
        passwordPolicy: "local",
        domain: "",
        ntHash: "",
        tls: Config.AuthConfig.TLSConfig(
            certificateFile: "",
            privateKeyFile: "",
            certificateValidityDays: 3650,
            rsaKeyBits: 2048))

    // MARK: - video

    static let videoDefault = Config.VideoConfig(
        bitrateKbps: 25_000,
        keyframeIntervalFrames: 120,
        hwAcceleration: "required",
        maxFps: 60,
        useClientHint: true,
        useBandwidthAutodetect: true,
        dataRate: Config.VideoConfig.DataRateConfig(
            burstMultiplier: 1.5,
            burstSeconds: 1),
        maxFrameDelayCount: 0,
        sckQueueDepth: 5,
        compositorNudgeMs: 33,
        maxOutstandingFrames: 2,
        avc420: Config.VideoConfig.AVC420Hint(
            qp: 22,
            qualityVal: 100),
        codec: "hybrid",
        profiles: videoProfilesDefault,
        tile: tileDefault)

    static let videoProfilesDefault: [String: Config.VideoConfig.QualityProfile] = [
        "lan":       .init(bitrateKbps: 25_000, maxFps: 60),
        "broadband": .init(bitrateKbps: 10_000, maxFps: 30),
        "modem":     .init(bitrateKbps:  1_500, maxFps: 15),
    ]

    // MARK: - tile

    /// Engine analysis cadence. Shared across the chain — the engine ticks
    /// at one rate regardless of which classifier wins. Decoupled from the
    /// Schmitt window: window-based classifiers bucket by wall-clock (see
    /// their `bucketMs` / `bucketCount`), so this knob only controls CPU.
    /// frameInterval=1 = analyze on every .complete submit (SCK already
    /// filters idle frames, so submit rate ≈ source frame rate). Raise
    /// (e.g. 4) when `pixelRate` is the active classifier and per-pixel
    /// diff dominates CPU.
    static let tileAnalysisDefault = Config.TileConfig.AnalysisCadence(
        frameInterval: 1)

    static let tileDefault = Config.TileConfig(
        tileSize: 64,
        classifiers: ["dirtyFreqDR"],
        analysis: tileAnalysisDefault,
        blobDR: Config.TileConfig.BlobDRConfig(
            tileActiveCoverage: 0.02,
            largeRegionTiles: 12),
        dirtyFreqDR: Config.TileConfig.DirtyFreqDRConfig(
            bucketMs:          33,
            bucketCount:       90,
            videoFramesEnter:  30,
            videoFramesExit:    1),
        pixelRate: Config.TileConfig.PixelRateConfig(
            perFrameCoverageThreshold:  0.1,
            bucketMs:           33,   // ≈ 1 frame at 30 fps (pixelRate is the expensive one)
            bucketCount:        30,   // window ≈ 1 s
            videoFramesEnter:   27,   // ≈ 0.9 × 30
            videoFramesExit:    12),  // ≈ 0.4 × 30
        mask: Config.TileConfig.MaskConfig(
            enable: false,
            colorBGRA: 0xFF00_0000,  // opaque black
            haloTiles: 2),
        encoder: Config.TileConfig.EncoderConfig(
            fullRangeVideo: false,
            qp: 22,
            qualityVal: 100))

    // MARK: - display

    static let displayDefault = Config.DisplayConfig(
        resize: Config.DisplayConfig.ResizeConfig(
            policy: "resize",
            perSlot: [:],
            hook: "",
            timeoutSeconds: 3.0,
            hiDPIPolicy: "client"),
        captureDisplayID: 0,
        monitors: [])

    // MARK: - input

    static let inputDefault = Config.InputConfig(
        wheelPixelsPerNotch: 50)

    // MARK: - cursor

    static let cursorDefault = Config.CursorConfig(
        hardwareCursor: true,
        pollIntervalMs: 16,
        allowLargePointer: true,
        streamPosition: false)

    // MARK: - tray

    static let trayDefault = Config.TrayConfig(
        enabled: true)

    // MARK: - audio out

    static let audioOutDefault = Config.AudioOutConfig(
        enabled: true,
        codec: "aac",
        muteLocalOutput: "always",
        opus: Config.AudioOutConfig.OpusConfig(
            frameMs: 10,
            bitrateKbps: 96),
        lag: Config.AudioOutConfig.LagConfig(
            shortWindowMs: 1000,
            refWindowMs: 20_000,
            driftAllowanceMs: 80,
            // Absolute backstop OFF by default. The drift detector above
            // catches sustained growth correctly; an absolute cap on
            // shortFloor mis-classifies legitimately deep client jitter
            // buffers (mstsc PCM ≈ 300-500ms, slow links higher) as
            // "broken", and once shortFloor exceeds the cap every packet
             // is dropped — no sends → no confirms → shortFloor stuck high;
             // only the 1.5 s stale-confirm escape lets audio trickle
             // through. Set to >0 only when you have a specific
             // runaway-skew scenario that drift alone can't see.
            maxMs: 0))

    // MARK: - audio in

    static let audioInDefault = Config.AudioInConfig(
        enabled: true,
        outputDeviceUID: "")

    // MARK: - clipboard

    static let clipboardDefault = Config.ClipboardConfig(
        text: true,
        image: true,
        files: true,
        maxFileSizeMiB: 4096,
        pollIntervalMs: 200,
        fileFetchMode: "lazy",
        speedStatsWindowSec: 4.0,
        showInFinder: false,
        echo: Config.ClipboardConfig.EchoConfig(
            suppressMs: 500,
            cancelReleaseMs: 3000))

    // MARK: - rdpdr

    static let rdpdrDefault = Config.RDPDRConfig(
        enabled: true)

    // MARK: - log

    /// Format defaults — off, so the message field stays minimal. Console.app
    /// shows the timestamp + category in its own columns already; flip these
    /// on when piping the unified log out to a plain-text stream.
    static let logFormatDefault = Config.LogConfig.FormatConfig(
        timestamp: false,
        prefix:    true)

    /// Every known log source listed at the baseline level. Keeping the
    /// roster here (instead of an empty dict + "see Logging.swift") means
    /// `DefaultConfig.swift` doubles as the discovery point: one file lists
    /// every tunable, including which logging sources exist. Rename or add
    /// a source in `Logging.swift` → mirror it here.
    static let logSourcesDefault: [String: String] = [
        "server":    "notice",  // bootstrap, TLS provisioning, signal handlers
        "listener":  "notice",  // accept loop, kicks, new-peer arrival
        "session":   "notice",  // per-peer lifecycle, RDPDR device announces
        "display":   "notice",  // ScreenCaptureKit, capture reconnects
        "encoder":   "notice",  // VT H.264, hybrid classifier setup, codec picks
        "audio.out": "notice",  // system-audio capture, codec, lag stats
        "audio.in":  "notice",  // client mic, loopback device routing
        "clipboard": "notice",  // format lists, file copy events, bridge lifecycle
        "input":     "notice",  // keyboard/mouse injection, sticky modifiers
        "resize":    "notice",  // client DISP requests, mode setter, resize hook
        "config":    "notice",  // config load, display-binding resolution
    ]

    /// WLog defaults. `default: DEBUG` preserves the legacy AppDelegate
    /// behaviour (we wanted GFX-channel byte-level visibility for bring-up);
    /// add per-channel overrides in `filters` to silence noisy subsystems
    /// without dropping the global level. Empty `filters` = no WLOG_FILTER
    /// is set (i.e. all channels at `default`).
    static let freerdpLogDefault = Config.LogConfig.FreeRDPConfig(
        default: "DEBUG",
        filters: [:])

    static let logDefault = Config.LogConfig(
        default: "notice",
        format:  logFormatDefault,
        sources: logSourcesDefault,
        freerdp: freerdpLogDefault)
}
