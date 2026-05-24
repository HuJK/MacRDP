//
//  AppDelegate.swift
//  rds
//
//  Bootstrap for MacRDP. Storyboard target's @main entry — the
//  storyboard itself is unused (we are a background / menu-bar app),
//  but Xcode's macOS App template wires the entry point here, so this
//  is where the listener + signal handlers + permissions probe live.
//
//  Subcommand `rds exercise …` keeps the standalone smoke-test path
//  working: parse args, run, then NSApp.terminate.
//
//  Permission gate: at launch, if any required TCC permission isn't
//  granted yet, we show PermissionPromptWindow first. Continue starts
//  the listener; Quit terminates.
//

import Cocoa
import Foundation
@preconcurrency import CoreMedia
@preconcurrency import ScreenCaptureKit
import os

@MainActor
@main
class AppDelegate: NSObject, NSApplicationDelegate {

    private var listener: RDPListener?
    private var signalSources: [DispatchSourceSignal] = []
    private var permissionPrompt: PermissionPromptWindow?
    /// Snapshot of parsed CLI args, kept alive so we can resume bootstrap
    /// after the permission prompt closes.
    private var pendingConfig: Config?
    /// FileProvider domain for Win→Mac clipboard files. Registered once
    /// at app launch (after permissions); `ClipboardBridge` writes into
    /// it whenever the Windows side copies files.
    static let sharedClipboardInbox = FileProviderInbox(
        domainID: AppGroupShared.clipboardDomainID,
        displayName: "MacRDP Clipboard")

    func applicationWillFinishLaunching(_ notification: Notification) {
        // The Storyboard target template auto-instantiates an empty
        // Main.storyboard window. We're a background daemon — hide it
        // before the user sees it. Permanent fix is to remove
        // Main.storyboard from the target (see "GUI fix" in commit msg).
        for window in NSApp.windows {
            window.orderOut(nil)
        }
    }

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Background daemon — no Dock icon by default. The permission
        // prompt temporarily flips this to .regular so the window comes
        // to the front, then flips back.
        NSApp.setActivationPolicy(.accessory)

        let allArgs = CommandLine.arguments

        // Exercise subcommand — standalone smoke test, no RDP client.
        if allArgs.count >= 2 && allArgs[1] == "exercise" {
            let cfg: Config
            do { cfg = try ConfigLoader.load(explicitPath: nil) }
            catch {
                FileHandle.standardError.write(Data("error: \(error)\n".utf8))
                NSApp.terminate(nil); return
            }
            let subargs = Array(allArgs.dropFirst(2))
            Task { @MainActor in
                await ExerciseMode.run(subargs, config: cfg)
                NSApp.terminate(nil)
            }
            return
        }

        // Normal server mode.
        let opts = CLIOptions.parse(allArgs)
        if opts.showHelp {
            print(CLIOptions.usage)
            print("")
            print("Smoke testing (no RDP client needed):")
            print("  rds exercise --help")
            NSApp.terminate(nil); return
        }

        let config: Config
        do {
            var loaded = try ConfigLoader.load(explicitPath: opts.configPath)
            if let h = opts.listenHost { loaded.listen.host = h }
            if let p = opts.listenPort { loaded.listen.port = p }
            config = loaded
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            NSApp.terminate(nil); return
        }

        // Crank FreeRDP's WLog up so we see GFX channel byte-level
        // activity alongside our os.Logger output.
        if getenv("WLOG_LEVEL") == nil {
            setenv("WLOG_LEVEL", "DEBUG", 1)
        }

        Log.server.notice("MacRDP server starting on \(config.listen.host, privacy: .public):\(config.listen.port, privacy: .public)")

        self.pendingConfig = config

