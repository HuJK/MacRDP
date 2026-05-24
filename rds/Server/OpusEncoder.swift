//
//  OpusEncoder.swift
//  MacRDP
//
//  Wraps AVAudioConverter to turn the SCStream's Int16LE stereo PCM into a
//  stream of Opus packets for RDPSND. Mirrors AACEncoder; uses Apple's
//  AudioToolbox Opus encoder (kAudioFormatOpus). Engaged only when the client
//  selects WAVE_FORMAT_OPUS (FreeRDP clients built with Opus support) — mstsc
//  doesn't advertise Opus, so it falls back to PCM/AAC in negotiation.
//
//  20 ms frames @ 48 kHz = 960 samples per packet.
//

import Foundation
@preconcurrency import AVFoundation
import os

final class OpusEncoder: CompressedAudioEncoder, @unchecked Sendable {

    private let converter: AVAudioConverter
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private let framesPerPacket: Int

    init(sampleRate: Double = 48000,
         channels: AVAudioChannelCount = 2,
         bitRate: Int = 96_000,
         framesPerPacket: Int = 480) throws {   // 10 ms @ 48 kHz

        guard let inFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                           sampleRate: sampleRate,
                                           channels: channels,
                                           interleaved: true) else {
            throw NSError(domain: "MacRDP.opus", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Bad PCM input format"])
        }
        var outDesc = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatOpus,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(framesPerPacket),
            mBytesPerFrame: 0,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 0,
            mReserved: 0)
        guard let outFormat = AVAudioFormat(streamDescription: &outDesc) else {
            throw NSError(domain: "MacRDP.opus", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Bad Opus output format"])
        }
        guard let conv = AVAudioConverter(from: inFormat, to: outFormat) else {
            // No system Opus encoder available.
            throw NSError(domain: "MacRDP.opus", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "AVAudioConverter (Opus) init failed"])
        }
        conv.bitRate = bitRate
        self.converter = conv
        self.inputFormat = inFormat
        self.outputFormat = outFormat
        self.framesPerPacket = framesPerPacket
    }

    func encode(pcm: Data) -> [CompressedAudioPacket] {
        let frameCount = pcm.count / 4   // Int16 stereo = 4 bytes/frame
        if frameCount == 0 { return [] }

        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inputFormat,
                                           frameCapacity: AVAudioFrameCount(frameCount)) else {
            return []
        }
        inBuf.frameLength = AVAudioFrameCount(frameCount)
        pcm.withUnsafeBytes { raw in
            if let src = raw.baseAddress, let dst = inBuf.int16ChannelData?[0] {
                memcpy(dst, src, pcm.count)
            }
        }

        var packets: [CompressedAudioPacket] = []
        var consumedInput = false
        while true {
            let outBuf = AVAudioCompressedBuffer(format: outputFormat,
                                                 packetCapacity: 8,
                                                 maximumPacketSize: 4096)
            var err: NSError?
            let status = converter.convert(to: outBuf, error: &err) { _, outStatus in
                if consumedInput { outStatus.pointee = .noDataNow; return nil }
                consumedInput = true
                outStatus.pointee = .haveData
                return inBuf
            }
            if let err {
                Log.audioOut.error("Opus convert error: \(String(describing: err), privacy: .public)")
                return packets
            }
            if outBuf.packetCount == 0 { return packets }
            if let descs = outBuf.packetDescriptions {
                let base = outBuf.data.assumingMemoryBound(to: UInt8.self)
                for i in 0..<Int(outBuf.packetCount) {
                    let d = descs[i]
                    let bytes = Data(bytes: base.advanced(by: Int(d.mStartOffset)),
                                     count: Int(d.mDataByteSize))
                    packets.append(CompressedAudioPacket(data: bytes,
                                                         pcmSampleCount: UInt32(framesPerPacket)))
                }
            }
            if status == .inputRanDry || status == .endOfStream { return packets }
        }
    }
}
