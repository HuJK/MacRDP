//
//  RDPSession.swift
//  MacRDP
//
//  One session = one accepted fd + one BridgePeer running its own
//  FreeRDP event loop on a worker thread. Per-peer subsystems
//  (DisplayPipeline, AudioOut, AudioIn, ClipboardBridge, InputInjector,
//  DisplayControl) are spun up after the peer reaches Activate.
//

import Foundation
import Darwin
@preconcurrency import CoreMedia
import os

@MainActor
final class RDPSession {
    private let fd: Int32
    private let config: Config

    #if MACRDP_BRIDGE_AVAILABLE
    private var bridge: BridgePeer?
    #endif
    private var workerThread: Thread?

    // Per-session subsystems (populated when peer activates).
    private var displayPipeline: DisplayPipeline?
    #if MACRDP_BRIDGE_AVAILABLE
    /// Hybrid per-tile codec coordinator (owns the tile map + analysis
    /// engine). Held for the session lifetime; nil for non-hybrid codecs.
    private var hybridCoordinator: HybridCoordinator?
    /// Hardware-cursor pipeline (RDP pointer channel). nil when disabled.
    private var cursorPipeline: CursorPipeline?
    #endif
    private var audioOut: AudioOutPipeline?
    private var audioIn: AudioInPipeline?
    private var clipboard: ClipboardBridge?
    /// InputInjector is thread-safe (@unchecked Sendable, CGEvent post
    /// works from any thread). We hold it via NSLocked storage so the
    /// bridge's input callbacks can dispatch directly without a
    /// MainActor hop — that saves ~1-5ms per mouse / keyboard event.
    private let inputBox = ThreadSafeBox<InputInjector>()
    private var displayControl: DisplayControl?
    /// "setOnServer" resize policy — changes the macOS display mode.
    private var displayModeController: DisplayModeController?
    private var displayMapping = DisplayMapping()
    /// Audio routing path. Holds the bridge plus an optional AAC
    /// encoder (engaged when mstsc selects WAVE_FORMAT_AAC_MS at
    /// activation). DisplayPipeline's audio callback funnels every
    /// PCM chunk through this; the encoder swap is hot — no need to
    /// rebuild the pipeline.
    private var audioPath: AudioPath?

    /// `@unchecked Sendable` because the SCStream audio queue calls
    /// `ingest` from a non-MainActor thread while MainActor swaps the
    /// encoder. NSLock around the swap is enough.
    private final class AudioPath: @unchecked Sendable {
        #if MACRDP_BRIDGE_AVAILABLE
        let bridge: BridgePeer
        #endif
        private let lock = NSLock()
        private var encoder: AACEncoder?

        #if MACRDP_BRIDGE_AVAILABLE
        init(bridge: BridgePeer) { self.bridge = bridge }
        #else
        init() {}
        #endif

        func setEncoder(_ enc: AACEncoder?) {
            lock.lock(); encoder = enc; lock.unlock()
        }

        func ingest(_ pcm: Data) {
            lock.lock()
            let enc = encoder
            lock.unlock()
            #if MACRDP_BRIDGE_AVAILABLE
            if let enc {
                let packets = enc.encode(pcm: pcm)
                for p in packets {
                    bridge.sendAudioAAC(p.data, pcmSampleCount: p.pcmSampleCount)
                }
            } else {
                bridge.sendAudioPCM(pcm)
            }
            #endif
        }
    }

    var onTerminated: (() -> Void)?

    init(fd: Int32, config: Config) {
        self.fd = fd
        self.config = config
    }

    func start() {
        #if MACRDP_BRIDGE_AVAILABLE
        do {
            try startBridge()
        } catch {
            Log.session.error("Bridge start failed: \(String(describing: error), privacy: .public)")
            shutdown()
        }
        #else
        // Bridge not yet available (bridging header / xcconfig).
        Log.session.notice("Bridge unavailable — closing fd=\(self.fd, privacy: .public)")
        close(fd)
        onTerminated?()
        #endif
    }