        // Gate on TCC permissions. If anything's missing, show the
        // prompt first and defer listener start until the user clicks
        // Continue. Otherwise proceed immediately.
        let missing = PermissionGate.missing()
        if missing.isEmpty {
            beginServing(config: config)
        } else {
            Log.server.notice("Showing permission prompt — \(missing.count, privacy: .public) missing")
            let prompt = PermissionPromptWindow()
            prompt.show(requirements: missing,
                        onContinue: { [weak self] in
                            guard let self, let cfg = self.pendingConfig else { return }
                            self.beginServing(config: cfg)
                        },
                        onQuit: {
                            Log.server.notice("User quit at permission prompt")
                            NSApp.terminate(nil)
                        })
            self.permissionPrompt = prompt
        }
    }

    /// Real bootstrap, run either immediately or after Continue.
    /// Async because we pre-warm SCStream first — that triggers any
    /// macOS screen-share prompt up front, so the user isn't surprised
    /// by a picker dialog the moment an RDP client connects.
    private func beginServing(config: Config) {
        Task { @MainActor in
            await self.preWarmScreenCapture()
            // Register the FileProvider clipboard domain so the
            // extension can serve "MacRDP Clipboard" through Finder.
            // Failure is non-fatal — clipboard text/image still work.
            // Note: the host-side XPC channel is the
            // NSFileProviderService connection opened on first publish;
            // no Mach service listener to start up front.
            // Clipboard is a transient paste-staging domain; hide it from
            // Finder unless the user opts in via config.
            await AppDelegate.sharedClipboardInbox.register(
                hidden: !(config.clipboard.showInFinder ?? false))
            // Wire the copy-progress UI: it polls CopyEventStore for
            // progress snapshots (the store wakes it when work starts).
            CopyProgressTracker.shared.configure(
                domainSubdir: AppDelegate.sharedClipboardInbox.subdir,
                speedWindowSec: config.clipboard.speedStatsWindowSec ?? 4)
            self.finishStartup(config: config)
        }
    }

    /// Briefly start a 2×2 SCStream and immediately stop it. The
    /// picker / "your screen is being recorded" reminder / annual
    /// re-prompt all attach to `startCapture()`. Doing it once at
    /// service start means the actual DisplayPipeline (per peer)
    /// won't trigger any new prompts.
    @MainActor
    private func preWarmScreenCapture() async {
        do {
            let content = try await SCShareableContent.current
            guard let display = content.displays.first else {
                Log.server.notice("SCStream pre-warm: no displays")
                return
            }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let cfg = SCStreamConfiguration()
            cfg.width = 2
            cfg.height = 2
            cfg.queueDepth = 3
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)  // 1 fps
            let stream = SCStream(filter: filter, configuration: cfg, delegate: nil)
            // startCapture requires at least one output; attach a no-op.
            let sink = DummySCStreamOutput()
            try stream.addStreamOutput(sink, type: .screen,
                                       sampleHandlerQueue: .global(qos: .utility))
            try await stream.startCapture()
            try await stream.stopCapture()
            Log.server.info("SCStream pre-warm complete")
        } catch {
            // Don't treat this as fatal — even if pre-warm fails, the
            // real DisplayPipeline will try again on peer connect.
            Log.server.notice("SCStream pre-warm failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func finishStartup(config: Config) {
        // Eagerly materialize the TLS certificate so failures surface
        // at startup rather than only when a peer connects.
        do {
            let (cert, key) = try TLSCertificateGenerator.ensureCertificate(config: config)
            Log.server.info("TLS cert: \(cert, privacy: .public)")
            Log.server.info("TLS key:  \(key, privacy: .public)")
        } catch {
            Log.server.error("TLS cert setup failed: \(String(describing: error), privacy: .public) (will retry on first peer)")
        }

        let listener = RDPListener(config: config)
        self.listener = listener
        do {
            try listener.start()
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            NSApp.terminate(nil); return
        }

        installSignalHandler(SIGINT)
        installSignalHandler(SIGTERM)
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        listener?.stop()
        listener = nil
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    /// No-op SCStreamOutput for the pre-warm dummy stream.
    private final class DummySCStreamOutput: NSObject, SCStreamOutput {
        nonisolated func stream(_ stream: SCStream,
                                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                                of type: SCStreamOutputType) {
            // Intentionally empty — we just want the side effects of
            // startCapture, not the frames.
        }
    }

    private func installSignalHandler(_ sig: Int32) {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: DispatchQueue.main)
        source.setEventHandler { [weak self] in
            Log.server.notice("Received signal \(sig, privacy: .public); shutting down")
            MainActor.assumeIsolated {
                self?.listener?.stop()
                NSApp.terminate(nil)
            }
        }
        source.resume()
        signalSources.append(source)
    }
}
