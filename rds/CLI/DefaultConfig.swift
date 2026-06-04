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

    // Per-classifier cadence + switching defaults. The numbers happen to be the
    // same starting point for all three, but they live with their owning
    // classifier so you can tune each one independently. Diverging them later
    // requires no schema change.

    /// blobDR is cheap (region-area on a dirty-rect bitmap) and its decisions
    /// are area-based — they don't flap on noise. Run often, low hysteresis.
    static let blobDRAnalysisDefault   = Config.TileConfig.AnalysisCadence(frameInterval: 2,  minIntervalMs: 33)
    static let blobDRSwitchingDefault  = Config.TileConfig.SwitchingConfig(hysteresisFrames: 3, settleRepaint: true)

    /// dirtyFreqDR is also cheap and reads from a rolling window already — the
    /// window does its own smoothing, so the post-pass hysteresis stays small.
    static let dirtyFreqDRAnalysisDefault  = Config.TileConfig.AnalysisCadence(frameInterval: 2,  minIntervalMs: 33)
    static let dirtyFreqDRSwitchingDefault = Config.TileConfig.SwitchingConfig(hysteresisFrames: 3, settleRepaint: true)

    /// pixelRate is the expensive one (full-frame per-pixel compare). The
    /// engine still runs it at the same baseline cadence; the operator dials
    /// it back here when they pick pixelRate as the active classifier.
    static let pixelRateAnalysisDefault  = Config.TileConfig.AnalysisCadence(frameInterval: 2,  minIntervalMs: 33)
    static let pixelRateSwitchingDefault = Config.TileConfig.SwitchingConfig(hysteresisFrames: 3, settleRepaint: true)

    static let tileDefault = Config.TileConfig(
        tileSize: 64,
        classifiers: ["dirtyFreqDR"],
        blobDR: Config.TileConfig.BlobDRConfig(
            tileActiveCoverage: 0.02,
            largeRegionTiles: 12,
            analysis:  blobDRAnalysisDefault,
            switching: blobDRSwitchingDefault),
        dirtyFreqDR: Config.TileConfig.DirtyFreqDRConfig(
            tileActiveCoverage: 0.02,
            historyFrames: 30,
            videoFractionEnter: 0.9,
            videoFractionExit: 0.4,
            analysis:  dirtyFreqDRAnalysisDefault,
            switching: dirtyFreqDRSwitchingDefault),
        pixelRate: Config.TileConfig.PixelRateConfig(
            tileActiveCoverage: 0.02,
            perFrameCoverageThreshold: 0.1,
            historyFrames: 30,
            videoFractionEnter: 0.9,
            videoFractionExit: 0.4,
            analysis:  pixelRateAnalysisDefault,
            switching: pixelRateSwitchingDefault),
        mask: Config.TileConfig.MaskConfig(
            enable: false,
            colorBGRA: 0xFF00_0000,  // opaque black
            haloTiles: 2),
        encoder: Config.TileConfig.EncoderConfig(
            fullRangeVideo: true,
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
            maxMs: 500))

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
        prefix:    false)

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

    static let logDefault = Config.LogConfig(
        default: "notice",
        format:  logFormatDefault,
        sources: logSourcesDefault)
}
