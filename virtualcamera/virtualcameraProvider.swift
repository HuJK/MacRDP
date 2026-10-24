//
//  virtualcameraProvider.swift
//  virtualcamera
//
//  MacRDP virtual camera CMIO extension.
//
//  Exposes a virtual camera ("MacRDP Camera") to the system. It owns two
//  streams on one device:
//    * source stream — what consumers (Zoom / FaceTime / Teams …) read.
//    * sink stream   — what the MacRDP host app writes into. Frames pushed
//      into the sink are forwarded straight to the source's consumers.
//
//  When nothing is feeding the sink (no RDP client camera connected) the
//  source emits a static "waiting" placeholder so the device always has a
//  valid signal.
//
//  Host side feeds frames via CoreMediaIO HAL: find the device by name, grab
//  its sink stream's CMSimpleQueue with CMIOStreamCopyBufferQueue, then
//  CMSimpleQueueEnqueue 32BGRA CMSampleBuffers. See VirtualCameraSinkClient
//  in the rds app target.
//
//  In-process testing: the same provider code can run inside a normal app
//  (no system extension install, no SIP changes) by constructing
//  virtualcameraProviderSource(clientQueue:hostedDelegate:). In that mode
//  CMIO publishing is bypassed — frames are delivered to the delegate, and
//  feedHosted(_:) stands in for the sink. See VirtualCameraHostedPreview.
//

import CoreGraphics
import CoreMediaIO
import CoreText
import Foundation
import IOKit.audio
import os.log

// MARK: - Configuration

let kFrameRate: Int = 30
let kFrameWidth: Int32 = 1280
let kFrameHeight: Int32 = 720

/// Custom CMIO property the host polls to learn the extension is ready to
/// receive on the sink. The 4-char token after "4cc_" must be exactly 4 bytes;
/// the host converts "sink" to a CMIOObjectPropertySelector.
private let kSinkPropertyToken = "sink"
private let customSinkExtensionProperty = CMIOExtensionProperty(
    rawValue: "4cc_" + kSinkPropertyToken + "_glob_0000")

/// Provider property the host sets to the manifest JSON (the devices to show).
private let customCamerasProviderProperty = CMIOExtensionProperty(
    rawValue: "4cc_" + VirtualCameraShared.camerasPropertyToken + "_glob_0000")

private let logger = Logger(subsystem: "com.mac-rdp.rds.virtualcamera", category: "Extension")

// MARK: - In-process testing hook

/// Receives frames when a device source runs in-process (hosted) instead of as
/// the system extension. The real CMIO source stream only delivers inside the
/// installed extension, so a hosted run routes here for on-screen preview.
public protocol VirtualCameraHostedDelegate: AnyObject {
    func virtualCamera(didOutput sampleBuffer: CMSampleBuffer)
}

// MARK: - Device source

class virtualcameraDeviceSource: NSObject, CMIOExtensionDeviceSource {

    private(set) var device: CMIOExtensionDevice!

    fileprivate var _streamSource: virtualcameraStreamSource!
    private var _streamSink: virtualcameraStreamSink!

    fileprivate var _streamingSourceCounter: UInt32 = 0
    private var _streamingSinkCounter: UInt32 = 0

    private var _sourceTimer: DispatchSourceTimer?
    private let _sourceTimerQueue = DispatchQueue(
        label: "com.mac-rdp.rds.virtualcamera.source", qos: .userInteractive,
        attributes: [], autoreleaseFrequency: .workItem,
        target: .global(qos: .userInteractive))

    private var _sinkTimer: DispatchSourceTimer?
    private let _sinkTimerQueue = DispatchQueue(
        label: "com.mac-rdp.rds.virtualcamera.sink", qos: .userInteractive,
        attributes: [], autoreleaseFrequency: .workItem,
        target: .global(qos: .userInteractive))

    private var _videoDescription: CMFormatDescription!
    private var _placeholderBuffer: CVPixelBuffer?
    /// The device UID, for the in-use notifications.
    private var _uid = ""

    /// `id` is a stable UUID string (also used as the CMIO device UID so apps
    /// can remember the selection). `localizedName` is shown in the picker.
    init(id: String, localizedName: String) {
        super.init()
        let deviceID = UUID(uuidString: id) ?? UUID()
        _uid = deviceID.uuidString
        device = CMIOExtensionDevice(
            localizedName: localizedName, deviceID: deviceID,
            legacyDeviceID: deviceID.uuidString, source: self)

        let dims = CMVideoDimensions(width: kFrameWidth, height: kFrameHeight)
        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, codecType: kCVPixelFormatType_32BGRA,
            width: dims.width, height: dims.height, extensions: nil,
            formatDescriptionOut: &_videoDescription)

