//
//  VirtualCameraSinkClient.swift
//  MacRDP (rds host)
//
//  Host side of the virtual camera. For each redirected RDP client webcam the
//  host creates one `VirtualCameraSink`:
//
//    1. registers the camera in the manifest, which goes to the extension as a
//       property of its CMIO provider (it then publishes a matching device),
//    2. discovers that CMIO device via the CoreMediaIO HAL (retrying, because
//       the extension is launched on-demand and the device appears async),
//    3. opens the device's *sink* stream and feeds it 1280x720 32BGRA frames.
//
//  Feed decoded webcam frames with `send(_:)`. The extension forwards them to
//  whatever app is reading the camera (Zoom / FaceTime / …).
//

import CoreMediaIO
import CoreVideo
import Foundation
import os.log

private let log = Logger(subsystem: "com.mac-rdp.rds", category: "VirtualCamera")

/// Frames fed to a sink must match the extension's stream format.
enum VirtualCameraFormat {
    static let width = 1280
    static let height = 720
    static let pixelFormat = kCVPixelFormatType_32BGRA
}

// MARK: - Manifest registry (shared list of cameras the extension should show)

/// The cameras the extension should show, kept here and pushed whole to the
/// extension's provider on every change. Only the host writes it.
enum VirtualCameraRegistry {
    private static let lock = NSLock()
    private static var manifest = VirtualCameraManifest.empty
    private static var lastSeen: [String] = []   // plug-ins the last lookup saw, for the log
    private static var usableAfter: Date?

    /// The activation request finished. CoreMediaIO lists its plug-ins once
    /// per process, at first use, and never picks up an extension the system
    /// swapped in later (each new build replaces the installed one at launch).
    /// So stay off CMIO until then, and a moment longer for the new copy to
    /// register; sinks retry until it's usable.
    static func extensionActivated() {
        lock.lock()
        usableAfter = Date().addingTimeInterval(5)
        lock.unlock()
    }

    static func add(id: String, name: String) {
        mutate { cameras in
            if let idx = cameras.firstIndex(where: { $0.id == id }) {
                cameras[idx].name = name
            } else {
                cameras.append(.init(id: id, name: name))
            }
        }
    }

    static func remove(id: String) {
        mutate { $0.removeAll { $0.id == id } }
    }

    /// Push the current list to the extension again: it starts with no devices
    /// whenever the system (re)launches it. False while it isn't running.
    @discardableResult
    static func publish() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return send(manifest)
    }

    private static func mutate(_ body: (inout [VirtualCameraManifest.Camera]) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body(&manifest.cameras)
        if !send(manifest) {
            log.info("virtual camera extension not running yet (CMIO objects \(lastSeen, privacy: .public)); cameras published once it is")
        }
    }

    private static func send(_ manifest: VirtualCameraManifest) -> Bool {
        guard let usableAfter, Date() >= usableAfter else {
            lastSeen = ["extension not activated yet"]
            return false
        }
        guard let provider = providerObject() else { return false }
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(fourCC(VirtualCameraShared.camerasPropertyToken)),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var json = manifest.json as CFString
        let status = CMIOObjectSetPropertyData(
            provider, &address, 0, nil, UInt32(MemoryLayout<CFString>.size), &json)
        if status != noErr { log.error("setting the virtual camera list failed: \(status)") }
        return status == noErr
    }

    /// The extension's provider: the CMIO plug-in object with its bundle id.
    private static func providerObject() -> CMIOObjectID? {
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOObjectPropertyOwnedObjects),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else {
            return nil
        }
        var objects = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &address, 0, nil, size, &used, &objects) == noErr else {
            return nil
        }
        var bundleAddress = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOPlugInPropertyBundleID),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var seen: [String] = []
        let found = objects.first { object in
            guard CMIOObjectHasProperty(object, &bundleAddress) else { seen.append("\(object):-"); return false }
            var bundleID: CFString = "" as CFString
            let status = CMIOObjectGetPropertyData(
                object, &bundleAddress, 0, nil, UInt32(MemoryLayout<CFString>.size), &used, &bundleID)
            seen.append("\(object):\(status == noErr ? bundleID as String : "err \(status)")")
            return status == noErr && bundleID as String == VirtualCameraShared.extensionBundleID
        }
        lastSeen = seen
        return found
    }

    private static func fourCC(_ s: String) -> UInt32 {
        s.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }
}

