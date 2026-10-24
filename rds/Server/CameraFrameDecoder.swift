//
//  CameraFrameDecoder.swift
//  MacRDP
//
//  A redirected client camera's H.264, turned into frames for the virtual
//  camera: decoded with VideoToolbox and scaled (letterboxed) to the
//  extension's 1280x720 32BGRA.
//
//  H264SampleBuilder is shared with the camera view: each RDPECAM sample is
//  one Annex-B access unit, and its slices (often several) must travel as one
//  length-prefixed (AVCC) CMSampleBuffer — one buffer per slice decodes as
//  broken frames.
//

import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

struct H264SampleBuilder {
    private var sps: [UInt8]?
    private var pps: [UInt8]?
    private(set) var formatDescription: CMFormatDescription?

    /// The access unit as one sample buffer, or nil before the first SPS/PPS
    /// (or for a sample without slices). Picks up new parameter sets on the way.
    mutating func sampleBuffer(for annexB: Data) -> CMSampleBuffer? {
        var avcc: [UInt8] = []
        var newParams = false
        annexB.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let b = raw.bindMemory(to: UInt8.self)
            Self.forEachNAL(b) { nal in
                guard let first = nal.first else { return }
                switch first & 0x1F {
                case 7: sps = Array(nal); newParams = true
                case 8: pps = Array(nal); newParams = true
                case 1, 5:   // slices: 4-byte big-endian length + NAL
                    let len = UInt32(nal.count)
                    avcc += [UInt8(len >> 24), UInt8((len >> 16) & 0xFF), UInt8((len >> 8) & 0xFF), UInt8(len & 0xFF)]
                    avcc += nal
                default: break   // SEI / AUD / etc.
                }
            }
        }
        if newParams { rebuildFormat() }
        guard let formatDescription, !avcc.isEmpty else { return nil }

        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: avcc.count,
                blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                offsetToData: 0, dataLength: avcc.count, flags: 0,
                blockBufferOut: &block) == kCMBlockBufferNoErr, let block,
              CMBlockBufferReplaceDataBytes(
                with: avcc, blockBuffer: block, offsetIntoDestination: 0,
                dataLength: avcc.count) == kCMBlockBufferNoErr else { return nil }
        var sample: CMSampleBuffer?
        var sizes = [avcc.count]
        guard CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault, dataBuffer: block,
                formatDescription: formatDescription, sampleCount: 1,
                sampleTimingEntryCount: 0, sampleTimingArray: nil,
                sampleSizeEntryCount: 1, sampleSizeArray: &sizes,
                sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }

    private mutating func rebuildFormat() {
        guard let sps, let pps else { return }
        var fmt: CMFormatDescription?
        let status = sps.withUnsafeBufferPointer { sp in
            pps.withUnsafeBufferPointer { pp in
                [sp.baseAddress!, pp.baseAddress!].withUnsafeBufferPointer { ptrs in
                    [sp.count, pp.count].withUnsafeBufferPointer { lens in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault, parameterSetCount: 2,
                            parameterSetPointers: ptrs.baseAddress!,
                            parameterSetSizes: lens.baseAddress!,
                            nalUnitHeaderLength: 4, formatDescriptionOut: &fmt)
                    }
                }
            }
        }
        if status == noErr { formatDescription = fmt }
    }

    /// Walk Annex-B NAL units (3- or 4-byte start codes).
    private static func forEachNAL(_ b: UnsafeBufferPointer<UInt8>,
                                   _ body: (UnsafeBufferPointer<UInt8>) -> Void) {
        let n = b.count
        func startLen(_ p: Int) -> Int {
            if p + 3 <= n, b[p] == 0, b[p + 1] == 0, b[p + 2] == 1 { return 3 }
            if p + 4 <= n, b[p] == 0, b[p + 1] == 0, b[p + 2] == 0, b[p + 3] == 1 { return 4 }
            return 0
        }
        var i = 0, nalStart = -1
        while i < n {
            let sc = startLen(i)
            if sc > 0 {
                if nalStart >= 0, i > nalStart { body(UnsafeBufferPointer(rebasing: b[nalStart..<i])) }
                i += sc
                nalStart = i
            } else {
                i += 1
            }
        }
        if nalStart >= 0, nalStart < n { body(UnsafeBufferPointer(rebasing: b[nalStart..<n])) }
    }
}

/// Decodes one camera's samples on its own queue and hands 1280x720 32BGRA
/// frames to `onFrame` (on that queue) while `forwardsFrames` is on.
///
/// Feed it every sample of the stream, used or not: the client sends its
/// parameter sets and keyframe only when the stream starts, so a decoder that
/// joins later (another viewer started the stream) has nothing to decode.
final class CameraFrameDecoder: @unchecked Sendable {

