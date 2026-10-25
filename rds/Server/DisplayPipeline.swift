//
//  DisplayPipeline.swift
//  MacRDP
//
//  Captures a single SCDisplay via ScreenCaptureKit, feeds CVPixelBuffers
//  to a VideoToolbox H264Encoder, and emits Annex-B frames to the
//  configured callback (which the FreeRDP bridge will wire to RDPGFX in
//  Phase 0c+).
//
//  Phase 1 ships single-display capture. Phase 8 wraps multiple
//  DisplayPipeline instances (one per bound rdpSlot) inside RDPSession.
//

import Foundation
import ScreenCaptureKit
@preconcurrency import CoreMedia
@preconcurrency import CoreVideo
import os

@MainActor
final class DisplayPipeline {
    typealias EncodedFrameHandler =
        @Sendable (Data, _ isIDR: Bool, _ pts: CMTime) -> Void
    /// SCK-delivered system audio PCM. Bytes are Int16LE stereo @ 48 kHz
    /// (we configure SCStream to that format).
    typealias AudioFrameHandler = @Sendable (Data) -> Void
    /// Raw-pixel handler for the RemoteFX Progressive path. The closure
    /// receives a locked, contiguous BGRA buffer + dimensions and must
    /// finish using the pointer before returning (no async access).
    typealias RawFrameHandler =
        @Sendable (_ bgra: UnsafePointer<UInt8>,
                   _ width: Int, _ height: Int,
                   _ stride: Int) -> Void
    typealias BackpressureProbe = @Sendable () -> Bool
    /// Called right after we resolve the actual capture dimensions
    /// (which may differ from the client's request due to aspect-ratio
    /// preservation). RDPSession uses this to tell the bridge to advertise
    /// the new desktop size + update InputInjector's coordinate space.
    typealias DimensionsResolved = @Sendable (_ width: Int, _ height: Int) -> Void

    private let config: Config
    private var stream: SCStream?
    private var encoder: H264Encoder?
    /// BGRA → full-range NV12 for the hybrid H.264 path (non-nil only in hybrid).
    private var nv12Converter: NV12Converter?
    private var output: StreamOutputProxy?
    private var currentDisplayID: CGDirectDisplayID = 0
    private var currentWidth: Int = 0
    private var currentHeight: Int = 0
    private var nextForceKeyframe = true
    /// The newest complete capture, and whether the client may lack it.
    /// Captures are skipped (too many unacked frames), refused by the bridge
    /// or dropped by the encoder on the assumption that a later capture
    /// replaces them, but once the picture goes still no later capture comes
    /// and the client keeps an older picture for good. So the newest one is
    /// resubmitted as soon as the backlog allows.
    private var lastSample: CMSampleBuffer?
    private var nudge: CompositorNudge?
    /// The nudge window's pixel(s) in capture space. SCK reports them dirty
    /// on every forced composite though the window is excluded.
    private var nudgeRect: CGRect?
    // Capture rate, logged every 10 s while frames come: new captures, and
    // how many of them backpressure kept from the encoder.
    private var statsCaptured = 0
    private var statsSkipped = 0
    private var statsSince = ProcessInfo.processInfo.systemUptime
    private var repaintPending = false
    private var repaintPolling = false
    /// Set by the SuppressOutput handler when the client minimizes / hides
    /// its window. While paused we still receive SCK frames but drop them
    /// in `handleSample`, and don't send anything on the GFX channel.
    private var paused = false
    /// True from the moment `start(..)` is called until `stop()` runs.
    /// Used by the SCStream stop-with-error handler to distinguish
    /// "we asked it to stop" vs "macOS killed our capture" — only the
    /// latter triggers an auto-reconnect.
    private var expectsRunning = false
    /// Auto-reconnect attempt counter (exponential backoff).
    private var reconnectAttempts: Int = 0
    /// Set while a reconnect is being scheduled or performed so a
    /// subsequent didStopWithError doesn't stack reconnect tasks.
    private var reconnectInProgress = false

    func pauseCapture()  { paused = true;  nextForceKeyframe = true }

    /// An encoded frame never reached the client (the bridge refused it):
    /// the client's decoder is a frame behind, so resync with an IDR of the
    /// newest capture.
    func encodedFrameLost() {
        nextForceKeyframe = true
        requestRepaint()
    }
    func resumeCapture() {
        paused = false
        nextForceKeyframe = true
        hybridSink?.repaintAll()
        requestRepaint()
    }