    func shutdown() {
        // Release any modifiers we believe the peer was still holding;
        // without this a dropped Cmd-up at disconnect time leaves
        // macOS thinking Cmd is held, and the next typed letter on the
        // *console* gets interpreted as a Cmd-shortcut.
        inputBox.value?.releaseAllModifiers()
        displayPipeline?.stop()
        // Restore any display whose mode we changed for "setOnServer".
        displayModeController?.restoreAll()
        displayModeController = nil
        #if MACRDP_BRIDGE_AVAILABLE
        cursorPipeline?.stop()
        cursorPipeline = nil
        hybridCoordinator = nil
        #endif
        audioOut?.stop()
        audioIn?.stop()
        clipboard?.stop()
        #if MACRDP_BRIDGE_AVAILABLE
        if let bridge { DriveStore.shared.removeAllDrives(adapter: bridge) }
        bridge?.requestStop()
        bridge = nil
        #endif
        if fd >= 0 {
            // BridgePeer's freerdp_peer owns the fd post-create, so we
            // only close here if we never reached that point.
        }
        onTerminated?()
    }

    #if MACRDP_BRIDGE_AVAILABLE
    private func startBridge() throws {
        let (certPath, keyPath) = try TLSCertificateGenerator
            .ensureCertificate(config: config)

        var sinks = BridgePeer.Sinks()
        sinks.onActivated = { [weak self] w, h, bpp, connType, audioMode in
            Task { @MainActor [weak self] in
                self?.onActivated(width: w, height: h,
                                  bpp: bpp, connectionType: connType,
                                  audioMode: audioMode)
            }
        }
        sinks.onClosed = { [weak self] reason in
            Task { @MainActor [weak self] in
                self?.onClosed(reason: reason)
            }
        }
        // Input goes through a thread-safe box (no MainActor hop) so
        // mouse / keyboard events reach CGEvent without a queue delay.
        let inputBox = self.inputBox
        sinks.onMouse = { flags, x, y in
            inputBox.value?.mouseEvent(flags: flags, x: x, y: y)
        }
        sinks.onKeyboard = { flags, sc in
            inputBox.value?.keyboardEvent(flags: flags, scancode: sc)
        }
        sinks.onUnicode = { flags, code in
            inputBox.value?.unicodeKeyboardEvent(flags: flags, code: code)
        }
        sinks.onSuppressOutput = { [weak self] allow in
            Task { @MainActor [weak self] in
                self?.onSuppressOutput(allow: allow)
            }
        }
        sinks.onAudioInFrame = { [weak self] pcm, sr, ch in
            Task { @MainActor [weak self] in
                self?.audioIn?.feedPCM(pcm)
            }
        }
        sinks.onDispLayout = { [weak self] monitors in
            Task { @MainActor [weak self] in
                self?.onDispLayout(monitors: monitors)
            }
        }
        // CLIPRDR: ready/format-list hop to MainActor to touch NSPasteboard.
        // data-request runs serveFormatDataRequest on MainActor (read pb).
        // data-response MUST stay nonisolated — it just signals a
        // semaphore that the paste thread is waiting on; a MainActor hop
        // would deadlock when the paste is on the main thread.
        sinks.onClipReady = { [weak self] in
            Task { @MainActor [weak self] in
                self?.clipboard?.markReady()
            }
        }
        sinks.onClipFormatList = { [weak self] formats in
            self?.clipboard?.handleClientFormatList(formats)
        }
        sinks.onClipDataRequest = { [weak self] fid in
            self?.clipboard?.handleClientFormatDataRequest(formatID: fid)
        }
        sinks.onClipDataResponse = { [weak self] fid, data in
            self?.clipboard?.handleClientFormatDataResponse(formatID: fid, data: data)
        }
        // RDPSND format negotiation result. Engages the AAC encoder if
        // mstsc picked WAVE_FORMAT_AAC_MS; otherwise keeps PCM path.
        sinks.onAudioFormatSelected = { [weak self] fmt in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch fmt {
                case .aac:
                    do {
                        let enc = try AACEncoder()
                        self.audioPath?.setEncoder(enc)
                        Log.audioOut.notice("Audio: AAC-LC selected (HW-accelerated encoder)")
                    } catch {
                        Log.audioOut.error("AAC encoder init failed, staying on PCM: \(String(describing: error), privacy: .public)")
                        self.audioPath?.setEncoder(nil)
                    }
                case .pcm:
                    self.audioPath?.setEncoder(nil)
                    Log.audioOut.notice("Audio: PCM selected (mstsc didn't pick AAC)")
                }
            }
        }
        sinks.onClipFormatListResponse = { [weak self] success in
            // Hop to MainActor to read the bridge's clipboard state.
            Task { @MainActor [weak self] in
                self?.clipboard?.handleFormatListResponse(success: success)
            }
        }
        // File-contents sinks — both stay nonisolated. The request side
        // reads files synchronously off the bridge thread (FileHandle
        // I/O is fine to do there); the response side just signals a
        // semaphore the materialize loop is waiting on.
        sinks.onClipFileContentsRequest = { [weak self] sid, idx, wantSize, off, len in
            self?.clipboard?.handleClientFileContentsRequest(
                streamID: sid, listIndex: idx,
                wantSize: wantSize, offset: off, length: len)
        }
        sinks.onClipFileContentsResponse = { [weak self] sid, data in
            self?.clipboard?.handleClientFileContentsResponse(streamID: sid, data: data)
        }
        // RDPDR drive redirection: mount each announced filesystem device
        // as its own FileProvider domain; route browse/read IRPs through
        // DriveStore. Completions are token-correlated, so they just need
        // the shared store (no session reference).
        sinks.onRdpdrDeviceAdded = { [weak self] id, type, dos in
            let kind: String
            switch type {
            case 0x01: kind = "SERIAL"
            case 0x02: kind = "PARALLEL"
            case 0x04: kind = "PRINT"
            case 0x08: kind = "FILESYSTEM"
            case 0x20: kind = "SMARTCARD"
            default:   kind = String(format: "0x%X", type)
            }
            Log.session.notice("RDPDR device announced: id=\(id, privacy: .public) type=\(kind, privacy: .public) name='\(dos, privacy: .public)'")
            // OnDriveCreate only fires for filesystem devices, but guard anyway.
            guard type == 0x08, let bridge = self?.bridge else { return }
            DriveStore.shared.addDrive(adapter: bridge, deviceID: id, dosName: dos)
        }
        sinks.onRdpdrDeviceRemoved = { [weak self] id in
            Log.session.notice("RDPDR device removed: id=\(id, privacy: .public)")
            guard let bridge = self?.bridge else { return }
            DriveStore.shared.removeDrive(adapter: bridge, deviceID: id)
        }
        sinks.onRdpdrDirEntry = { token, isEntry, ioStatus, name, attrs, size, mtime in
            DriveStore.shared.onDirEntry(token: token, isEntry: isEntry, ioStatus: ioStatus,
                                         name: name, attributes: attrs, size: size, mtimeMs: mtime)
        }
        sinks.onRdpdrOpenComplete = { token, st, dev, fid in
            DriveStore.shared.onOpenComplete(token: token, ioStatus: st, deviceID: dev, fileID: fid)
        }
        sinks.onRdpdrReadComplete = { token, st, data in
            DriveStore.shared.onReadComplete(token: token, ioStatus: st, data: data)
        }
        sinks.onRdpdrWriteComplete = { token, st, bw in
            DriveStore.shared.onWriteComplete(token: token, ioStatus: st, bytesWritten: bw)
        }
        sinks.onRdpdrCloseComplete = { token, st in
            DriveStore.shared.onCloseComplete(token: token, ioStatus: st)
        }
        sinks.onRdpdrSimpleComplete = { token, st in
            DriveStore.shared.onSimpleComplete(token: token, ioStatus: st)
        }

