//
//  Logging.swift
//  MacRDP
//
//  Per-source structured logging on top of `os.Logger`, with config-driven
//  per-source minimum levels + global message formatting.
//
//  Use site:
//      LogTo.encoder.info("submitted frame \(id)")
//      LogTo.audioOut.debug("PCM frame size=\(n)")
//
//  Each `LogTo.<source>` is a `ScopedLogger`. Calls below its current
//  `minLevel` short-circuit BEFORE the message string is built (the message
//  argument is `@autoclosure`), so a `.debug` call in a hot loop costs ~one
//  atomic load when debug logging is off.
//
//  Config wiring: after `ConfigLoader.load(...)` returns, the bootstrap calls
//  `LogTo.apply(config.log)` which:
//    1. updates the global format (timestamp / source prefix),
//    2. sets every known source's `minLevel` to `config.log.default`,
//    3. applies per-source overrides from `config.log.sources`.
//  Unknown source names and unknown level names log a warning to
//  `LogTo.config` and are skipped (no silent typo).
//
//  Source roster: declared statically below as `make(...)` calls AND mirrored
//  in `DefaultConfig.logSourcesDefault`. Adding a source means touching both.
//

import Foundation
import Darwin
import os

/// Severity. Ordered so `<=` works for "this call's level passes the gate".
enum LogLevel: Int, Sendable, Comparable {
    case debug   = 0
    case info    = 1
    case notice  = 2
    case warning = 3
    case error   = 4
    case fault   = 5

    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Lenient parser; case-insensitive. Accepts the names used in
    /// `config.log.default` / `config.log.sources`.
    static func parse(_ s: String) -> LogLevel? {
        switch s.lowercased() {
        case "debug":            return .debug
        case "info":             return .info
        case "notice", "default":return .notice
        case "warning", "warn":  return .warning
        case "error", "err":     return .error
        case "fault", "critical":return .fault
        default:                 return nil
        }
    }

    var name: String {
        switch self {
        case .debug:   return "debug"
        case .info:    return "info"
        case .notice:  return "notice"
        case .warning: return "warning"
        case .error:   return "error"
        case .fault:   return "fault"
        }
    }
}

/// Mutable threshold cell. Single-process, lock-protected.
final class LogLevelHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var value: LogLevel
    init(_ initial: LogLevel) { self.value = initial }
    var level: LogLevel {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock();        value = newValue;  lock.unlock() }
    }
}

/// Mutable global-format cell. Same shape as LogLevelHolder.
final class LogFormatHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Config.LogConfig.FormatConfig
    init(_ initial: Config.LogConfig.FormatConfig) { self.value = initial }
    var current: Config.LogConfig.FormatConfig {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock();        value = newValue;  lock.unlock() }
    }
}

/// One log source — a category against the shared subsystem, gated by a
/// per-source minimum level. The wrapper preserves `os.Logger`'s privacy
/// model by tagging the final assembled string `.public` (the only sensible
/// default for a self-hosted RDP server — there's no PII we want hidden from
/// sysadmins reading their own log stream).
struct ScopedLogger: Sendable {
    let source: String
    fileprivate let logger: Logger
    fileprivate let holder: LogLevelHolder

    var minLevel: LogLevel {
        get { holder.level }
        nonmutating set { holder.level = newValue }
    }

    func debug(_ msg: @autoclosure () -> String)   { emit(.debug,   msg) }
    func info(_ msg: @autoclosure () -> String)    { emit(.info,    msg) }
    func notice(_ msg: @autoclosure () -> String)  { emit(.notice,  msg) }
    func warning(_ msg: @autoclosure () -> String) { emit(.warning, msg) }
    func error(_ msg: @autoclosure () -> String)   { emit(.error,   msg) }
    func fault(_ msg: @autoclosure () -> String)   { emit(.fault,   msg) }

    private func emit(_ lvl: LogLevel, _ msg: () -> String) {
        guard lvl >= holder.level else { return }
        var s = msg()
        let fmt = LogTo.format
        if fmt.timestamp || fmt.prefix {
            var head = ""
            if fmt.timestamp { head += LogTo.nowHHMMSSms() + " " }
            if fmt.prefix    { head += "[\(source)] " }
            s = head + s
        }
        switch lvl {
        case .debug:   logger.debug(  "\(s, privacy: .public)")
        case .info:    logger.info(   "\(s, privacy: .public)")
        case .notice:  logger.notice( "\(s, privacy: .public)")
        case .warning: logger.warning("\(s, privacy: .public)")
        case .error:   logger.error(  "\(s, privacy: .public)")
        case .fault:   logger.fault(  "\(s, privacy: .public)")
        }
    }
}