    let onEncodedFrame: EncodedFrameHandler?
    let onRawFrame: RawFrameHandler?
    let onAudioFrame: AudioFrameHandler?
    let onDimensionsResolved: DimensionsResolved?
    /// Hybrid per-tile codec sink. When set, capture is BGRA, the H.264
    /// encoder is stood up, and each frame is routed per-tile through this
    /// sink instead of the avc420/progressive single-codec paths.
    let hybridSink: HybridFrameSink?
    /// Returns true if the encoder should skip this capture (network /
    /// client behind). Polled per captured sample buffer.
    let shouldDropCapture: BackpressureProbe

    init(config: Config,
         onEncodedFrame: EncodedFrameHandler? = nil,
         onRawFrame: RawFrameHandler? = nil,
         onAudioFrame: AudioFrameHandler? = nil,
         onDimensionsResolved: DimensionsResolved? = nil,
         hybridSink: HybridFrameSink? = nil,
         shouldDropCapture: @escaping BackpressureProbe = { false }) {
        self.config = config
        self.onEncodedFrame = onEncodedFrame
        self.onRawFrame = onRawFrame
        self.onAudioFrame = onAudioFrame
        self.onDimensionsResolved = onDimensionsResolved
        self.hybridSink = hybridSink
        self.shouldDropCapture = shouldDropCapture
    }

    /// Enumerate macOS displays. Used by RDPSession at session start
    /// to seed DisplayMapping.
    static func availableDisplays() async throws -> [AvailableDisplay] {
        let content = try await SCShareableContent.current
        let primary = CGMainDisplayID()
        return content.displays.map {
            AvailableDisplay(displayID: $0.displayID,
                             isPrimary: $0.displayID == primary)
        }
    }

