//
//  PCMResampler.swift
//  MacRDP
//
//  Streaming sample-rate conversion of the SCStream's Int16LE stereo PCM
//  (48 kHz) down to the RDPSND wire rate for the PCM and AAC formats
//  (MACRDP_RDPSND_WIRE_RATE, 44.1 kHz). mstsc plays a 48 kHz stream as if
//  it were 44.1 kHz — pitch 8.8% low, its buffer growing ~88 ms per second
//  until the drift detector drops audio — so we never send it 48 kHz PCM
//  or AAC. Opus is unaffected and stays at 48 kHz.
//
//  AVAudioConverter keeps its filter state between calls, so feeding SCK's
//  chunks one at a time yields one continuous stream; each call returns
//  whatever output is ready, which can be a frame or two off chunk × ratio.
//

import Foundation
@preconcurrency import AVFoundation
import os

final class PCMResampler: @unchecked Sendable {

    private let converter: AVAudioConverter
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat
    private let bytesPerFrame: Int
    private let ratio: Double

    init(from inRate: Double, to outRate: Double,
         channels: AVAudioChannelCount = 2) throws {
        guard let inFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: inRate,
                                           channels: channels, interleaved: true),
              let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: outRate,
                                            channels: channels, interleaved: true),
              let conv = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw NSError(domain: "MacRDP.resampler", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "AVAudioConverter \(Int(inRate)) → \(Int(outRate)) Hz init failed"])
        }
        self.converter = conv
        self.inputFormat = inFormat
        self.outputFormat = outFormat
        self.bytesPerFrame = Int(inFormat.streamDescription.pointee.mBytesPerFrame)
        self.ratio = outRate / inRate
    }

    /// Convert one chunk of Int16LE interleaved PCM at the input rate.
    /// Returns the output-rate frames ready so far (possibly empty).
    func process(_ pcm: Data) -> Data {
        let frames = pcm.count / bytesPerFrame
        guard frames > 0,
              let inBuf = AVAudioPCMBuffer(pcmFormat: inputFormat,
                                           frameCapacity: AVAudioFrameCount(frames)),
              let outBuf = AVAudioPCMBuffer(pcmFormat: outputFormat,
                                            frameCapacity: AVAudioFrameCount(Double(frames) * ratio) + 64)
        else { return Data() }
        inBuf.frameLength = AVAudioFrameCount(frames)
        pcm.withUnsafeBytes { raw in
            if let src = raw.baseAddress, let dst = inBuf.int16ChannelData?[0] {
                memcpy(dst, src, frames * bytesPerFrame)
            }
        }

        var consumedInput = false
        var err: NSError?
        _ = converter.convert(to: outBuf, error: &err) { _, outStatus in
            if consumedInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumedInput = true
            outStatus.pointee = .haveData
            return inBuf
        }
        if let err {
            LogTo.audioOut.error("Resample error: \(String(describing: err))")
            return Data()
        }
        guard let out = outBuf.int16ChannelData?[0] else { return Data() }
        return Data(bytes: out, count: Int(outBuf.frameLength) * bytesPerFrame)
    }
}