        let videoStreamFormat = CMIOExtensionStreamFormat(
            formatDescription: _videoDescription,
            maxFrameDuration: CMTime(value: 1, timescale: Int32(kFrameRate)),
            minFrameDuration: CMTime(value: 1, timescale: Int32(kFrameRate)),
            validFrameDurations: nil)

        let videoID = UUID()
        let videoSinkID = UUID()
        _streamSource = virtualcameraStreamSource(
            localizedName: "MacRDP.Video", streamID: videoID,
            streamFormat: videoStreamFormat, device: device)
        _streamSink = virtualcameraStreamSink(
            localizedName: "MacRDP.Video.Sink", streamID: videoSinkID,
            streamFormat: videoStreamFormat, device: device)

        do {
            try device.addStream(_streamSource.stream)
            try device.addStream(_streamSink.stream)
        } catch {
            fatalError("Failed to add streams: \(error.localizedDescription)")
        }
    }

    // MARK: Device properties

    var availableProperties: Set<CMIOExtensionProperty> {
        [.deviceTransportType, .deviceModel]
    }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws
        -> CMIOExtensionDeviceProperties
    {
        let p = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) {
            p.transportType = kIOAudioDeviceTransportTypeVirtual
        }
        if properties.contains(.deviceModel) {
            p.model = "MacRDP Virtual Camera"
        }
        return p
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}

    fileprivate var sinkActive: Bool { _streamingSinkCounter > 0 }

    // MARK: In-process (hosted) testing

    /// When set, the device runs inside a normal app rather than the system
    /// extension: rendered/fed frames are delivered here instead of through the
    /// CMIO source stream. Leave nil in the shipping extension.
    weak var hostedDelegate: VirtualCameraHostedDelegate?
    private var _hosted: Bool { hostedDelegate != nil }
    private var _lastHostedFeed: CFAbsoluteTime = 0

    /// Begin emitting the placeholder frame for in-process preview.
    func startHostedPreview() { startStreamingSource() }

    /// In-process equivalent of pushing a frame to the sink. `pixelBuffer` must
    /// be 1280x720 32BGRA.
    func feedHosted(_ pixelBuffer: CVPixelBuffer) {
        _lastHostedFeed = CFAbsoluteTimeGetCurrent()
        send(pixelBuffer, into: _streamSource, at: CMClockGetTime(CMClockGetHostTimeClock()))
    }

    // MARK: Source streaming (placeholder when nothing feeds the sink)

    func startStreamingSource() {
        _streamingSourceCounter += 1
        if _streamingSourceCounter == 1, !_hosted {
            VirtualCameraShared.post(VirtualCameraShared.inUseNotification(id: _uid, inUse: true))
        }
        guard _sourceTimer == nil else { return }

        _sourceTimer = DispatchSource.makeTimerSource(flags: .strict, queue: _sourceTimerQueue)
        _sourceTimer!.schedule(deadline: .now(), repeating: 1.0 / Double(kFrameRate), leeway: .milliseconds(5))
        _sourceTimer!.setEventHandler { [weak self] in
            guard let self else { return }
            // Stay quiet while real frames are arriving — via the sink (real
            // extension) or feedHosted (in-process). Only synthesize when idle.
            if self.sinkActive { return }
            if self._hosted, CFAbsoluteTimeGetCurrent() - self._lastHostedFeed < 0.2 { return }
            guard let buffer = self.placeholderBuffer() else { return }
            let now = CMClockGetTime(CMClockGetHostTimeClock())
            self.send(buffer, into: self._streamSource, at: now)
        }
        _sourceTimer!.resume()
    }

    func stopStreamingSource() {
        if _streamingSourceCounter > 1 {
            _streamingSourceCounter -= 1
        } else {
            _streamingSourceCounter = 0
            _sourceTimer?.cancel()
            _sourceTimer = nil
            if !_hosted {
                VirtualCameraShared.post(VirtualCameraShared.inUseNotification(id: _uid, inUse: false))
            }
        }
    }

    // MARK: Sink streaming (host → extension)

    func startStreamingSink(client: CMIOExtensionClient) {
        _streamingSinkCounter += 1
        guard _sinkTimer == nil else { return }

        _sinkTimer = DispatchSource.makeTimerSource(flags: .strict, queue: _sinkTimerQueue)
        // Poll faster than the frame rate so we never starve when the host's
        // delivery jitters; consumeSampleBuffer returns nil when empty.
        _sinkTimer!.schedule(deadline: .now(), repeating: 1.0 / (Double(kFrameRate) * 2.0), leeway: .milliseconds(5))
        _sinkTimer!.setEventHandler { [weak self] in
            guard let self else { return }
            self._streamSink.stream.consumeSampleBuffer(from: client) { sbuf, seq, _, _, err in
                guard let sbuf else {
                    if let err { self.noteSink(error: err) }
                    return
                }
                self.noteSink(forwarded: self._streamingSourceCounter > 0)
                let now = CMClockGetTime(CMClockGetHostTimeClock())
                let output = CMIOExtensionScheduledOutput(
                    sequenceNumber: seq,
                    hostTimeInNanoseconds: UInt64(now.seconds * Double(NSEC_PER_SEC)))
                if self._streamingSourceCounter > 0 {
                    self._streamSource.stream.send(
                        sbuf, discontinuity: [],
                        hostTimeInNanoseconds: UInt64(sbuf.presentationTimeStamp.seconds * Double(NSEC_PER_SEC)))
                }
                self._streamSink.stream.notifyScheduledOutputChanged(output)
            }
        }
        _sinkTimer!.resume()
    }

    /// Sink traffic, logged every 5 s: frames taken from the host and
    /// forwarded to readers, and consume errors. Diagnostics only.
    private let _sinkStatsLock = NSLock()
    private var _sinkConsumed = 0, _sinkForwarded = 0, _sinkErrors = 0
    private var _sinkLastError = ""
    private var _sinkStatsSince: CFAbsoluteTime = 0

    private func noteSink(forwarded: Bool? = nil, error: Error? = nil) {
        _sinkStatsLock.lock()
        defer { _sinkStatsLock.unlock() }
        if let forwarded {
            _sinkConsumed += 1
            if forwarded { _sinkForwarded += 1 }
        }
        if let error { _sinkErrors += 1; _sinkLastError = error.localizedDescription }
        let now = CFAbsoluteTimeGetCurrent()
        if _sinkStatsSince == 0 { _sinkStatsSince = now }
        guard now - _sinkStatsSince >= 5 else { return }
        logger.info("\(self.device.localizedName, privacy: .public): \(self._sinkConsumed) frames from the sink, \(self._sinkForwarded) forwarded, \(self._sinkErrors) consume errors\(self._sinkErrors > 0 ? " (last: \(self._sinkLastError))" : "", privacy: .public)")
        _sinkConsumed = 0; _sinkForwarded = 0; _sinkErrors = 0; _sinkStatsSince = now
    }

    func stopStreamingSink() {
        if _streamingSinkCounter > 1 {
            _streamingSinkCounter -= 1
        } else {
            _streamingSinkCounter = 0
            _sinkTimer?.cancel()
            _sinkTimer = nil
        }
    }

    // MARK: Helpers

    private func send(_ pixelBuffer: CVPixelBuffer, into stream: virtualcameraStreamSource, at time: CMTime) {
        var sbuf: CMSampleBuffer!
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: Int32(kFrameRate)),
            presentationTimeStamp: time, decodeTimeStamp: .invalid)
        let err = CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: _videoDescription,
            sampleTiming: &timing, sampleBufferOut: &sbuf)
        guard err == 0 else {
            logger.error("sample create err \(err)")
            return
        }
        // Hosted run: there is no system consumer, so hand the frame to the
        // preview delegate instead of the (extension-only) CMIO stream.
        if let hostedDelegate {
            hostedDelegate.virtualCamera(didOutput: sbuf)
            return
        }
        stream.stream.send(
            sbuf, discontinuity: [],
            hostTimeInNanoseconds: UInt64(time.seconds * Double(NSEC_PER_SEC)))
    }

    /// Lazily render a static "waiting for client camera" frame once and reuse it.
    private func placeholderBuffer() -> CVPixelBuffer? {
        if let _placeholderBuffer { return _placeholderBuffer }

        let attrs: NSDictionary = [
            kCVPixelBufferWidthKey: kFrameWidth,
            kCVPixelBufferHeightKey: kFrameHeight,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as NSDictionary,
        ]
        var pb: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, Int(kFrameWidth), Int(kFrameHeight),
            kCVPixelFormatType_32BGRA, attrs, &pb) == kCVReturnSuccess, let pb else {
            return nil
        }

        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }

        let cs = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        if let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(pb),
            width: Int(kFrameWidth), height: Int(kFrameHeight),
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
            space: cs, bitmapInfo: bitmapInfo)
        {
            ctx.setFillColor(CGColor(red: 0.07, green: 0.08, blue: 0.10, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: Int(kFrameWidth), height: Int(kFrameHeight)))

            let text = "MacRDP — waiting for client camera"
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String):
                    CTFontCreateWithName("Helvetica" as CFString, 40, nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                    CGColor(red: 0.6, green: 0.62, blue: 0.66, alpha: 1),
            ]
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: text, attributes: attributes))
            let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
            ctx.textPosition = CGPoint(
                x: (CGFloat(kFrameWidth) - bounds.width) / 2,
                y: (CGFloat(kFrameHeight) - bounds.height) / 2)
            CTLineDraw(line, ctx)
        }

        _placeholderBuffer = pb
        return pb
    }
}

