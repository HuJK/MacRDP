//
//  AACEncoder.swift
//  MacRDP
//
//  Wraps AVAudioConverter to turn the SCStream's Int16LE stereo PCM
//  into a stream of AAC-LC packets for RDPSND Wave2 PDUs. Used only
//  when mstsc selects WAVE_FORMAT_AAC_MS at activation; the PCM path
//  in DisplayPipeline stays as a fallback for older clients.
//
//  Hardware-accelerated via Apple's built-in AAC encoder on Apple
//  silicon. Each emitted packet covers 1024 PCM samples (~23.2ms at the
//  44.1 kHz RDPSND wire rate), which is the AAC-LC frame size.
//

import Foundation
@preconcurrency import AVFoundation
import os

/// One encoded audio packet + how many PCM input samples it covers.
struct CompressedAudioPacket {
    let data: Data
    let pcmSampleCount: UInt32
}

/// A streaming PCM→compressed audio encoder (AAC, Opus, …) feeding RDPSND.
protocol CompressedAudioEncoder: AnyObject, Sendable {
    /// Feed Int16LE stereo PCM; return any whole packets produced.
    func encode(pcm: Data) -> [CompressedAudioPacket]
}

final class AACEncoder: CompressedAudioEncoder, @unchecked Sendable {

    private let converter: AVAudioConverter
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private let framesPerPacket: Int
    private let sampleRate: Double

    // Diagnostics — log every 2 seconds so we can see if the encoder
    // is steady or bursting under sustained input.
    private let statsLock = NSLock()
    private var statsStartWall: Double = 0
    private var statsLastLogWall: Double = 0
    private var statsInputFrames: Int = 0
    private var statsPacketsOut: Int = 0
    private var statsBytesOut: Int = 0

    /// AAC-LC by default — broadest compatibility with mstsc.
    /// To experiment with AAC-LD / ELD, swap the format ID:
    ///   kAudioFormatMPEG4AAC_LD  → 512 frames/packet, ~20ms delay
    ///   kAudioFormatMPEG4AAC_ELD → 480 frames/packet, ~15ms delay
    /// (Also tweak framesPerPacket accordingly.)
    init(sampleRate: Double = 48000,
         channels: AVAudioChannelCount = 2,
         bitRate: Int = 128_000) throws {

        guard let inFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                           sampleRate: sampleRate,
                                           channels: channels,
                                           interleaved: true) else {
            throw NSError(domain: "MacRDP.aac", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Bad PCM input format"])
        }
        var outDesc = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 1024,
            mBytesPerFrame: 0,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 0,
            mReserved: 0)
        guard let outFormat = AVAudioFormat(streamDescription: &outDesc) else {
            throw NSError(domain: "MacRDP.aac", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Bad AAC output format"])
        }
        guard let conv = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw NSError(domain: "MacRDP.aac", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "AVAudioConverter init failed"])
        }
        conv.bitRate = bitRate
        // High quality / low latency. The hardware encoder ignores quality
        // hints once initialized — these matter only when SW-encoding.
        conv.bitRateStrategy = AVAudioBitRateStrategy_Constant
        self.converter = conv
        self.inputFormat = inFormat
        self.outputFormat = outFormat
        self.framesPerPacket = 1024
        self.sampleRate = sampleRate
    }

    /// Feed one PCM chunk; collect any whole AAC packets the encoder
    /// produces. The encoder buffers partial frames internally, so
    /// chunks smaller than 1024 samples are fine — packets come out as
    /// they're ready.
    func encode(pcm: Data) -> [CompressedAudioPacket] {
        let frameCount = pcm.count / 4   // Int16 stereo = 4 bytes/frame
        if frameCount == 0 { return [] }

        defer { logStats(framesIn: frameCount) }

        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inputFormat,
                                           frameCapacity: AVAudioFrameCount(frameCount)) else {
            return []
        }
        inBuf.frameLength = AVAudioFrameCount(frameCount)
        pcm.withUnsafeBytes { raw in
            if let src = raw.baseAddress,
               let dst = inBuf.int16ChannelData?[0] {
                memcpy(dst, src, pcm.count)
            }
        }

        var packets: [CompressedAudioPacket] = []
        var consumedInput = false

        // Drain the encoder until it tells us "need more input". The
        // converter buffers leftover frames internally between calls.
        while true {
            // Ask for up to 8 packets at a time. AVAudioCompressedBuffer
            // can hold multiple variable-length packets back to back.
            let outBuf = AVAudioCompressedBuffer(format: outputFormat,
                                                  packetCapacity: 8,
                                                  maximumPacketSize: 4096)
            var err: NSError?
            let status = converter.convert(to: outBuf, error: &err) { _, outStatus in
                if consumedInput {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                consumedInput = true
                outStatus.pointee = .haveData
                return inBuf
            }

            if let err {
                LogTo.audioOut.error("AAC convert error: \(String(describing: err))")
                return packets
            }
            if outBuf.packetCount == 0 {
                return packets
            }
            // Extract each variable-length packet using the descriptions.
            if let descs = outBuf.packetDescriptions {
                let base = outBuf.data.assumingMemoryBound(to: UInt8.self)
                for i in 0..<Int(outBuf.packetCount) {
                    let d = descs[i]
                    let bytes = Data(bytes: base.advanced(by: Int(d.mStartOffset)),
                                     count: Int(d.mDataByteSize))
                    packets.append(CompressedAudioPacket(data: bytes,
                                           pcmSampleCount: UInt32(framesPerPacket)))
                    bumpPacketStats(bytes: bytes.count)
                }
            }
            if status == .inputRanDry || status == .endOfStream {
                return packets
            }
        }
    }

    private func logStats(framesIn: Int) {
        statsLock.lock()
        let now = CACurrentMediaTime()
        if statsStartWall == 0 {
            statsStartWall = now
            statsLastLogWall = now
        }
        statsInputFrames += framesIn
        // (statsPacketsOut/statsBytesOut already updated by caller)
        guard now - statsLastLogWall >= 2.0 else {
            statsLock.unlock()
            return
        }
        let wallElapsed = now - statsStartWall
        let packetsPerSec = Double(statsPacketsOut) / wallElapsed
        let kbpsOut = Double(statsBytesOut * 8) / wallElapsed / 1000.0
        let avgBytes = statsPacketsOut > 0 ? statsBytesOut / statsPacketsOut : 0
        let pcmSec = Double(statsInputFrames) / sampleRate
        // pcmSec should track wallElapsed closely (we're real-time);
        // packetsPerSec should be ~sampleRate/1024 (43.07 at 44.1 kHz); kbps
        // should be around our 128k bitRate setting.
        LogTo.audioOut.info("AAC: pcm=\(Int(pcmSec*1000))ms wall=\(Int(wallElapsed*1000))ms pkts=\(self.statsPacketsOut) rate=\(Int(packetsPerSec))/s avg=\(avgBytes)B \(Int(kbpsOut))kbps")
        statsLastLogWall = now
        statsLock.unlock()
    }

    private func bumpPacketStats(bytes: Int) {
        statsLock.lock()
        statsPacketsOut += 1
        statsBytesOut += bytes
        statsLock.unlock()
    }
}
