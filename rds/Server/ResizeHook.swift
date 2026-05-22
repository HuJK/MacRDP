//
//  ResizeHook.swift
//  MacRDP
//
//  Invokes the user-configured resize hook. The contract is designed to be
//  forward-compatible with multi-monitor (Phase 8) without breaking
//  single-monitor scripts.
//
//  Contract (versioned via MonitorLayoutRequest.version):
//
//    $HOOK [argv with optional placeholders]
//
//    Environment (always set):
//      MACRDP_LAYOUT_VERSION      — schema version (currently 1)
//      MACRDP_MONITOR_COUNT       — total number of monitors
//      MACRDP_PRIMARY_RDP_SLOT    — RDP slot of the primary monitor
//      MACRDP_PRIMARY_DISPLAY_ID  — CGDirectDisplayID we bound to that slot
//      MACRDP_PRIMARY_WIDTH       — primary monitor width, px
//      MACRDP_PRIMARY_HEIGHT      — primary monitor height, px
//      MACRDP_PRIMARY_REFRESH     — primary monitor refresh, Hz
//
//    Stdin (always written, hook may ignore it):
//      JSON serialization of MonitorLayoutRequest. Each monitor entry
//      carries `rdpSlot` AND `displayID`, so the hook can route the
//      update to the correct virtual head in your driver.
//
//    Placeholders in argv (substituted by us, NOT a shell, so digits only —
//    no injection surface):
//      {width}, {height}, {refresh}, {display_id}   — primary monitor
//      {monitor_count}, {rdp_slot}
//
//  Single-monitor example:
//      "resize_hook": "/usr/local/bin/setmode {width} {height} {refresh}"
//
//  Multi-monitor example:
//      "resize_hook": "/usr/local/bin/setmode-multi"
//      (script reads JSON on stdin)
//

import Foundation
import os

struct ResizeHook {
    let template: String
    let timeoutSeconds: Double

    enum Failure: Error, CustomStringConvertible {
        case parse(String)
        case launch(Error)
        case nonZeroExit(code: Int32, stderr: String)
        case timeout

        var description: String {
            switch self {
            case .parse(let r): return "parse: \(r)"
            case .launch(let e): return "launch: \(e)"
            case .nonZeroExit(let c, let s): return "exit=\(c), stderr=\(s)"
            case .timeout: return "timed out"
            }
        }
    }

    /// Run the hook with the requested layout. Throws on failure or
    /// non-zero exit.
    func run(_ request: MonitorLayoutRequest) async throws {
        guard let primary = request.primary else {
            throw Failure.parse("layout request has no monitors")
        }

        let tokens = template
            .split(whereSeparator: { $0.isWhitespace })
            .map { String($0) }
        guard let exe = tokens.first else {
            throw Failure.parse("empty hook template")
        }

        let args: [String] = tokens.dropFirst().map { arg in
            arg
                .replacingOccurrences(of: "{width}",         with: String(primary.width))
                .replacingOccurrences(of: "{height}",        with: String(primary.height))
                .replacingOccurrences(of: "{refresh}",       with: String(primary.refreshHz))
                .replacingOccurrences(of: "{display_id}",    with: String(primary.displayID))
                .replacingOccurrences(of: "{rdp_slot}",      with: String(primary.rdpSlot))
                .replacingOccurrences(of: "{monitor_count}", with: String(request.monitors.count))
        }

        Log.resize.info("Invoking resize hook: \(exe, privacy: .public) \(args.joined(separator: " "), privacy: .public) [monitors=\(request.monitors.count, privacy: .public)]")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = args

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin"
        env["MACRDP_LAYOUT_VERSION"]     = String(request.version)
        env["MACRDP_MONITOR_COUNT"]      = String(request.monitors.count)
        env["MACRDP_PRIMARY_RDP_SLOT"]   = String(primary.rdpSlot)
        env["MACRDP_PRIMARY_DISPLAY_ID"] = String(primary.displayID)
        env["MACRDP_PRIMARY_WIDTH"]      = String(primary.width)
        env["MACRDP_PRIMARY_HEIGHT"]     = String(primary.height)
        env["MACRDP_PRIMARY_REFRESH"]    = String(primary.refreshHz)
        process.environment = env

        // Write the JSON layout on stdin so multi-monitor hooks can read it.
        let stdinPipe = Pipe()
        process.standardInput = stdinPipe
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = Pipe()    // discard stdout

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload: Data
        do {
            payload = try encoder.encode(request)
        } catch {
            throw Failure.parse("JSON encode: \(error)")
        }

        let task = Task<Void, Error> {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { proc in
                    if proc.terminationStatus == 0 {
                        cont.resume()
                    } else {
                        let stderrData = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
                        let s = String(data: stderrData, encoding: .utf8) ?? "<binary>"
                        cont.resume(throwing: Failure.nonZeroExit(
                            code: proc.terminationStatus, stderr: s))
                    }
                }
                do {
                    try process.run()
                    // Write payload + EOF to stdin so the hook can read it
                    // even if it does `cat - | jq`.
                    let handle = stdinPipe.fileHandleForWriting
                    try? handle.write(contentsOf: payload)
                    try? handle.close()
                } catch {
                    cont.resume(throwing: Failure.launch(error))
                }
            }
        }

        // Race the process against a timeout.
        let timeoutNs = UInt64(timeoutSeconds * 1_000_000_000)
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await task.value }
                group.addTask {
                    try await Task.sleep(nanoseconds: timeoutNs)
                    throw Failure.timeout
                }
                _ = try await group.next()
                group.cancelAll()
            }
        } catch {
            if process.isRunning { process.terminate() }
            throw error
        }
    }
}
