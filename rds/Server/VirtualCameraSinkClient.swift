//
//  VirtualCameraSinkClient.swift
//  MacRDP (rds host)
//
//  Host side of the virtual camera. For each redirected RDP client webcam the
//  host creates one `VirtualCameraSink`:
//
//    1. registers the camera in the shared App Group manifest and wakes the
//       extension (which then publishes a matching CMIO device),
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

/// Serializes read-modify-write of the shared manifest across all sinks in this
/// process. Only the host writes it.
enum VirtualCameraRegistry {
    private static let lock = NSLock()

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

    private static func mutate(_ body: (inout [VirtualCameraManifest.Camera]) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        var manifest = VirtualCameraManifest.load()
        body(&manifest.cameras)
        do {
            try manifest.save()
            VirtualCameraShared.postDidChange()
        } catch {
            log.error("failed to write virtual camera manifest: \(error.localizedDescription)")
        }
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
    private var started = false

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
            VirtualCameraRegistry.remove(id: id)
        }
    }

    /// Feed one frame. `pixelBuffer` must be `VirtualCameraFormat` (1280x720
    /// 32BGRA). Dropped silently if the sink isn't connected yet or is full.
    func send(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime? = nil) {
        queue.async { [self] in
            guard let simpleQueue, let formatDescription else { return }

            // Drop rather than block when the extension hasn't drained yet.
            if CMSimpleQueueGetCount(simpleQueue) >= CMSimpleQueueGetCapacity(simpleQueue) {
                return
            }

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
            }
        }
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
        guard let device = Self.findDevice(uid: id) else { return }  // not published yet
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

        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, codecType: VirtualCameraFormat.pixelFormat,
            width: Int32(VirtualCameraFormat.width), height: Int32(VirtualCameraFormat.height),
            extensions: nil, formatDescriptionOut: &formatDescription)

        deviceID = device
        sinkStreamID = sink
        simpleQueue = cmQueue.takeUnretainedValue()
        discoveryTimer?.cancel()
        discoveryTimer = nil
        log.info("connected to virtual camera sink \(self.name, privacy: .public)")
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
