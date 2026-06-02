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
import FileProvider
import Foundation
@preconcurrency import CoreMedia
@preconcurrency import ScreenCaptureKit
import os

/// Reference box stored in an NSMenuItem's `representedObject` so resource rows
/// can carry which session + resource they act on (ObjectIdentifier can't be a
/// menu-item tag). Read back by `menuActionClicked`.
final class MenuAction {
    enum Kind {
        case disconnect(ObjectIdentifier)
        case openDrive(ObjectIdentifier, String)        // sessionID, driveKey
        case micSpectrum(ObjectIdentifier, Int)         // sessionID, micIndex
        case camera(ObjectIdentifier, String, String)   // sessionID, deviceID, name
    }
    let kind: Kind
    init(_ kind: Kind) { self.kind = kind }
}

@MainActor
@main
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var listener: RDPListener?
    private var signalSources: [DispatchSourceSignal] = []
    private var permissionPrompt: PermissionPromptWindow?
    /// Menu-bar status item + the session snapshot backing its Sessions list.
    private var statusItem: NSStatusItem?
    private var menuSessions: [SessionInfo] = []
    /// Snapshot of parsed CLI args, kept alive so we can resume bootstrap
    /// after the permission prompt closes.
    private var pendingConfig: Config?
    /// FileProvider domain for Win→Mac clipboard files. Registered once
    /// at app launch (after permissions); `ClipboardBridge` writes into
    /// it whenever the Windows side copies files.
    // displayName has no "MacRDP" prefix — Finder renders FileProvider domains
    // as "<app name> - <displayName>" (and `~/Library/CloudStorage` folders as
    // `<app name>-<displayName>`), so any "MacRDP" here doubles up. Just
    // "Clipboard" → CloudStorage `MacRDP-Clipboard`, sidebar `MacRDP - Clipboard`.
    static let sharedClipboardInbox = FileProviderInbox(
        domainID: AppGroupShared.clipboardDomainID,
        displayName: "Clipboard")

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

        // nthash subcommand — turn a plaintext password into the NT-hash for
        // the "nthash" login policy, so no plaintext lives in config.
        // Reads the password without echo from the terminal, or from stdin
        // when piped.
        if allArgs.count >= 2 && allArgs[1] == "nthash" {
            let pw: String
            if isatty(0) != 0, let c = getpass("Password: ") {
                pw = String(cString: c)
            } else {
                pw = readLine(strippingNewline: true) ?? ""
            }
            print(AuthProvisioner.ntHashHex(pw))
            NSApp.terminate(nil); return
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
            // Wipe any FileProvider domains left over from a previous crash /
            // force-quit before (re)registering. Exit-time removal is
            // unreliable (the process dies before the async unregister
            // finishes), so a clean slate at startup is the real guarantee.
            await DriveDomain.removeAllAppDomains()
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
            CopyEventStore.shared.cancelReleaseSec =
                Double(config.clipboard.cancelReleaseMs ?? 3000) / 1000.0
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

        if (pendingConfig?.effectiveTray.enabled ?? true) {
            setupMenuBar()
        }
    }

    // MARK: - Menu bar (NSStatusItem)

    private func setupMenuBar() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "display",
                                     accessibilityDescription: "MacRDP")
        item.button?.image?.isTemplate = true
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        self.statusItem = item
        Log.server.info("Menu-bar status item installed")
    }

    /// Rebuild the menu each time it opens so the session list is current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let header = NSMenuItem(title: "MacRDP", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let sessionsTitle = NSMenuItem(title: "Sessions", action: nil, keyEquivalent: "")
        sessionsTitle.isEnabled = false
        menu.addItem(sessionsTitle)

        menuSessions = listener?.activeSessions() ?? []
        if menuSessions.isEmpty {
            let none = NSMenuItem(title: "No active sessions", action: nil, keyEquivalent: "")
            none.indentationLevel = 1
            none.isEnabled = false
            menu.addItem(none)
        } else {
            for s in menuSessions {
                addSessionItems(s, to: menu)
            }
        }

        menu.addItem(.separator())
        let restart = NSMenuItem(title: "Restart Service", action: #selector(restartService(_:)), keyEquivalent: "")
        restart.target = self
        menu.addItem(restart)
        let off = NSMenuItem(title: "Turn Off Service", action: #selector(quitService(_:)), keyEquivalent: "")
        off.target = self
        menu.addItem(off)
    }

    /// Render one session as an indented group: the client header, then its
    /// forwarded resources (drives / mics / cameras) one level deeper, then a
    /// Disconnect action. `indentationLevel` marks the parent/child grouping.
    private func addSessionItems(_ s: SessionInfo, to menu: NSMenu) {
        // Session row at level 1; give it an icon so it shares the same image
        // column as the resource rows below and the nesting reads cleanly.
        let header = NSMenuItem(title: "\(s.ip)  —  \(s.username)", action: nil, keyEquivalent: "")
        header.indentationLevel = 1
        header.image = NSImage(systemSymbolName: "display", accessibilityDescription: nil)
        header.isEnabled = false
        menu.addItem(header)

        for d in s.drives {
            let mi = resourceItem(title: d.label, symbol: "externaldrive.fill",
                                  action: .openDrive(s.id, d.key))
            menu.addItem(mi)
        }
        for n in 1...max(1, s.micCount) where s.micCount > 0 {
            let mi = resourceItem(title: "Mic \(n)", symbol: "mic.fill",
                                  action: .micSpectrum(s.id, n - 1))
            menu.addItem(mi)
        }
        for (i, c) in s.cameras.enumerated() {
            let label = c.name.isEmpty ? "Camera \(i + 1)" : c.name
            let mi = resourceItem(title: label, symbol: "camera.fill",
                                  action: .camera(s.id, c.id, label))
            mi.toolTip = "Open a live view (decodes the client's camera directly over RDPECAM)"
            menu.addItem(mi)
        }

        let disconnect = NSMenuItem(title: "Disconnect", action: #selector(menuActionClicked(_:)),
                                    keyEquivalent: "")
        disconnect.indentationLevel = 2
        disconnect.target = self
        disconnect.representedObject = MenuAction(.disconnect(s.id))
        menu.addItem(disconnect)
    }

    /// Build an indented resource row with an SF Symbol icon. A nil `action`
    /// makes it a non-clickable (greyed) listing.
    private func resourceItem(title: String, symbol: String, action: MenuAction.Kind?) -> NSMenuItem {
        let mi = NSMenuItem(
            title: title,
            action: action == nil ? nil : #selector(menuActionClicked(_:)),
            keyEquivalent: "")
        mi.indentationLevel = 2
        mi.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        if let action {
            mi.target = self
            mi.representedObject = MenuAction(action)
        } else {
            mi.isEnabled = false
        }
        return mi
    }

    @objc private func menuActionClicked(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? MenuAction else { return }
        switch action.kind {
        case .disconnect(let id):
            listener?.kick(id: id)
        case .openDrive(let id, let key):
            listener?.openDrive(sessionID: id, driveKey: key)
        case .micSpectrum(let id, _):
            listener?.openMicSpectrum(sessionID: id)
        case .camera(let id, let deviceID, let name):
            listener?.openCamera(sessionID: id, deviceID: deviceID, name: name)
        }
    }

    @objc private func restartService(_ sender: NSMenuItem) {
        guard let cfg = pendingConfig else { return }
        Log.server.notice("Restarting service from menu bar")
        listener?.stop()
        listener = nil
        let l = RDPListener(config: cfg)
        self.listener = l
        do { try l.start() }
        catch { Log.server.error("Restart failed: \(String(describing: error), privacy: .public)") }
    }

    @objc private func quitService(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        listener?.stop()
        listener = nil
        // Best-effort: drop all our FileProvider domains on the way out. Bounded
        // wait — the completion fires on a background queue so blocking the main
        // thread briefly here is safe (no MainActor re-entry). Startup cleanup
        // is the real guarantee if this doesn't finish.
        let sem = DispatchSemaphore(value: 0)
        NSFileProviderManager.removeAllDomains { _ in sem.signal() }
        _ = sem.wait(timeout: .now() + 2)
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