/// Project-wide log registry. Sources are statically declared; their levels
/// and the global format are initialised to a build-time default and
/// overridden at boot from `config.log`.
enum LogTo {
    static let subsystem = "com.macrdp.server"

    // Initial level before config is applied. `notice` matches the OS default
    // visibility threshold (notice+ get persisted by Console.app).
    private static let bootDefault = LogLevel.notice

    // MARK: - Format

    /// Format starts off so messages are minimal (`Console.app` shows the
    /// timestamp + category in its own columns). Overridden by `apply`.
    private static let formatHolder = LogFormatHolder(
        Config.LogConfig.FormatConfig(timestamp: false, prefix: false))

    static var format: Config.LogConfig.FormatConfig { formatHolder.current }

    // MARK: - Sources
    //
    // Each `make(...)` here MUST also appear in `DefaultConfig.logSourcesDefault`
    // — that's the operator-facing roster. Adding a source = two edits.

    static let server    = make("server")
    static let listener  = make("listener")
    static let session   = make("session")
    static let display   = make("display")
    static let encoder   = make("encoder")
    static let audioOut  = make("audio.out")
    static let audioIn   = make("audio.in")
    static let clipboard = make("clipboard")
    static let input     = make("input")
    static let resize    = make("resize")
    static let config    = make("config")

    // MARK: - Registry

    /// Every ScopedLogger keyed by its source name. Used by `apply` to route
    /// per-source overrides without hard-coding the list in two places here.
    private static let registry: [String: ScopedLogger] = [
        "server":    server,
        "listener":  listener,
        "session":   session,
        "display":   display,
        "encoder":   encoder,
        "audio.out": audioOut,
        "audio.in":  audioIn,
        "clipboard": clipboard,
        "input":     input,
        "resize":    resize,
        "config":    config,
    ]

    /// Apply user-config log settings. Sets global format, sets every known
    /// source's `minLevel` to `cfg.default`, then applies per-source
    /// overrides. Unknown source names and unknown level names log a warning
    /// (via `LogTo.config`) and are skipped.
    static func apply(_ cfg: Config.LogConfig) {
        formatHolder.current = cfg.format

        let baseline = LogLevel.parse(cfg.default) ?? bootDefault
        if LogLevel.parse(cfg.default) == nil {
            config.warning("log.default \"\(cfg.default)\" is not a valid level; using \"\(baseline.name)\"")
        }
        for (_, s) in registry { s.minLevel = baseline }
        for (sourceName, levelName) in cfg.sources {
            guard let target = registry[sourceName] else {
                config.warning("log.sources has unknown source \"\(sourceName)\"; ignoring")
                continue
            }
            guard let lvl = LogLevel.parse(levelName) else {
                config.warning("log.sources.\(sourceName) has invalid level \"\(levelName)\"; ignoring")
                continue
            }
            target.minLevel = lvl
        }
    }

    private static func make(_ source: String) -> ScopedLogger {
        ScopedLogger(
            source: source,
            logger: Logger(subsystem: subsystem, category: source),
            holder: LogLevelHolder(bootDefault))
    }

    // MARK: - Timestamp helper

    /// Wall-clock `HH:mm:ss.SSS` (local zone, ms precision). No allocation
    /// beyond the returned `String`. Called only when `format.timestamp` is
    /// on AND the message passes the level gate, so it stays off the hot path
    /// for default-config debug calls.
    fileprivate static func nowHHMMSSms() -> String {
        var ts = timespec()
        clock_gettime(CLOCK_REALTIME, &ts)
        var t = tm()
        var sec = ts.tv_sec
        localtime_r(&sec, &t)
        let ms = Int(ts.tv_nsec / 1_000_000)
        return String(format: "%02d:%02d:%02d.%03d",
                      Int(t.tm_hour), Int(t.tm_min), Int(t.tm_sec), ms)
    }
}