// MARK: - One virtual camera feed

final class VirtualCameraSink {

    let id: String
    let name: String

    private let queue = DispatchQueue(label: "com.mac-rdp.rds.virtualcamera.sink")
    private var deviceID: CMIOObjectID = 0
    private var sinkStreamID: CMIOStreamID = 0
    private var simpleQueue: CMSimpleQueue?
    private var formatDescription: CMFormatDescription?
    private var discoveryTimer: DispatchSourceTimer?
    private var misses = 0
    private var sentFrames = 0, droppedFrames = 0
    private var statsSince: CFAbsoluteTime = 0
    private var started = false

    /// Called on the main queue when the first app starts, or the last one
    /// stops, reading this camera (the extension's in-use notifications), so
    /// the client webcam is pulled only while it's used.
    var onInUseChanged: ((Bool) -> Void)?

    /// - Parameters:
    ///   - id: stable UUID string (becomes the CMIO device UID). Reuse the same
    ///         value for the same logical client camera across reconnects.
    ///   - name: user-visible name shown in the camera picker.
    init(id: String = UUID().uuidString, name: String = VirtualCameraShared.defaultCameraName) {
        self.id = id.uppercased()  // CMIO reports device UIDs uppercased
        self.name = name
    }

    /// Publish the camera and begin connecting to its sink. Safe to call once.
    func start() {
        queue.async { [self] in
            guard !started else { return }
            started = true
            observeInUse()   // before the device exists, so no transition is missed
            VirtualCameraRegistry.add(id: id, name: name)
            beginDiscovery()
        }
    }

    /// Remove the camera and tear down the sink.
    func stop() {
        queue.async { [self] in
            guard started else { return }
            started = false
            discoveryTimer?.cancel()
            discoveryTimer = nil
            if sinkStreamID != 0 {
                CMIODeviceStopStream(deviceID, sinkStreamID)
            }
            simpleQueue = nil
            deviceID = 0
            sinkStreamID = 0
            CFNotificationCenterRemoveEveryObserver(
                CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque())
            VirtualCameraRegistry.remove(id: id)
        }
    }

