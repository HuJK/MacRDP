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
    func resumeCapture() { paused = false; nextForceKeyframe = true }

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
            Log.display.notice(
                "Aspect-fit: Mac \(macW, privacy: .public)x\(macH, privacy: .public) → capture \(pxW, privacy: .public)x\(pxH, privacy: .public) (client requested \(reqW, privacy: .public)x\(reqH, privacy: .public))")
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
        cfg.showsCursor = !config.effectiveCursor.hardwareCursor
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

        let filter = SCContentFilter(display: display, excludingWindows: [])

        // Stand up the H.264 encoder for the AVC420 path or the hybrid path.
        // Hybrid feeds BGRA (VT converts); AVC420 feeds NV12.
        if let sink = hybridSink {
            // Feed the encoder full-range NV12 (converted from BGRA below) so
            // H.264 whites/blacks match the Progressive tiles — see NV12Converter.
            // fullRangeVideo=false (debug) skips it: BGRA → VT limited range, so
            // H.264 tiles render darker and the codec map is visible by eye.
            let fullRange = config.video.effectiveHybrid.fullRangeVideo
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
                let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
                let t0 = CACurrentMediaTime()
                if let pcm = Self.extractInt16StereoPCM(from: sample) {
                    h(pcm)
                }
                let dt = CACurrentMediaTime() - t0
                audioStats.tick(frames: frameCount, ptsSec: pts, sendMs: dt * 1000)
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
            Log.audioOut.info("SCK system audio capture enabled")
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

        Log.display.info("Display capture started \(pxW, privacy: .public)x\(pxH, privacy: .public) (CGDirectDisplayID=\(self.currentDisplayID, privacy: .public))")
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
        Log.display.notice("SCStream lost (\(String(describing: error), privacy: .public)); reconnect attempt \(self.reconnectAttempts, privacy: .public) in \(delaySec, privacy: .public)s")

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
            Log.display.info("SCStream reconnected on display \(id, privacy: .public) \(w, privacy: .public)x\(h, privacy: .public)")
        } catch {
            Log.display.error("SCStream reconnect failed: \(String(describing: error), privacy: .public)")
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
            Log.display.info("Resize \(width, privacy: .public)x\(height, privacy: .public) → no-op (already \(pxW, privacy: .public)x\(pxH, privacy: .public))")
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
        cfg.showsCursor = !config.effectiveCursor.hardwareCursor

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
        self.currentWidth = pxW
        self.currentHeight = pxH
        self.nextForceKeyframe = true
        Log.display.info("Display resize \(pxW, privacy: .public)x\(pxH, privacy: .public) (client requested \(width, privacy: .public)x\(height, privacy: .public))")
        onDimensionsResolved?(pxW, pxH)
    }

    // MARK: - Internals

    /// Convert an SCK audio CMSampleBuffer (Float32 planar @ configured
    /// sample rate / channel count) into Int16LE interleaved bytes for
    /// Tracks the audio path: producer rate vs. real-time, chunk size
    /// distribution, time spent in our send path. Logs every ~2s.
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
        private var samples: Int = 0
        private var lastLogWall: Double = 0
        private var firstPTS: Double = -1

        func tick(frames: Int, ptsSec: Double, sendMs: Double) {
            lock.lock()
            let now = CACurrentMediaTime()
            if startWall == 0 { startWall = now; lastLogWall = now }
            if firstPTS < 0 { firstPTS = ptsSec }
            totalFrames += frames
            maxChunk = max(maxChunk, frames)
            minChunk = min(minChunk, frames)
            maxSendMs = max(maxSendMs, sendMs)
            sumSendMs += sendMs
            samples += 1
            if now - lastLogWall >= 2.0 {
                let wallElapsed = now - startWall
                let measuredRate = Double(totalFrames) / wallElapsed
                let ptsElapsed = ptsSec - firstPTS
                // PTS drift = wall - PTS. If positive and growing, we're
                // falling behind SCK's queue (SCK delivers older audio
                // each tick). If negative, we're somehow ahead (unlikely).
                let drift = wallElapsed - ptsElapsed
                let avgSend = sumSendMs / Double(samples)
                lock.unlock()
                Log.audioOut.info("Audio: rate=\(Int(measuredRate), privacy: .public)Hz drift=\(Int(drift*1000), privacy: .public)ms chunk(min/max)=\(self.minChunk == .max ? -1 : self.minChunk, privacy: .public)/\(self.maxChunk, privacy: .public) send(avg/max)=\(Int(avgSend), privacy: .public)/\(Int(self.maxSendMs), privacy: .public)ms")
                lock.lock()
                lastLogWall = now
                maxChunk = 0; minChunk = .max
                maxSendMs = 0; sumSendMs = 0; samples = 0
            }
            lock.unlock()
        }
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
    }

    private func handleSample(_ sample: CMSampleBuffer) {
        guard CMSampleBufferIsValid(sample) else { return }

        // SCK delivers at the configured fps even when nothing changed.
        // The frame's status attachment tells us if it's a real new
        // frame (.complete), unchanged (.idle), occluded, etc. Drop
        // anything that isn't actual new content — saves the entire
        // encode pass + a wire round-trip, and lowers the latency tail
        // for the *next* real change.
        if !isCompleteFrame(sample) {
            // Idle frame (content unchanged). Use it to converge: if the client
            // is still showing a former H.264 region, repaint it once via
            // Progressive so it doesn't stay stuck on the last lossy blit.
            // No analysis here — idle frames carry no dirtyRects.
            if let sink = hybridSink, !paused, !shouldDropCapture(),
               let pixel = CMSampleBufferGetImageBuffer(sample) {
                sink.flushSettle(pixel: pixel,
                                 width: CVPixelBufferGetWidth(pixel),
                                 height: CVPixelBufferGetHeight(pixel),
                                 stride: CVPixelBufferGetBytesPerRow(pixel))
            }
            return
        }

        guard let pixel = CMSampleBufferGetImageBuffer(sample) else { return }

        // Client minimized / hid its window.
        if paused {
            nextForceKeyframe = true
            return
        }

        // Backpressure: skip the encode pass entirely if we have too
        // many in-flight frames. When we resume, force an IDR so the
        // client can decode without needing the frames we just dropped.
        if shouldDropCapture() {
            nextForceKeyframe = true
            return
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let force = nextForceKeyframe
        nextForceKeyframe = false

        // Hybrid per-tile path. Route the frame (analysis submit + read the
        // tile map + coalesce + optional mask), then either send a
        // Progressive-only frame (no video tiles) or encode the (masked)
        // frame; the encoder output callback composes both codecs.
        if let sink = hybridSink {
            let dirty = Self.dirtyRects(from: sample)
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
                    Log.encoder.error("hybrid: NV12 conversion failed; dropping frame")
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
                Log.encoder.error("hybrid encode failed: \(String(describing: error), privacy: .public)")
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
            Log.encoder.error("encode failed: \(String(describing: error), privacy: .public)")
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
        Log.display.error("SCStream stopped: \(String(describing: error), privacy: .public)")
        onStopped(error)
    }
}