    /// Start capturing a specific display, resampled to (width, height).
    /// Passing width/height = 0 falls back to the display's native pixel size.
    func start(displayID: CGDirectDisplayID,
               width: Int = 0,
               height: Int = 0) async throws {
        try await teardown()

        let content = try await SCShareableContent.current
        guard let display = content.displays.first(where: { $0.displayID == displayID })
                          ?? content.displays.first else {
            throw MacRDPError.capturePermissionDenied
        }

        currentDisplayID = display.displayID

        // Preserve the Mac display's aspect ratio. If the client requested
        // a different aspect, SCK would letterbox/pad the content and our
        // linear mouse mapping would lie about where pixels are. Instead,
        // compute the largest size that (a) has Mac's exact aspect ratio
        // and (b) fits within the client's requested bounds. The bridge
        // then advertises THESE dimensions via RESETGRAPHICS so the
        // client adapts.
        let macW = CGDisplayPixelsWide(display.displayID)
        let macH = CGDisplayPixelsHigh(display.displayID)
        let reqW = width  > 0 ? width  : macW
        let reqH = height > 0 ? height : macH
        let macAR  = Double(macW) / Double(max(1, macH))
        let reqAR  = Double(reqW) / Double(max(1, reqH))
        let pxW: Int, pxH: Int
        if macAR > reqAR {
            pxW = reqW
            pxH = max(2, Int((Double(reqW) / macAR).rounded()))
        } else {
            pxH = reqH
            pxW = max(2, Int((Double(reqH) * macAR).rounded()))
        }
        currentWidth  = pxW
        currentHeight = pxH
        if pxW != reqW || pxH != reqH {
            LogTo.display.notice(
                "Aspect-fit: Mac \(macW)x\(macH) → capture \(pxW)x\(pxH) (client requested \(reqW)x\(reqH))")
        }
        // Tell the rest of the stack about the resolved dimensions so
        // the bridge advertises them via RESETGRAPHICS and the input
        // injector uses the right coord space.
        onDimensionsResolved?(pxW, pxH)

        let cfg = SCStreamConfiguration()
        cfg.width  = pxW
        cfg.height = pxH
        // AVC420 path uses NV12 (VT-native). Progressive and hybrid both
        // need BGRA bytes (progressive_compress + per-tile analysis); the
        // hybrid H.264 encoder is fed BGRA too (VT converts internally).
        if onRawFrame != nil || hybridSink != nil {
            cfg.pixelFormat = kCVPixelFormatType_32BGRA
        } else {
            cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        }
        cfg.minimumFrameInterval = CMTime(value: 1,
            timescale: CMTimeScale(max(config.video.maxFps * 2, 120)))
        cfg.queueDepth = config.video.sckQueueDepth
        // Hardware cursor: keep the pointer OUT of the captured frame and send
        // it over the RDP pointer channel instead (see CursorPipeline).
        cfg.showsCursor = !config.cursor.hardwareCursor
        cfg.colorSpaceName = CGColorSpace.sRGB
        // System audio capture (SCK 14+). Cheaper and more reliable than
        // building our own CATap-on-aggregate-device — Apple's own
        // pipeline delivers Int16/Float PCM directly through the stream.
        if onAudioFrame != nil {
            cfg.capturesAudio = true
            cfg.sampleRate = 48000
            cfg.channelCount = 2
            cfg.excludesCurrentProcessAudio = true
        }

        // See CompositorNudge: SCK may hold a lone change until the next
        // composite. The nudge window itself stays out of the picture.
        var excluded: [SCWindow] = []
        if config.video.compositorNudgeMs > 0 {
            let n = CompositorNudge(display: display.displayID, intervalMs: config.video.compositorNudgeMs)
            nudge = n
            if let w = await n.shareableWindow() { excluded = [w] }
            else { LogTo.display.error("Compositor nudge window not in shareable content; it will show in the picture") }
            nudgeRect = CGRect(x: 0, y: 0,
                               width: (Double(pxW) / Double(max(1, display.width))).rounded(.up),
                               height: (Double(pxH) / Double(max(1, display.height))).rounded(.up))
        }
        let filter = SCContentFilter(display: display, excludingWindows: excluded)

        // Stand up the H.264 encoder for the AVC420 path or the hybrid path.
        // Hybrid feeds BGRA (VT converts); AVC420 feeds NV12.
        if let sink = hybridSink {
            // Feed the encoder full-range NV12 (converted from BGRA below) so
            // H.264 whites/blacks match the Progressive tiles — see NV12Converter.
            // fullRangeVideo=false (debug) skips it: BGRA → VT limited range, so
            // H.264 tiles render darker and the codec map is visible by eye.
            let fullRange = config.video.tile.encoder.fullRangeVideo
            let encoderSettings = H264Encoder.Settings.from(
                config.video, width: pxW, height: pxH,
                pixelFormat: fullRange ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                                       : kCVPixelFormatType_32BGRA)
            self.nv12Converter = fullRange ? NV12Converter() : nil
            self.encoder = try H264Encoder(settings: encoderSettings) { data, isIDR, pts, userData in
                if let payload = userData as? HybridFramePayload {
                    sink.send(annexB: data, isIDR: isIDR, pts: pts, payload: payload)
                }
            }
        } else if let handler = onEncodedFrame {
            let encoderSettings = H264Encoder.Settings.from(
                config.video, width: pxW, height: pxH)
            self.encoder = try H264Encoder(settings: encoderSettings) { data, isIDR, pts, _ in
                handler(data, isIDR, pts)
            }
        } else {
            self.encoder = nil
        }
        wireRepaint()

        let audioHandler = onAudioFrame
        let audioStats = AudioStats()
        let proxy = StreamOutputProxy(
            onVideoSample: { [weak self] sample in
                Task { @MainActor [weak self] in
                    self?.handleSample(sample)
                }
            },
            onAudioSample: { sample in
                guard let h = audioHandler else { return }
                let frameCount = CMSampleBufferGetNumSamples(sample)
                let nominalRate = Self.nominalSampleRate(of: sample)
                let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
                // T_arrive: when SCK actually handed us this buffer. PTS is
                // when the audio was captured. The gap is hop A latency —
                // SCK's own capture + buffer delay before we ever see it.
                let arrived = CACurrentMediaTime()
                let sckDelayMs = max(0.0, (arrived - pts) * 1000)
                let t0 = arrived
                if let pcm = Self.extractInt16StereoPCM(from: sample) {
                    h(pcm)
                }
                let dt = CACurrentMediaTime() - t0
                audioStats.tick(frames: frameCount, ptsSec: pts,
                                nominalRate: nominalRate,
                                sckDelayMs: sckDelayMs, sendMs: dt * 1000)
            },
            onStopped: { [weak self] error in
                Task { @MainActor [weak self] in
                    self?.handleStreamStopped(error: error)
                }
            })
        self.output = proxy

        let stream = SCStream(filter: filter, configuration: cfg, delegate: proxy)
        let videoQueue = DispatchQueue(label: "com.macrdp.scstream.video",
                                       qos: .userInteractive)
        let audioQueue = DispatchQueue(label: "com.macrdp.scstream.audio",
                                       qos: .userInteractive)
        try stream.addStreamOutput(proxy, type: .screen,
                                   sampleHandlerQueue: videoQueue)
        if onAudioFrame != nil {
            try stream.addStreamOutput(proxy, type: .audio,
                                       sampleHandlerQueue: audioQueue)
            LogTo.audioOut.info("SCK system audio capture enabled")
        }
        try await stream.startCapture()
        self.stream = stream
        nextForceKeyframe = true
        expectsRunning = true
        // Clear any leftover reconnect state so a subsequent
        // stream death restarts the backoff from 1 s rather than
        // continuing whatever climb was in flight.
        reconnectAttempts = 0
        reconnectInProgress = false

        LogTo.display.info("Display capture started \(pxW)x\(pxH) (CGDirectDisplayID=\(self.currentDisplayID))")
    }

