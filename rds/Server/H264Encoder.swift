//
//  H264Encoder.swift
//  MacRDP
//
//  VideoToolbox H.264 encoder configured for low-latency RDPGFX use:
//    - hardware acceleration when available
//    - low-latency rate control (infinite GOP, no B-frames)
//    - High profile, CABAC
//    - explicit IDR on demand
//    - AVCC -> Annex-B conversion with SPS/PPS prepended on every IDR
//

import Foundation
@preconcurrency import VideoToolbox
@preconcurrency import CoreMedia
@preconcurrency import CoreVideo
import os

/// Annex-B 4-byte start code prefix.
private let kStartCode: [UInt8] = [0x00, 0x00, 0x00, 0x01]

final class H264Encoder {
    struct Settings: Sendable {
        var width: Int32
        var height: Int32
        var bitrateBitsPerSecond: Int
        var maxKeyFrameInterval: Int
        var maxFps: Int
        /// "required" / "allow" / "disable"
        var hwAcceleration: String
        var dataRateBurstMultiplier: Double
        var dataRateBurstSeconds: Int
        var maxFrameDelayCount: Int
        /// CVPixelBuffer pixel format the encoder is fed. AVC420 capture is
        /// NV12 (VT-native); the hybrid path feeds BGRA (VT converts).
        var pixelFormat: OSType

        static func from(_ video: Config.VideoConfig,
                         width: Int, height: Int,
                         pixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) -> Settings {
            Settings(
                width: Int32(width),
                height: Int32(height),
                bitrateBitsPerSecond: video.bitrateKbps * 1000,
                maxKeyFrameInterval: video.keyframeIntervalFrames,
                maxFps: video.maxFps,
                hwAcceleration: video.hwAcceleration,
                dataRateBurstMultiplier: video.dataRateBurstMultiplier,
                dataRateBurstSeconds: video.dataRateBurstSeconds,
                maxFrameDelayCount: video.maxFrameDelayCount,
                pixelFormat: pixelFormat
            )
        }
    }

    /// Annex-B output. `isIDR` is true on keyframes; in that case
    /// SPS+PPS NALs are already prepended. `userData` is the opaque value
    /// passed to `encode` for this frame (the hybrid path threads its
    /// tile-routing payload through here).
    typealias Output = (Data, _ isIDR: Bool, _ pts: CMTime, _ userData: (any Sendable)?) -> Void

    private let settings: Settings
    private var session: VTCompressionSession?
    private let outputQueue = DispatchQueue(label: "com.macrdp.h264.out",
                                            qos: .userInteractive)
    private let onEncoded: Output

    init(settings: Settings, onEncoded: @escaping Output) throws {
        self.settings = settings
        self.onEncoded = onEncoded
        try createSession()
    }

    deinit {
        invalidate()
    }

    // MARK: - Session lifecycle

    private func createSession() throws {
        // For low-latency RDP GFX we want:
        //   - Hardware (Apple Media Engine) encoder, not the CPU software path
        //   - No frame reordering, no B-frames, no lookahead buffer
        //   - Real-time pacing
        //
        // EnableLowLatencyRateControl historically forces the software
        // encoder on some hardware combos; we omit it and instead drive
        // low latency via MaxFrameDelayCount=1 + RealTime=true.
        var spec: [CFString: Any] = [:]
        switch settings.hwAcceleration {
        case "disable":
            spec[kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder] = kCFBooleanFalse!
        case "allow":
            spec[kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder] = kCFBooleanTrue!
        default:   // "required" or unrecognized → require HW
            spec[kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder] = kCFBooleanTrue!
            spec[kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder] = kCFBooleanTrue!
        }

        let imageBufferAttrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: Int(settings.pixelFormat) as CFNumber
        ]