    private let queue = DispatchQueue(label: "com.mac-rdp.rds.camera.decode")
    private let onFrame: (CVPixelBuffer) -> Void
    private let forwardLock = NSLock()
    private var _forwardsFrames = false
    /// Hand decoded frames to `onFrame` (scaled); off = decode only.
    var forwardsFrames: Bool {
        get { forwardLock.lock(); defer { forwardLock.unlock() }; return _forwardsFrames }
        set { forwardLock.lock(); _forwardsFrames = newValue; forwardLock.unlock() }
    }
    private var builder = H264SampleBuilder()
    private var session: VTDecompressionSession?
    private var sessionFormat: CMFormatDescription?
    private var transfer: VTPixelTransferSession?
    private var pool: CVPixelBufferPool?
    private var failures = 0

    init(onFrame: @escaping (CVPixelBuffer) -> Void) {
        self.onFrame = onFrame
    }

    deinit {
        if let session { VTDecompressionSessionInvalidate(session) }
        if let transfer { VTPixelTransferSessionInvalidate(transfer) }
    }

    func decode(_ annexB: Data) {
        queue.async { [self] in
            stats.samples += 1
            defer { logStats() }
            guard let sample = builder.sampleBuffer(for: annexB),
                  let fmt = builder.formatDescription, makeSession(for: fmt), let session else {
                stats.unusable += 1
                return
            }
            let status = VTDecompressionSessionDecodeFrame(
                session, sampleBuffer: sample, flags: [], infoFlagsOut: nil
            ) { [self] status, _, image, _, _ in
                guard status == noErr, let image else { stats.lastError = status; stats.errors += 1; return }
                stats.decoded += 1
                guard forwardsFrames else { return }
                if let frame = scaled(image) { stats.forwarded += 1; onFrame(frame) } else { stats.unscaled += 1 }
            }
            if status != noErr {
                failures += 1
                if failures == 1 || failures % 100 == 0 {
                    LogTo.session.error("Camera decode failed (\(status)), \(self.failures) so far")
                }
            }
        }
    }

    /// Per-5 s counts, logged while frames are forwarded (or failing).
    private struct Stats {
        var samples = 0, unusable = 0, decoded = 0, errors = 0, forwarded = 0, unscaled = 0
        var lastError: OSStatus = 0
        var since = CFAbsoluteTimeGetCurrent()
    }
    private var stats = Stats()

    private func logStats() {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - stats.since >= 5 else { return }
        if stats.forwarded > 0 || stats.errors > 0 || stats.unscaled > 0 || forwardsFrames {
            LogTo.session.notice("Camera decoder: \(self.stats.samples) samples, \(self.stats.unusable) without parameter sets, \(self.stats.decoded) decoded, \(self.stats.errors) errors (last \(self.stats.lastError)), \(self.stats.forwarded) forwarded, \(self.stats.unscaled) not scaled")
        }
        stats = Stats(since: now)
    }

    /// (Re)create the decoder when the stream's parameter sets change.
    private func makeSession(for fmt: CMFormatDescription) -> Bool {
        if session != nil, let sessionFormat, CMFormatDescriptionEqual(fmt, otherFormatDescription: sessionFormat) {
            return true
        }
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var s: VTDecompressionSession?
        guard VTDecompressionSessionCreate(
                allocator: kCFAllocatorDefault, formatDescription: fmt, decoderSpecification: nil,
                imageBufferAttributes: attrs as CFDictionary, outputCallback: nil,
                decompressionSessionOut: &s) == noErr, let s else {
            LogTo.session.error("Camera decoder: VTDecompressionSessionCreate failed")
            return false
        }
        session = s
        sessionFormat = fmt
        return true
    }

    /// The decoded frame in the virtual camera's size, letterboxed.
    private func scaled(_ image: CVPixelBuffer) -> CVPixelBuffer? {
        let w = VirtualCameraFormat.width, h = VirtualCameraFormat.height
        if CVPixelBufferGetWidth(image) == w, CVPixelBufferGetHeight(image) == h,
           CVPixelBufferGetPixelFormatType(image) == VirtualCameraFormat.pixelFormat {
            return image
        }
        if transfer == nil {
            var t: VTPixelTransferSession?
            guard VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &t) == noErr,
                  let t else { return nil }
            VTSessionSetProperty(t, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Letterbox)
            transfer = t
        }
        if pool == nil {
            let attrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: VirtualCameraFormat.pixelFormat,
                kCVPixelBufferWidthKey: w, kCVPixelBufferHeightKey: h,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ]
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &pool)
        }
        var out: CVPixelBuffer?
        guard let pool, let transfer,
              CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &out) == kCVReturnSuccess,
              let out, VTPixelTransferSessionTransferImage(transfer, from: image, to: out) == noErr
        else { return nil }
        return out
    }
}