    func stop() {
        expectsRunning = false
        Task { @MainActor in
            try? await teardown()
        }
    }

    /// Called from `StreamOutputProxy.stream:didStopWithError`. macOS
    /// kills our SCStream on display sleep/wake, lid close, GPU driver
    /// hiccups, etc. If the user still expects us to be capturing
    /// (i.e. `stop()` wasn't called), reconnect with exponential
    /// backoff. Without this the RDP screen "freezes" — input still
    /// flows, but no video frames are produced.
    @MainActor
    private func handleStreamStopped(error: Error) {
        // Ignore if the stop was requested by us.
        guard expectsRunning else {
            reconnectAttempts = 0
            reconnectInProgress = false
            return
        }
        guard !reconnectInProgress else { return }
        reconnectInProgress = true
        // Tear down any stale state from the dead stream so the next
        // `start(..)` doesn't trip over self.stream.
        self.stream = nil
        self.encoder?.invalidate()
        self.encoder = nil
        self.output = nil

        // Backoff: 1s, 2s, 4s, ..., capped at 30s.
        let delaySec = min(pow(2.0, Double(reconnectAttempts)), 30.0)
        reconnectAttempts += 1
        LogTo.display.notice("SCStream lost (\(String(describing: error))); reconnect attempt \(self.reconnectAttempts) in \(delaySec)s")

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delaySec * 1_000_000_000))
            await self?.attemptReconnect()
        }
    }

    @MainActor
    private func attemptReconnect() async {
        guard expectsRunning else {
            reconnectInProgress = false
            return
        }
        let id = currentDisplayID
        let w = currentWidth
        let h = currentHeight
        do {
            try await start(displayID: id, width: w, height: h)
            reconnectAttempts = 0
            reconnectInProgress = false
            LogTo.display.info("SCStream reconnected on display \(id) \(w)x\(h)")
        } catch {
            LogTo.display.error("SCStream reconnect failed: \(String(describing: error))")
            reconnectInProgress = false
            // Treat the failure itself as another stop event so we
            // keep retrying with backoff.
            handleStreamStopped(error: error)
        }
    }

    /// Resize capture + encoder in place. Aspect-fits against the
    /// current Mac display, then fires onDimensionsResolved so the
    /// bridge re-advertises the new size via RESETGRAPHICS.
    func resize(width: Int, height: Int) async throws {
        guard let stream else {
            throw MacRDPError.notImplementedYet("DisplayPipeline.resize before start")
        }

        // Same aspect-fit logic as start().
        let macW = CGDisplayPixelsWide(currentDisplayID)
        let macH = CGDisplayPixelsHigh(currentDisplayID)
        let macAR = Double(macW) / Double(max(1, macH))
        let reqAR = Double(width) / Double(max(1, height))
        let pxW: Int, pxH: Int
        if macAR > reqAR {
            pxW = width
            pxH = max(2, Int((Double(width) / macAR).rounded()))
        } else {
            pxH = height
            pxW = max(2, Int((Double(height) * macAR).rounded()))
        }

        // Skip the reconfigure entirely if the aspect-fit lands on the size we
        // already capture (covers "one dim equal, the other larger" and "both
        // equal") — avoids a needless SCStream reconfigure + latency hit.
        if pxW == currentWidth && pxH == currentHeight {
            LogTo.display.info("Resize \(width)x\(height) → no-op (already \(pxW)x\(pxH))")
            return
        }

        let cfg = SCStreamConfiguration()
        cfg.width  = pxW
        cfg.height = pxH
        cfg.pixelFormat = (onRawFrame != nil || hybridSink != nil)
            ? kCVPixelFormatType_32BGRA
            : kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        cfg.minimumFrameInterval = CMTime(value: 1,
            timescale: CMTimeScale(max(config.video.maxFps * 2, 120)))
        cfg.queueDepth = config.video.sckQueueDepth
        cfg.showsCursor = !config.cursor.hardwareCursor

        try await stream.updateConfiguration(cfg)

        encoder?.invalidate()
        if let sink = hybridSink {
            let settings = H264Encoder.Settings.from(
                config.video, width: pxW, height: pxH,
                pixelFormat: kCVPixelFormatType_32BGRA)
            self.encoder = try H264Encoder(settings: settings) { data, isIDR, pts, userData in
                if let payload = userData as? HybridFramePayload {
                    sink.send(annexB: data, isIDR: isIDR, pts: pts, payload: payload)
                }
            }
        } else if let handler = onEncodedFrame {
            let settings = H264Encoder.Settings.from(
                config.video, width: pxW, height: pxH)
            self.encoder = try H264Encoder(settings: settings) { data, isIDR, pts, _ in
                handler(data, isIDR, pts)
            }
        } else {
            self.encoder = nil
        }
        wireRepaint()
        self.currentWidth = pxW
        self.currentHeight = pxH
        self.nextForceKeyframe = true
        LogTo.display.info("Display resize \(pxW)x\(pxH) (client requested \(width)x\(height))")
        onDimensionsResolved?(pxW, pxH)
    }

    // MARK: - Internals

    /// Convert an SCK audio CMSampleBuffer (Float32 planar @ configured
    /// sample rate / channel count) into Int16LE interleaved bytes for
    /// RDPSND. Tracks the audio path: producer rate vs. real-time, chunk
    /// size distribution, time spent in our send path, AND the
    /// PTS→arrival delay from SCK itself (hop A — everything that
    /// happens before the buffer reaches our callback). Logs every ~2s.
    ///
    /// Reading the line:
    ///   * `nominal` — sample rate SCK *claims* in the buffer format
    ///      descriptor. Should match `cfg.sampleRate = 48000`; if not,
    ///      SCK silently down/upgraded our request and the resample to
    ///      the 44.1 kHz wire rate (PCMResampler) starts from the wrong
    ///      rate.
    ///   * `rateCum` — cumulative empirical rate (totalFrames /
    ///      wallElapsed) since the stream started. The TRUTH about how
    ///      fast SCK is actually delivering samples. > 48000 → over-
    ///      delivery → client buffer grows; < 48000 → under-delivery →
    ///      buffer drains.
    ///   * `rateWin` — same calc over the last ~2s only. Diverges from
    ///      rateCum when SCK is bursting (rateWin > rateCum during
    ///      catch-up, < cumulative during stall recovery).
    ///   * `drift` — cumulative (wallElapsed − ptsElapsed). Same idea as
    ///      rate but ms-based; grows if PTS clock and wall clock disagree.
    ///   * `sck(avg/max)` — capture→our-callback gap. Steady-state value
    ///      is SCK's own internal buffer (~10-50ms on a healthy stream);
    ///      growth means SCK is delivering older audio each tick.
    ///   * `send(avg/max)` — time we spend in extractPCM + AAC encode +
    ///      bridge handoff per chunk.
    ///
    /// `@unchecked Sendable` because the proxy closure captures it from
    /// any thread; internal lock serializes the counters.
    fileprivate final class AudioStats: @unchecked Sendable {
        private let lock = NSLock()
        private var startWall: Double = 0
        private var totalFrames: Int = 0
        private var maxChunk: Int = 0
        private var minChunk: Int = .max
        private var maxSendMs: Double = 0
        private var sumSendMs: Double = 0
        private var maxSCKMs: Double = 0
        private var sumSCKMs: Double = 0
        private var samples: Int = 0
        private var lastLogWall: Double = 0
        private var firstPTS: Double = -1
        // Frames-at-last-log snapshot for the short-window rate.
        private var winFramesAtLastLog: Int = 0
        // Nominal rate from the latest buffer's format desc (should be
        // constant per stream; latest-wins covers any mid-stream reformat).
        private var nominalRate: Double = 0

        func tick(frames: Int, ptsSec: Double, nominalRate: Double,
                  sckDelayMs: Double, sendMs: Double) {
            lock.lock()
            let now = CACurrentMediaTime()
            if startWall == 0 { startWall = now; lastLogWall = now }
            if firstPTS < 0 { firstPTS = ptsSec }
            if nominalRate > 0 { self.nominalRate = nominalRate }
            totalFrames += frames
            maxChunk = max(maxChunk, frames)
            minChunk = min(minChunk, frames)
            maxSendMs = max(maxSendMs, sendMs)
            sumSendMs += sendMs
            maxSCKMs = max(maxSCKMs, sckDelayMs)
            sumSCKMs += sckDelayMs
            samples += 1
            if now - lastLogWall >= 2.0 {
                let wallElapsed = now - startWall
                let rateCum = Double(totalFrames) / wallElapsed
                let winFrames = totalFrames - winFramesAtLastLog
                let winSec = now - lastLogWall
                let rateWin = winSec > 0 ? Double(winFrames) / winSec : 0
                let ptsElapsed = ptsSec - firstPTS
                let drift = wallElapsed - ptsElapsed
                let avgSend = sumSendMs / Double(samples)
                let avgSCK  = sumSCKMs  / Double(samples)
                let snapMinChunk = minChunk == .max ? -1 : minChunk
                let snapMaxChunk = maxChunk
                let snapMaxSend  = maxSendMs
                let snapMaxSCK   = maxSCKMs
                let snapNominal = self.nominalRate
                lock.unlock()
                LogTo.audioOut.info("Audio: nominal=\(Int(snapNominal))Hz rateCum=\(Int(rateCum))Hz rateWin=\(Int(rateWin))Hz drift=\(Int(drift*1000))ms chunk(min/max)=\(snapMinChunk)/\(snapMaxChunk) sck(avg/max)=\(Int(avgSCK))/\(Int(snapMaxSCK))ms send(avg/max)=\(Int(avgSend))/\(Int(snapMaxSend))ms")
                lock.lock()
                lastLogWall = now
                winFramesAtLastLog = totalFrames
                maxChunk = 0; minChunk = .max
                maxSendMs = 0; sumSendMs = 0
                maxSCKMs = 0; sumSCKMs = 0
                samples = 0
            }
            lock.unlock()
        }
    }

    /// SCK's nominal sample rate as declared in the buffer's format
    /// descriptor — the rate SCK CLAIMS each frame represents. Compare
    /// against the requested 48000 and against the empirical
    /// `totalFrames / wallElapsed` rate logged in AudioStats: any
    /// divergence between the three is a smoking gun for buffer-growth
    /// at the client (we tag the audio as one rate but deliver another).
    nonisolated static func nominalSampleRate(of sample: CMSampleBuffer) -> Double {
        guard let fd = CMSampleBufferGetFormatDescription(sample),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)
        else { return 0 }
        return asbd.pointee.mSampleRate
    }

    /// RDPSND. Returns nil on any extraction failure. Safe from any thread.
    nonisolated static func extractInt16StereoPCM(from sample: CMSampleBuffer) -> Data? {
        guard CMSampleBufferIsValid(sample),
              let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        let frameCount = CMSampleBufferGetNumSamples(sample)
        if frameCount == 0 { return nil }
        var totalLen = 0
        var dataPtr: UnsafeMutablePointer<CChar>?
        let st = CMBlockBufferGetDataPointer(block, atOffset: 0,
                                             lengthAtOffsetOut: nil,
                                             totalLengthOut: &totalLen,
                                             dataPointerOut: &dataPtr)
        guard st == kCMBlockBufferNoErr, let dataPtr else { return nil }
        // SCK delivers PLANAR Float32: L-channel block first then R, each
        // frameCount samples long. Convert to interleaved Int16LE.
        let floats = UnsafePointer<Float>(OpaquePointer(dataPtr))
        let lPtr = floats
        let rPtr = floats + frameCount   // if mono, this falls outside; guarded below
        let channels = totalLen >= frameCount * 4 * 2 ? 2 : 1
        var out = Data(count: frameCount * 4)
        out.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
            for i in 0..<frameCount {
                let l = max(-1.0, min(1.0, lPtr[i]))
                let r = (channels == 2) ? max(-1.0, min(1.0, rPtr[i])) : l
                base[i * 2 + 0] = Int16((l * 32767.0).rounded())
                base[i * 2 + 1] = Int16((r * 32767.0).rounded())
            }
        }
        return out
    }

    /// SCK attaches an SCStreamFrameInfo dictionary to each sample.
    /// Only `.complete` carries real new pixel data; .idle / .blank /
    /// .suspended / .started repeat the previous frame.
    private func isCompleteFrame(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sample, createIfNecessary: false) as? [[CFString: Any]],
              let first = attachments.first,
              let raw = first[SCStreamFrameInfo.status as CFString] as? Int,
              let status = SCFrameStatus(rawValue: raw) else {
            // No metadata — treat as new frame to be safe.
            return true
        }
        return status == .complete
    }

    /// SCK attaches the frame's changed regions as `SCStreamFrameInfoDirtyRects`
    /// — per the header, "an array of CGRect in NSValue … specified in pixels"
    /// (i.e. surface pixel coords, the same space as the tile grid). Returns
    /// nil when the attachment is absent so the analyzer falls back to a
    /// full-frame pixel-diff change signal.
    private static func dirtyRects(from sample: CMSampleBuffer) -> [CGRect]? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sample, createIfNecessary: false) as? [[CFString: Any]],
              let first = attachments.first,
              let raw = first[SCStreamFrameInfo.dirtyRects as CFString] as? [Any]
        else { return nil }
        // SCK stores each rect as a CGRect *dictionary representation*
        // (CFDictionary with X/Y/Width/Height), NOT an NSValue — decode each
        // with CGRect(dictionaryRepresentation:).
        return raw.compactMap { elem in
            (elem as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
        }
    }

    private func teardown() async throws {
        if let s = stream {
            try? await s.stopCapture()
            self.stream = nil
        }
        encoder?.invalidate()
        encoder = nil
        output = nil
        nudge?.stop()
        nudge = nil
        nudgeRect = nil
        lastSample = nil
        repaintPending = false
    }

    // MARK: - Repaint

    /// Frames lost downstream (bridge refusal, encoder drop, an AVC frame
    /// the client never decoded) ask for the newest capture to be sent
    /// again; a pending IDR request makes that resend a keyframe.
    private func wireRepaint() {
        let again: @Sendable () -> Void = { [weak self] in
            Task { @MainActor [weak self] in self?.requestRepaint() }
        }
        encoder?.onDropped = again
        hybridSink?.onRepaintNeeded = again
    }

    /// Resubmit the newest capture once the backlog clears, unless a newer
    /// one gets through first.
    func requestRepaint() {
        repaintPending = true
        guard !repaintPolling else { return }
        repaintPolling = true
        pollRepaint()
    }

    private func pollRepaint() {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(20)) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.repaintPending, let sample = self.lastSample else {
                    self.repaintPolling = false
                    return
                }
                if self.paused || self.shouldDropCapture() {
                    self.pollRepaint()
                    return
                }
                self.repaintPolling = false
                LogTo.display.info("Resending the newest capture: it never got to the client")
                self.handleSample(sample, repaint: true)
            }
        }
    }

    private func noteCapture(skipped: Bool) {
        statsCaptured += 1
        if skipped { statsSkipped += 1 }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - statsSince >= 10 else { return }
        let fps = Double(statsCaptured) / (now - statsSince)
        LogTo.display.notice("Capture: \(self.statsCaptured) new frames (\(String(format: "%.1f", fps)) fps), \(self.statsSkipped) skipped for backpressure")
        statsCaptured = 0; statsSkipped = 0; statsSince = now
    }

    private func handleSample(_ sample: CMSampleBuffer, repaint: Bool = false) {
        guard CMSampleBufferIsValid(sample) else { return }

        // SCK delivers at the configured fps even when nothing changed.
        // The frame's status attachment tells us if it's a real new frame
        // (.complete), unchanged (.idle), occluded, etc. Drop anything
        // that isn't actual new content — saves the entire encode pass +
        // a wire round-trip, and lowers the latency tail for the *next*
        // real change. The hybrid Schmitt is now wall-clock-bucketed
        // (TimeBucketHistory), so a tile that stops being touched exits
        // H.264 naturally on the next .complete; no idle-driven repaint.
        if !isCompleteFrame(sample) { return }
        // A composite the nudge forced: nothing changed but its own pixel.
        if !repaint, let nr = nudgeRect, let dirty = Self.dirtyRects(from: sample), !dirty.isEmpty,
           dirty.allSatisfy({ nr.contains($0) }) { return }

        guard let pixel = CMSampleBufferGetImageBuffer(sample) else { return }
        lastSample = sample
        if !repaint { noteCapture(skipped: paused || shouldDropCapture()) }

        // Client minimized / hid its window.
        if paused {
            nextForceKeyframe = true
            return
        }

        // Backpressure: skip the encode pass entirely if we have too
        // many in-flight frames, and send this capture again once the
        // backlog clears if nothing newer comes. No IDR: the encoder never
        // saw this frame, so its references are still the client's. (Forcing
        // one made every frame after a skip a keyframe under load: bigger,
        // slower to decode, slower acks, more skips.)
        if shouldDropCapture() {
            requestRepaint()
            return
        }
        repaintPending = false   // this capture supersedes any pending repaint

        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let force = nextForceKeyframe
        nextForceKeyframe = false

        // Hybrid per-tile path. Route the frame (analysis submit + read the
        // tile map + coalesce + optional mask), then either send a
        // Progressive-only frame (no video tiles) or encode the (masked)
        // frame; the encoder output callback composes both codecs.
        if let sink = hybridSink {
            // A repaint resends a capture already analysed: nothing changed.
            let dirty = repaint ? [] : Self.dirtyRects(from: sample)
            CVPixelBufferLockBaseAddress(pixel, .readOnly)
            let w = CVPixelBufferGetWidth(pixel)
            let h = CVPixelBufferGetHeight(pixel)
            let stride = CVPixelBufferGetBytesPerRow(pixel)
            let routing = sink.route(pixel: pixel, width: w, height: h, stride: stride,
                                     dirtyRects: dirty)
            CVPixelBufferUnlockBaseAddress(pixel, .readOnly)

            let payload = HybridFramePayload(
                captureToken: routing.captureToken,
                videoRects: routing.videoRects, staticRects: routing.staticRects,
                grid: routing.grid, pixel: pixel)

            if routing.videoRects.isEmpty {
                // Nothing photographic this frame — Progressive only.
                sink.send(annexB: nil, isIDR: false, pts: pts, payload: payload)
                return
            }
            // Convert the (masked) BGRA → full-range NV12 before encode so the
            // H.264 region isn't darker than the Progressive region. When the
            // converter is off (fullRangeVideo=false, debug), feed BGRA straight
            // to VT (limited range → darker H.264, visible codec map).
            let bgraInput = routing.maskedBuffer ?? pixel
            let encodeInput: CVPixelBuffer
            if let converter = nv12Converter {
                guard let nv12 = converter.convert(bgraInput) else {
                    LogTo.encoder.error("hybrid: NV12 conversion failed; dropping frame")
                    nextForceKeyframe = true
                    return
                }
                encodeInput = nv12
            } else {
                encodeInput = bgraInput
            }
            // The sink can demand an IDR after a prior send dropped its AVC NAL
            // (every blit rect filtered against newer Progressive paints) — the
            // client decoder DPB is one frame behind us until we resync.
            let forceFromSink = sink.popPendingKeyframe()
            do {
                try encoder?.encode(pixelBuffer: encodeInput,
                                    pts: pts,
                                    forceKeyframe: force || forceFromSink,
                                    userData: payload)
            } catch {
                LogTo.encoder.error("hybrid encode failed: \(String(describing: error))")
            }
            return
        }

        // Raw-frame path (RemoteFX Progressive) — hand the locked BGRA
        // pointer straight to the bridge; FreeRDP's progressive_compress
        // does the heavy lifting.
        if let rawHandler = onRawFrame {
            CVPixelBufferLockBaseAddress(pixel, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(pixel) else { return }
            let w = CVPixelBufferGetWidth(pixel)
            let h = CVPixelBufferGetHeight(pixel)
            let stride = CVPixelBufferGetBytesPerRow(pixel)
            rawHandler(base.assumingMemoryBound(to: UInt8.self), w, h, stride)
            return
        }

        do {
            try encoder?.encode(pixelBuffer: pixel, pts: pts, forceKeyframe: force)
        } catch {
            LogTo.encoder.error("encode failed: \(String(describing: error))")
        }
    }
}

/// Bridge from the Sendable-typed SCStreamOutput protocol back to
/// our @MainActor pipeline. Splits .screen vs .audio sample buffers
/// to separate handler closures.
private final class StreamOutputProxy: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let onVideoSample: @Sendable (CMSampleBuffer) -> Void
    private let onAudioSample: @Sendable (CMSampleBuffer) -> Void
    private let onStopped: @Sendable (Error) -> Void

    init(onVideoSample: @escaping @Sendable (CMSampleBuffer) -> Void,
         onAudioSample: @escaping @Sendable (CMSampleBuffer) -> Void,
         onStopped: @escaping @Sendable (Error) -> Void) {
        self.onVideoSample = onVideoSample
        self.onAudioSample = onAudioSample
        self.onStopped = onStopped
    }

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        switch type {
        case .screen: onVideoSample(sampleBuffer)
        case .audio:  onAudioSample(sampleBuffer)
        default:      break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        LogTo.display.error("SCStream stopped: \(String(describing: error))")
        onStopped(error)
    }
}