        var s: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: settings.width,
            height: settings.height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: spec as CFDictionary,
            imageBufferAttributes: imageBufferAttrs as CFDictionary,
            compressedDataAllocator: nil,
            outputCallback: nil,    // we use encode-with-handler below
            refcon: nil,
            compressionSessionOut: &s)
        guard status == noErr, let session = s else {
            throw MacRDPError.encoderInitFailed(osStatus: status)
        }

        VTSessionSetProperty(session,
                             key: kVTCompressionPropertyKey_RealTime,
                             value: kCFBooleanTrue!)
        // Tell the encoder we'd rather have a frame *now* than a slightly
        // smaller one a few ms later. macOS 14+ honours this on the
        // Apple Media Engine.
        if #available(macOS 14.0, *) {
            VTSessionSetProperty(session,
                                 key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality,
                                 value: kCFBooleanTrue!)
        }
        VTSessionSetProperty(session,
                             key: kVTCompressionPropertyKey_ProfileLevel,
                             value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(session,
                             key: kVTCompressionPropertyKey_H264EntropyMode,
                             value: kVTH264EntropyMode_CABAC)
        VTSessionSetProperty(session,
                             key: kVTCompressionPropertyKey_AllowFrameReordering,
                             value: kCFBooleanFalse!)
        VTSessionSetProperty(session,
                             key: kVTCompressionPropertyKey_AverageBitRate,
                             value: settings.bitrateBitsPerSecond as CFNumber)
        VTSessionSetProperty(session,
                             key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
                             value: settings.maxKeyFrameInterval as CFNumber)
        VTSessionSetProperty(session,
                             key: kVTCompressionPropertyKey_ExpectedFrameRate,
                             value: settings.maxFps as CFNumber)
        // Minimum buffer: tell the encoder to emit each frame ASAP without
        // any lookahead. Combined with AllowFrameReordering=false this
        // gives us a strict P-frame pipeline with no held-back frames.
        VTSessionSetProperty(session,
                             key: kVTCompressionPropertyKey_MaxFrameDelayCount,
                             value: settings.maxFrameDelayCount as CFNumber)

        // Hard cap data rate to smooth bursts and keep the network from
        // queueing up keyframes. Bytes/sec averaged over burstSeconds.
        let capBytesPerSec = Int(
            (Double(settings.bitrateBitsPerSecond) * settings.dataRateBurstMultiplier) / 8.0)
        let limits: [Any] = [capBytesPerSec as CFNumber,
                             settings.dataRateBurstSeconds as CFNumber]
        VTSessionSetProperty(session,
                             key: kVTCompressionPropertyKey_DataRateLimits,
                             value: limits as CFArray)

        VTCompressionSessionPrepareToEncodeFrames(session)
        self.session = session

        // Log the actual hw-accel decision.
        var usingHW: CFTypeRef?
        VTSessionCopyProperty(session,
                              key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                              allocator: kCFAllocatorDefault,
                              valueOut: &usingHW)
        let hw = (usingHW as? Bool) ?? false
        Log.encoder.info("H264 session ready \(self.settings.width, privacy: .public)x\(self.settings.height, privacy: .public) @ \(self.settings.maxFps, privacy: .public)fps hw=\(hw, privacy: .public)")
    }

    func invalidate() {
        if let s = session {
            VTCompressionSessionInvalidate(s)
            self.session = nil
        }
    }

    /// Live bitrate update — called from the adaptive-quality path
    /// (Phase 3) when bandwidth autodetect reports a change.
    func setBitrate(bitsPerSecond: Int) {
        guard let s = session else { return }
        VTSessionSetProperty(s,
                             key: kVTCompressionPropertyKey_AverageBitRate,
                             value: bitsPerSecond as CFNumber)
        let cap = bitsPerSecond * 3 / 2 / 8
        let limits: [Any] = [cap as CFNumber, 1 as CFNumber]
        VTSessionSetProperty(s,
                             key: kVTCompressionPropertyKey_DataRateLimits,
                             value: limits as CFArray)
    }

    // MARK: - Encode

    func encode(pixelBuffer: CVPixelBuffer, pts: CMTime,
                forceKeyframe: Bool, userData: (any Sendable)? = nil) throws {
        guard let s = session else {
            throw MacRDPError.encoderInitFailed(osStatus: -1)
        }
        var frameProps: CFDictionary?
        if forceKeyframe {
            frameProps = [
                kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue!
            ] as CFDictionary
        }
        let status = VTCompressionSessionEncodeFrame(
            s,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: frameProps,
            infoFlagsOut: nil
        ) { [weak self] status, _, sample in
            guard status == noErr, let sample else { return }
            self?.outputQueue.async {
                self?.handleEncoded(sample, userData: userData)
            }
        }
        if status != noErr {
            throw MacRDPError.encoderInitFailed(osStatus: status)
        }
    }

    // MARK: - AVCC -> Annex-B

    private func handleEncoded(_ sample: CMSampleBuffer, userData: (any Sendable)?) {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sample) else { return }
        guard let formatDesc = CMSampleBufferGetFormatDescription(sample) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let isIDR = isKeyframe(sample)

        var annexB = Data()
        annexB.reserveCapacity(64 * 1024)

        // On IDR, prepend SPS+PPS as start-code-delimited NALs so a
        // late-joining client can decode without waiting.
        if isIDR {
            for nal in extractParameterSets(formatDesc) {
                annexB.append(contentsOf: kStartCode)
                annexB.append(nal)
            }
        }

        // Convert each AVCC NAL (4-byte big-endian length prefix) into
        // Annex-B (start-code prefix). VT uses 4-byte length by default,
        // but we verify via CMVideoFormatDescriptionGetH264ParameterSetAtIndex.
        let nalLenSize = avccNalLengthSize(formatDesc)

        var totalLen = 0
        var dataPtr: UnsafeMutablePointer<CChar>?
        let status = CMBlockBufferGetDataPointer(
            dataBuffer, atOffset: 0, lengthAtOffsetOut: nil,
            totalLengthOut: &totalLen, dataPointerOut: &dataPtr)
        guard status == kCMBlockBufferNoErr, let dataPtr else { return }

        var offset = 0
        let bytes = UnsafePointer<UInt8>(OpaquePointer(dataPtr))
        while offset + nalLenSize <= totalLen {
            var nalLen: Int = 0
            for i in 0..<nalLenSize {
                nalLen = (nalLen << 8) | Int(bytes[offset + i])
            }
            offset += nalLenSize
            if nalLen <= 0 || offset + nalLen > totalLen { break }
            annexB.append(contentsOf: kStartCode)
            annexB.append(UnsafeBufferPointer(start: bytes + offset, count: nalLen))
            offset += nalLen
        }

        onEncoded(annexB, isIDR, pts, userData)
    }

    private func isKeyframe(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sample, createIfNecessary: false) as? [[CFString: Any]],
              let first = attachments.first else {
            // Single-sample-buffer keyframes: if attachments missing,
            // assume keyframe to be safe.
            return true
        }
        // The DependsOnOthers attachment is FALSE for keyframes.
        if let dependsOnOthers = first[kCMSampleAttachmentKey_DependsOnOthers] as? Bool {
            return !dependsOnOthers
        }
        return false
    }

    private func extractParameterSets(_ fmt: CMVideoFormatDescription) -> [Data] {
        var sets: [Data] = []
        var count = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            fmt, parameterSetIndex: 0,
            parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
        for i in 0..<count {
            var ptr: UnsafePointer<UInt8>?
            var size: Int = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                fmt, parameterSetIndex: i,
                parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            if let ptr, size > 0 {
                sets.append(Data(bytes: ptr, count: size))
            }
        }
        return sets
    }

    private func avccNalLengthSize(_ fmt: CMVideoFormatDescription) -> Int {
        var len: Int32 = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            fmt, parameterSetIndex: 0,
            parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: nil, nalUnitHeaderLengthOut: &len)
        return Int(len > 0 ? len : 4)
    }
}