        let cfgWithPaths = withTLSPaths(certPath: certPath, keyPath: keyPath)
        let peer = try BridgePeer(fd: fd, config: cfgWithPaths, sinks: sinks)
        self.bridge = peer

        let thread = Thread {
            let rc = peer.runLoop()
            Log.session.info("Bridge run loop returned: \(rc, privacy: .public)")
        }
        thread.name = "com.macrdp.session.peer"
        thread.start()
        self.workerThread = thread

        Log.session.info("Session started fd=\(self.fd, privacy: .public) cert=\(certPath, privacy: .public)")
    }

    private func withTLSPaths(certPath: String, keyPath: String) -> Config {
        var c = config
        c.auth.certificateFile = certPath
        c.auth.privateKeyFile = keyPath
        return c
    }
    #endif

    // MARK: - Lifecycle hooks (MainActor)

    private func onActivated(width: Int, height: Int,
                             bpp: Int, connectionType: Int,
                             audioMode: BridgePeer.AudioMode) {
        Log.session.notice("Peer activated: \(width, privacy: .public)x\(height, privacy: .public)@\(bpp, privacy: .public)bpp connType=\(connectionType, privacy: .public) audio=\(String(describing: audioMode), privacy: .public)")

        // Seed the per-session display mapping. Phase 1 binds slot 0 to
        // the primary CGDirectDisplayID; Phase 8 multi-monitor binds N.
        let primary = CGMainDisplayID()
        displayMapping.bind(rdpSlot: 0, displayID: primary)

        // InputInjector is built lazily once DisplayPipeline resolves
        // the actual capture dimensions (which may differ from the
        // client's request due to aspect-ratio preservation). For
        // safety, seed a best-effort version using the client's request
        // so input works in the brief window before resolution.
        let initialBounds = CGDisplayBounds(primary)
        self.inputBox.value = InputInjector(
            surfaceWidth: width,
            surfaceHeight: height,
            outputDisplayBounds: initialBounds,
            wheelPixelsPerNotch: config.input.wheelPixelsPerNotch)

        #if MACRDP_BRIDGE_AVAILABLE
        // Phase 1: spin up the capture + encode pipeline. SCK is told to
        // resample to (width, height) so the encoded H.264 matches the
        // surface dimensions we advertise to the client.
        //
        // Capture by value — the encoded-frame callback fires on the
        // encoder's queue, NOT MainActor. Calling MainActor.assumeIsolated
        // there would crash with SIGTRAP.
        guard let bridge = self.bridge else { return }
        let frameCounter = FrameCounter()
        let maxOutstanding = Int32(config.video.maxOutstandingFrames)

        // Shared callback that fires once SCK + aspect-fit resolves the
        // real capture dimensions. Updates the bridge so RESETGRAPHICS
        // carries the correct size, and re-creates InputInjector with
        // the matching coordinate space so mouse mapping doesn't drift.
        let inputBoxRef = self.inputBox
        let outBounds = CGDisplayBounds(primary)
        let wheelPx = config.input.wheelPixelsPerNotch

        // Hybrid coordinator (per-tile codec). Created up front so the
        // dimension-resolved callback can rebuild its tile grid. Seeded with
        // the activated size; the real capture size arrives via onResolved.
        let hybridCoord: HybridCoordinator?
        if config.video.codec.lowercased() == "hybrid" {
            let tileSize = config.video.effectiveHybrid.tileSize
            let seed = TileGrid(width: width, height: height, tileSize: tileSize)
            let coord = HybridCoordinator(config: config, bridge: bridge, initialGrid: seed)
            self.hybridCoordinator = coord
            hybridCoord = coord
        } else {
            hybridCoord = nil
        }

        // Hardware cursor: capture without the pointer baked in and stream it
        // over the RDP pointer channel instead.
        let cursorPipe: CursorPipeline?
        if config.effectiveCursor.hardwareCursor {
            let cp = CursorPipeline(bridge: bridge, config: config.effectiveCursor)
            self.cursorPipeline = cp
            cursorPipe = cp
            cp.start()
        } else {
            cursorPipe = nil
        }

        let onResolved: @Sendable (Int, Int) -> Void = { w, h in
            bridge.setDesktopSize(width: w, height: h)
            inputBoxRef.value = InputInjector(
                surfaceWidth: w, surfaceHeight: h,
                outputDisplayBounds: outBounds,
                wheelPixelsPerNotch: wheelPx)
            hybridCoord?.resolutionChanged(width: w, height: h)
            cursorPipe?.updateGeometry(surfaceWidth: w, surfaceHeight: h, displayID: primary)
        }

        // SCK-delivered audio path: only enabled when the client
        // wanted "play on this computer". All audio flows through
        // self.audioPath, which is a single object the
        // onAudioFormatSelected callback updates with an AAC encoder
        // when mstsc picks AAC. No need to rebuild the pipeline.
        let audioEnabled = config.audioOut.enabled && audioMode == .playOnThisComputer
        let audioHandler: DisplayPipeline.AudioFrameHandler?
        if audioEnabled {
            let path = AudioPath(bridge: bridge)
            self.audioPath = path
            audioHandler = { pcm in path.ingest(pcm) }
        } else {
            audioHandler = nil
        }

        let pipeline: DisplayPipeline
        switch config.video.codec.lowercased() {
        case "hybrid":
            Log.encoder.notice("Using RDPGFX codec: hybrid (per-tile AVC420 + Progressive)")
            pipeline = DisplayPipeline(
                config: config,
                onAudioFrame: audioHandler,
                onDimensionsResolved: onResolved,
                hybridSink: hybridCoord,
                shouldDropCapture: {
                    bridge.outstandingFrames >= maxOutstanding
                })
        case "progressive":
            Log.encoder.notice("Using RDPGFX codec: RemoteFX Progressive V2")
            pipeline = DisplayPipeline(
                config: config,
                onRawFrame: { bgra, w, h, stride in
                    if bridge.sendProgressive(bgra: bgra, surfaceID: 0,
                                              width: w, height: h, stride: stride) {
                        frameCounter.tick(bytes: 0, isIDR: false)
                    }
                },
                onAudioFrame: audioHandler,
                onDimensionsResolved: onResolved,
                shouldDropCapture: {
                    bridge.outstandingFrames >= maxOutstanding
                })
        default:   // "avc420" and unrecognized
            Log.encoder.notice("Using RDPGFX codec: AVC420 (VideoToolbox H.264)")
            pipeline = DisplayPipeline(
                config: config,
                onEncodedFrame: { data, isIDR, pts in
                    let sent = bridge.sendH264(data, surfaceID: 0, isIDR: isIDR, pts: pts)
                    if sent {
                        frameCounter.tick(bytes: data.count, isIDR: isIDR)
                    }
                },
                onAudioFrame: audioHandler,
                onDimensionsResolved: onResolved,
                shouldDropCapture: {
                    bridge.outstandingFrames >= maxOutstanding
                })
        }

        // Audio out — three RDP modes:
        //   .doNotPlay         → don't start anything (Mac plays nothing or
        //                        plays locally per its own routing; client
        //                        explicitly opted out)
        //   .playOnRemote      → don't start CATap (let Mac speakers play
        //                        normally, NO muting); RDPSND won't be opened
        //                        by the bridge in this mode
        //   .playOnThisComputer → start CATap + ship via RDPSND (current
        //                         default)
        // Audio out is delivered via SCStream (capturesAudio=true) above.
        // AudioOutPipeline now exists solely to mute the Mac speakers
        // for the duration of the session (via a tap with
        // muteBehavior=.muted — the side-effect-only path).
        if audioMode == .playOnThisComputer {
            let mute = AudioOutPipeline(config: config)
            do {
                try mute.start()
                self.audioOut = mute
            } catch {
                Log.audioOut.error("local mute setup failed: \(String(describing: error), privacy: .public)")
            }
        }
        Log.audioOut.info("Audio out via SCK (mode=\(String(describing: audioMode), privacy: .public))")

        // Audio in (client mic → Mac) — start the playback engine. PCM
        // arriving over AUDIN gets routed here. With a loopback output
        // (BlackHole) configured via config.audioIn.outputDeviceUID,
        // Mac apps see a usable virtual mic. Without one, the audio
        // plays through whatever output is default — not very useful
        // but proves the wire works.
        if config.audioIn.enabled {
            let inPipe = AudioInPipeline(config: config)
            do {
                try inPipe.start()
                self.audioIn = inPipe
            } catch {
                Log.audioIn.error("audio in start failed: \(String(describing: error), privacy: .public)")
            }
        }

        // CLIPRDR — text + image (Phase 6). The bridge handles file
        // support at the wire level but ClipboardBridge currently only
        // ships text/image; files land in Phase 7.
        if config.clipboard.text || config.clipboard.image || config.clipboard.files {
            let clip = ClipboardBridge(config: config)
            // Outbound wiring — these closures run on whatever thread
            // invoked the C bridge callback / data provider; they're
            // Sendable and BridgePeer methods are thread-safe.
            clip.sendFormatList = { formats in
                bridge.sendClipFormatList(formats)
            }
            clip.sendFormatDataResponse = { fid, data in
                bridge.sendClipDataResponse(formatID: fid, data: data)
            }
            clip.sendFormatDataRequest = { fid in
                bridge.sendClipDataRequest(formatID: fid)
            }
            clip.sendFileContentsResponse = { sid, ok, data in
                bridge.sendClipFileContentsResponse(streamID: sid, success: ok, data: data)
            }
            clip.sendFileContentsRequest = { sid, idx, wantSize, off, len, clipDataID in
                bridge.sendClipFileContentsRequest(
                    streamID: sid, listIndex: idx,
                    wantSize: wantSize, offset: off, length: len,
                    clipDataID: clipDataID)
            }
            clip.sendClipLock   = { cid in bridge.sendClipLock(clipDataID: cid) }
            clip.sendClipUnlock = { cid in bridge.sendClipUnlock(clipDataID: cid) }
            do {
                try clip.start()
                self.clipboard = clip
            } catch {
                Log.clip.error("clipboard start failed: \(String(describing: error), privacy: .public)")
            }
        }

        self.displayPipeline = pipeline
        // Resize-policy collaborators: mode-setter ("setOnServer") and the
        // resize-hook driver ("cliCommand"). Selected per-screen in onDispLayout.
        self.displayModeController = DisplayModeController(
            hidpiPolicy: config.display.resizeHiDPIPolicy)
        self.displayControl = DisplayControl(
            config: config, pipeline: pipeline, mapping: displayMapping)
        let w = width, h = height
        Task { @MainActor in
            do {
                try await pipeline.start(displayID: primary, width: w, height: h)
            } catch {
                Log.display.error("display pipeline start failed: \(String(describing: error), privacy: .public)")
            }
        }
        #endif
    }

    private func onClosed(reason: Int) {
        Log.session.info("Peer closed: reason=\(reason, privacy: .public)")
        shutdown()
    }

    private func onSuppressOutput(allow: Bool) {
        Log.session.info("Client suppress_output: allow=\(allow, privacy: .public)")
        if allow {
            displayPipeline?.resumeCapture()
        } else {
            displayPipeline?.pauseCapture()
        }
    }

    /// Client requested a desktop resize (window resize / fullscreen
    /// toggle). Apply the primary monitor's dimensions to the capture
    /// pipeline; aspect-fit + RESETGRAPHICS happens automatically via
    /// the existing onDimensionsResolved callback.
    private func onDispLayout(monitors: [MonitorLayout]) {
        guard let primary = monitors.first(where: { $0.primary }) ?? monitors.first else {
            return
        }
        let slot = primary.rdpSlot
        let policy = ResizePolicy(config.display.effectiveResizePolicy(slot: slot))
        let w = primary.width, h = primary.height
        let scale = primary.scale
        Log.resize.info("Client DISP request: slot=\(slot, privacy: .public) \(w, privacy: .public)x\(h, privacy: .public) scale=\(scale, privacy: .public) policy=\(policy.rawValue, privacy: .public)")
        guard let pipeline = displayPipeline else { return }

        switch policy {
        case .none:
            return

        case .resize:
            // GPU resample the captured frame to the client size (aspect-fit);
            // pipeline.resize skips when the fit is already exact.
            Task { @MainActor in
                do { try await pipeline.resize(width: w, height: h) }
                catch { Log.resize.error("resize failed: \(String(describing: error), privacy: .public)") }
            }

        case .setOnServer:
            let displayID = displayMapping.displayID(forSlot: slot) ?? CGMainDisplayID()
            let ctrl = displayModeController
            Task { @MainActor in
                let fit = ctrl?.applyBestFit(displayID: displayID,
                                             clientPixelW: w, clientPixelH: h,
                                             desktopScale: scale)
                // Capture at the new native size (1:1) if we changed it, else
                // fall back to resampling to the client size.
                let (rw, rh) = fit ?? (w, h)
                do { try await pipeline.resize(width: rw, height: rh) }
                catch { Log.resize.error("setOnServer resize failed: \(String(describing: error), privacy: .public)") }
            }

        case .cliCommand:
            guard let ctrl = displayControl else {
                Log.resize.error("cliCommand policy but no DisplayControl / resize_hook configured")
                return
            }
            Task { @MainActor in await ctrl.handleClientResize(raw: monitors) }
        }
    }
}