    private func observeInUse() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        for inUse in [true, false] {
            CFNotificationCenterAddObserver(
                center, observer,
                { _, observer, name, _, _ in
                    guard let observer, let name else { return }
                    let sink = Unmanaged<VirtualCameraSink>.fromOpaque(observer).takeUnretainedValue()
                    let inUse = (name.rawValue as String).contains(".inUse.")
                    DispatchQueue.main.async { sink.onInUseChanged?(inUse) }
                },
                VirtualCameraShared.inUseNotification(id: id, inUse: inUse) as CFString,
                nil, .deliverImmediately)
        }
    }

    /// Feed one frame. `pixelBuffer` must be `VirtualCameraFormat` (1280x720
    /// 32BGRA). Dropped silently if the sink isn't connected yet or is full.
    func send(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime? = nil) {
        queue.async { [self] in
            guard let simpleQueue else { return }

            // Drop rather than block when the extension hasn't drained yet.
            if CMSimpleQueueGetCount(simpleQueue) >= CMSimpleQueueGetCapacity(simpleQueue) {
                noteFrame(sent: false)
                return
            }
            // Described from the buffer itself: a bare 1280x720 BGRA
            // description doesn't match buffers carrying colour attachments
            // (decoded frames do), and the sample buffer is then refused
            // (kCMSampleBufferError_InvalidMediaFormat).
            if formatDescription.map({ !CMVideoFormatDescriptionMatchesImageBuffer($0, imageBuffer: pixelBuffer) }) ?? true {
                formatDescription = nil
                CMVideoFormatDescriptionCreateForImageBuffer(
                    allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
                    formatDescriptionOut: &formatDescription)
            }
            guard let formatDescription else { return }

            let pts = presentationTime ?? CMClockGetTime(CMClockGetHostTimeClock())
            var timing = CMSampleTimingInfo(
                duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
            var sampleBuffer: CMSampleBuffer?
            let status = CMSampleBufferCreateForImageBuffer(
                allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, dataReady: true,
                makeDataReadyCallback: nil, refcon: nil, formatDescription: formatDescription,
                sampleTiming: &timing, sampleBufferOut: &sampleBuffer)
            guard status == noErr, let sampleBuffer else {
                log.error("CMSampleBufferCreateForImageBuffer failed: \(status)")
                return
            }
            // The queue takes ownership; the extension releases on consume.
            let ref = Unmanaged.passRetained(sampleBuffer).toOpaque()
            if CMSimpleQueueEnqueue(simpleQueue, element: ref) != noErr {
                Unmanaged<CMSampleBuffer>.fromOpaque(ref).release()
                noteFrame(sent: false)
            } else {
                noteFrame(sent: true)
            }
        }
    }

    /// Frames into the sink vs dropped (queue full), logged every 5 s.
    private func noteFrame(sent: Bool) {
        if sent { sentFrames += 1 } else { droppedFrames += 1 }
        let now = CFAbsoluteTimeGetCurrent()
        if statsSince == 0 { statsSince = now }
        guard now - statsSince >= 5 else { return }
        log.info("virtual camera \(self.name, privacy: .public): \(self.sentFrames) frames to the sink in \(String(format: "%.0f", now - self.statsSince)) s, \(self.droppedFrames) dropped (queue full)")
        sentFrames = 0; droppedFrames = 0; statsSince = now
    }

    // MARK: Discovery

    private func beginDiscovery() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(500))
        timer.setEventHandler { [weak self] in self?.tryConnect() }
        discoveryTimer = timer
        timer.resume()
    }

    private func tryConnect() {
        guard started, simpleQueue == nil else { return }
        guard let device = Self.findDevice(uid: id) else {
            // Not published yet. Every few seconds, hand the extension the
            // list again, in case it was (re)launched after we sent it.
            misses += 1
            if misses % 6 == 0 { VirtualCameraRegistry.publish() }
            return
        }
        guard let sink = Self.sinkStream(of: device) else { return }

        let queuePtr = UnsafeMutablePointer<Unmanaged<CMSimpleQueue>?>.allocate(capacity: 1)
        defer { queuePtr.deallocate() }
        let copyStatus = CMIOStreamCopyBufferQueue(
            sink, { _, _, _ in }, nil, queuePtr)
        guard copyStatus == noErr, let cmQueue = queuePtr.pointee else {
            log.error("CMIOStreamCopyBufferQueue failed: \(copyStatus)")
            return
        }
        guard CMIODeviceStartStream(device, sink) == noErr else {
            log.error("CMIODeviceStartStream failed")
            return
        }

        deviceID = device
        sinkStreamID = sink
        simpleQueue = cmQueue.takeUnretainedValue()
        discoveryTimer?.cancel()
        discoveryTimer = nil
        log.info("connected to virtual camera sink \(self.name)")
    }

    // MARK: CoreMediaIO HAL helpers

    private static func findDevice(uid: String) -> CMIOObjectID? {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var dataSize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(
            CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, &dataSize) == noErr,
            dataSize > 0 else { return nil }

        let count = Int(dataSize) / MemoryLayout<CMIOObjectID>.size
        var devices = [CMIOObjectID](repeating: 0, count: count)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, dataSize, &used,
            &devices) == noErr else { return nil }

        for device in devices {
            if deviceUID(device)?.uppercased() == uid { return device }
        }
        return nil
    }

    private static func deviceUID(_ device: CMIOObjectID) -> String? {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceUID),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var dataSize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(device, &address, 0, nil, &dataSize) == noErr else {
            return nil
        }
        var uid: CFString = "" as CFString
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(
            device, &address, 0, nil, dataSize, &used, &uid) == noErr else { return nil }
        return uid as String
    }

    /// Our device exposes [source, sink]; the sink is the last stream that
    /// isn't also the first.
    private static func sinkStream(of device: CMIOObjectID) -> CMIOStreamID? {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyStreams),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var dataSize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(device, &address, 0, nil, &dataSize) == noErr else {
            return nil
        }
        let count = Int(dataSize) / MemoryLayout<CMIOStreamID>.size
        guard count >= 2 else { return nil }  // need both source and sink
        var streams = [CMIOStreamID](repeating: 0, count: count)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(
            device, &address, 0, nil, dataSize, &used, &streams) == noErr else { return nil }
        return streams.last
    }
}