// MARK: - Source stream (consumed by camera clients)

class virtualcameraStreamSource: NSObject, CMIOExtensionStreamSource {

    private(set) var stream: CMIOExtensionStream!
    private let device: CMIOExtensionDevice
    private let _streamFormat: CMIOExtensionStreamFormat

    init(localizedName: String, streamID: UUID, streamFormat: CMIOExtensionStreamFormat,
        device: CMIOExtensionDevice)
    {
        self.device = device
        _streamFormat = streamFormat
        super.init()
        stream = CMIOExtensionStream(
            localizedName: localizedName, streamID: streamID, direction: .source,
            clockType: .hostTime, source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [_streamFormat] }

    var activeFormatIndex: Int = 0 {
        didSet { if activeFormatIndex >= 1 { logger.error("Invalid format index") } }
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration, customSinkExtensionProperty]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws
        -> CMIOExtensionStreamProperties
    {
        let p = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { p.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) {
            p.frameDuration = CMTime(value: 1, timescale: Int32(kFrameRate))
        }
        if properties.contains(customSinkExtensionProperty) {
            // Report "ready" to the host once the source is live so it knows it
            // may begin enqueuing onto the sink.
            let ready = ((device.source as? virtualcameraDeviceSource)?._streamingSourceCounter ?? 0) > 0
            p.setPropertyState(
                CMIOExtensionPropertyState(value: (ready ? "true" : "false") as NSString),
                forProperty: customSinkExtensionProperty)
        }
        return p
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let idx = streamProperties.activeFormatIndex { activeFormatIndex = idx }
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool { true }

    func startStream() throws {
        guard let deviceSource = device.source as? virtualcameraDeviceSource else {
            fatalError("Unexpected source type \(String(describing: device.source))")
        }
        deviceSource.startStreamingSource()
    }

    func stopStream() throws {
        guard let deviceSource = device.source as? virtualcameraDeviceSource else {
            fatalError("Unexpected source type \(String(describing: device.source))")
        }
        deviceSource.stopStreamingSource()
    }
}

// MARK: - Sink stream (written to by the MacRDP host app)

class virtualcameraStreamSink: NSObject, CMIOExtensionStreamSource {

    private(set) var stream: CMIOExtensionStream!
    private let device: CMIOExtensionDevice
    private let _streamFormat: CMIOExtensionStreamFormat
    private var client: CMIOExtensionClient?

    init(localizedName: String, streamID: UUID, streamFormat: CMIOExtensionStreamFormat,
        device: CMIOExtensionDevice)
    {
        self.device = device
        _streamFormat = streamFormat
        super.init()
        stream = CMIOExtensionStream(
            localizedName: localizedName, streamID: streamID, direction: .sink,
            clockType: .hostTime, source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [_streamFormat] }

    var activeFormatIndex: Int = 0 {
        didSet { if activeFormatIndex >= 1 { logger.error("Invalid format index") } }
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration, .streamSinkBufferQueueSize,
         .streamSinkBuffersRequiredForStartup, .streamSinkBufferUnderrunCount,
         .streamSinkEndOfData]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws
        -> CMIOExtensionStreamProperties
    {
        let p = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { p.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) {
            p.frameDuration = CMTime(value: 1, timescale: Int32(kFrameRate))
        }
        if properties.contains(.streamSinkBufferQueueSize) { p.sinkBufferQueueSize = 1 }
        if properties.contains(.streamSinkBuffersRequiredForStartup) {
            p.sinkBuffersRequiredForStartup = 1
        }
        return p
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let idx = streamProperties.activeFormatIndex { activeFormatIndex = idx }
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        self.client = client
        return true
    }

    func startStream() throws {
        guard let deviceSource = device.source as? virtualcameraDeviceSource, let client else {
            fatalError("Unexpected source type \(String(describing: device.source)) or no client")
        }
        deviceSource.startStreamingSink(client: client)
    }

    func stopStream() throws {
        guard let deviceSource = device.source as? virtualcameraDeviceSource else {
            fatalError("Unexpected source type \(String(describing: device.source))")
        }
        deviceSource.stopStreamingSink()
    }
}

// MARK: - Provider

class virtualcameraProviderSource: NSObject, CMIOExtensionProviderSource {

    private(set) var provider: CMIOExtensionProvider!

    /// Live devices keyed by manifest camera id, and the manifest they were
    /// built from. Only touched on `_syncQueue`.
    private var _devices: [String: virtualcameraDeviceSource] = [:]
    private var _manifest = VirtualCameraManifest.empty
    private let _syncQueue = DispatchQueue(label: "com.mac-rdp.rds.virtualcamera.provider.sync")

    /// Non-nil only for in-process (hosted) runs — a single device whose frames
    /// go to the preview delegate instead of a system consumer.
    private(set) var hostedDeviceSource: virtualcameraDeviceSource?
    private var _hosted: Bool { hostedDeviceSource != nil }

    /// - Parameter hostedDelegate: pass non-nil to run in-process for testing
    ///   (no CMIO publish, no manifest); leave nil for the real extension,
    ///   which starts with no devices until the host sets the manifest.
    init(clientQueue: DispatchQueue?, hostedDelegate: VirtualCameraHostedDelegate? = nil) {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)

        if let hostedDelegate {
            let device = virtualcameraDeviceSource(
                id: UUID().uuidString, localizedName: VirtualCameraShared.defaultCameraName)
            device.hostedDelegate = hostedDelegate
            try? provider.addDevice(device.device)
            hostedDeviceSource = device
        }
    }

    // MARK: In-process preview convenience

    /// Start the hosted device's placeholder preview. Hosted mode only.
    func startHostedPreview() { hostedDeviceSource?.startHostedPreview() }

    /// Feed one 1280x720 32BGRA frame to the hosted device. Hosted mode only.
    func feedHosted(_ pixelBuffer: CVPixelBuffer) { hostedDeviceSource?.feedHosted(pixelBuffer) }

    func connect(to client: CMIOExtensionClient) throws {}
    func disconnect(from client: CMIOExtensionClient) {}

    // MARK: Manifest-driven device set

    /// Reconcile the live CMIO devices with the manifest the host set:
    /// add new cameras, drop removed ones, rebuild renamed ones.
    private func resync(to manifest: VirtualCameraManifest) {
        _syncQueue.async { [weak self] in
            guard let self, manifest != self._manifest else { return }
            self._manifest = manifest
            let desired = manifest.cameras
            let desiredIDs = Set(desired.map(\.id))

            // Remove devices no longer wanted.
            for (id, source) in self._devices where !desiredIDs.contains(id) {
                try? self.provider.removeDevice(source.device)
                self._devices[id] = nil
                logger.info("removed virtual camera \(id, privacy: .public)")
            }

            // Add new devices; rebuild on rename.
            for cam in desired {
                if let existing = self._devices[cam.id] {
                    if existing.device.localizedName == cam.name { continue }
                    try? self.provider.removeDevice(existing.device)
                    self._devices[cam.id] = nil
                }
                let source = virtualcameraDeviceSource(id: cam.id, localizedName: cam.name)
                do {
                    try self.provider.addDevice(source.device)
                    self._devices[cam.id] = source
                    logger.info("added virtual camera \(cam.name, privacy: .public)")
                } catch {
                    logger.error("addDevice failed: \(error.localizedDescription)")
                }
            }
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.providerManufacturer, customCamerasProviderProperty]
    }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws
        -> CMIOExtensionProviderProperties
    {
        let p = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) { p.manufacturer = "MacRDP" }
        if properties.contains(customCamerasProviderProperty) {
            let json = _syncQueue.sync { _manifest.json }
            p.setPropertyState(CMIOExtensionPropertyState(value: json as NSString),
                               forProperty: customCamerasProviderProperty)
        }
        return p
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {
        guard let state = providerProperties.propertiesDictionary[customCamerasProviderProperty] else { return }
        guard !_hosted, let json = state.value as? String, let manifest = VirtualCameraManifest(json: json) else {
            logger.error("ignoring a camera list that is not a manifest")
            return
        }
        resync(to: manifest)
    }
}
