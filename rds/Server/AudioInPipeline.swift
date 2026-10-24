//
//  AudioInPipeline.swift
//  MacRDP
//
//  Decoded mic PCM frames (from AUDIN, supplied by the FreeRDP bridge)
//  are queued through an AVAudioEngine playback chain whose output
//  device is, in order: the configured one; MacRDP's own driver
//  (scripts/build-audio-driver.sh), whose hidden "MacRDP Microphone Feed"
//  output comes back out of its "MacRDP Microphone" input for Mac apps;
//  or another loopback driver such as BlackHole.
//

import Foundation
@preconcurrency import AVFoundation
@preconcurrency import CoreAudio
import os

final class AudioInPipeline: @unchecked Sendable {
    private let config: Config

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var playbackFormat: AVAudioFormat?
    /// Converts a client mic that negotiated anything but 48 kHz stereo;
    /// rebuilt if the negotiated format changes.
    private var converter: (rate: Int, channels: Int, resampler: PCMResampler)?

    /// Optional observer of the decoded mic PCM (Int16LE interleaved), used to
    /// drive the menu-bar live spectrum. Set/cleared and invoked on the same
    /// (MainActor) path as `feedPCM`, so no extra synchronization is needed.
    /// nil = no tap (zero added work).
    var pcmTap: ((Data) -> Void)?

    init(config: Config) {
        self.config = config
    }

    func start() throws {
        guard config.audioIn.enabled else {
            LogTo.audioIn.info("audio in disabled by config")
            return
        }

        // Route policy:
        //  - Use config.audioIn.outputDeviceUID if explicitly set.
        //  - Otherwise MacRDP's own driver, if installed: its hidden feed
        //    device, which Mac apps hear as "MacRDP Microphone".
        //  - Otherwise auto-detect a known loopback driver (BlackHole)
        //    so Mac apps can pick it as their microphone source.
        //  - Otherwise fall back to default output (audible — diagnostic only).
        let wantedUID = config.audioIn.outputDeviceUID
        if !wantedUID.isEmpty {
            try applyOutputDevice(uid: wantedUID)
            LogTo.audioIn.info("AUDIN → output device UID=\(wantedUID)")
        } else if Self.findDevice(byUID: Self.macRDPFeedUID) != nil {
            try applyOutputDevice(uid: Self.macRDPFeedUID)
            LogTo.audioIn.notice("AUDIN routed to MacRDP's virtual microphone (\"MacRDP Microphone\")")
        } else if let bh = Self.findLoopbackDevice() {
            try applyOutputDevice(uid: bh.uid)
            LogTo.audioIn.notice("AUDIN auto-routed to loopback device: \(bh.name) (UID=\(bh.uid))")
        } else {
            LogTo.audioIn.notice("AUDIN: no virtual microphone (MacRDP's audio driver, BlackHole, Loopback) found; mic audio will play on default output. Install MacRDP's audio driver to route it into Mac apps.")
        }

        // Standard 48 kHz / Int16 / stereo for now; later we negotiate.
        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                      sampleRate: 48_000, channels: 2,
                                      interleaved: true) else {
            throw MacRDPError.audioPermissionDenied
        }
        self.playbackFormat = fmt

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: fmt)

        try engine.start()
        player.play()
        LogTo.audioIn.info("Audio in playback ready")
    }

    func stop() {
        player.stop()
        engine.stop()
        engine.reset()
    }

    /// Called by the FreeRDP bridge for each PCM frame received over AUDIN:
    /// Int16LE interleaved in the format the client picked from the ones the
    /// bridge offers (48 or 44.1 kHz, 16 kHz, stereo or mono). Everything
    /// past this point (playback, the spectrum tap) gets 48 kHz stereo.
    func feedPCM(_ input: Data, sampleRate: Int, channels: Int) {
        var pcm = input
        if sampleRate != 48_000 || channels != 2 {
            if converter?.rate != sampleRate || converter?.channels != channels {
                guard let rs = try? PCMResampler(from: Double(sampleRate), to: 48_000,
                                                 channels: AVAudioChannelCount(channels),
                                                 outChannels: 2) else {
                    LogTo.audioIn.error("no converter for AUDIN \(sampleRate) Hz/\(channels) ch; dropping")
                    return
                }
                converter = (sampleRate, channels, rs)
                LogTo.audioIn.notice("AUDIN \(sampleRate) Hz/\(channels) ch → converting to 48 kHz stereo")
            }
            pcm = converter!.resampler.process(input)
        }
        if let pcmTap, !pcm.isEmpty { pcmTap(pcm) }
        guard let fmt = playbackFormat, !pcm.isEmpty else { return }
        let bytesPerFrame = Int(fmt.streamDescription.pointee.mBytesPerFrame)
        let frameCount = pcm.count / max(1, bytesPerFrame)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: fmt,
                                            frameCapacity: AVAudioFrameCount(frameCount)) else {
            return
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        pcm.withUnsafeBytes { src in
            if let baseAddr = src.baseAddress {
                memcpy(buffer.audioBufferList.pointee.mBuffers.mData,
                       baseAddr, pcm.count)
            }
        }
        player.scheduleBuffer(buffer, completionHandler: nil)
    }

    // MARK: - Output-device routing

    /// UID of the hidden output device of MacRDP's driver (BlackHole's
    /// "<kDriver_Name>_2_UID", see scripts/build-audio-driver.sh).
    static let macRDPFeedUID = "MacRDP_2_UID"

    private func applyOutputDevice(uid: String) throws {
        guard let deviceID = Self.findDevice(byUID: uid) else {
            LogTo.audioIn.error("output device UID \(uid) not found")
            return
        }
        let outputUnit = engine.outputNode.audioUnit
        guard let outputUnit else { return }
        var did = deviceID
        let status = AudioUnitSetProperty(
            outputUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0,
            &did,
            UInt32(MemoryLayout<AudioDeviceID>.size))
        if status != noErr {
            LogTo.audioIn.error("AudioUnitSetProperty(CurrentDevice) failed: \(status)")
        }
    }

    /// Walk Core Audio's device list and return the first device whose
    /// name looks like a "loopback" / virtual driver (BlackHole, Loopback,
    /// Soundflower, VB-Cable). Returned as (UID, name) so we can log it.
    private static func findLoopbackDevice() -> (uid: String, name: String)? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
                AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr,
              size > 0 else { return nil }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else {
            return nil
        }

        let needles = ["blackhole", "loopback", "soundflower", "vb-cable", "vb-audio"]
        for did in ids {
            guard let name = stringProp(did, kAudioDevicePropertyDeviceNameCFString)?.lowercased() else { continue }
            if needles.contains(where: { name.contains($0) }) {
                if let uid = stringProp(did, kAudioDevicePropertyDeviceUID) {
                    let displayName = stringProp(did, kAudioDevicePropertyDeviceNameCFString) ?? name
                    return (uid, displayName)
                }
            }
        }
        return nil
    }

    private static func stringProp(_ device: AudioDeviceID,
                                   _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var ref: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<CFString>.size)
        let rc = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &ref)
        if rc == noErr, let s = ref?.takeRetainedValue() as String? { return s }
        return nil
    }

    private static func findDevice(byUID uid: String) -> AudioDeviceID? {
        // Translation finds hidden devices too (MacRDP's feed device), which
        // kAudioHardwarePropertyDevices leaves out.
        var translate = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var cfUID = uid as CFString
        var translated = AudioDeviceID(kAudioObjectUnknown)
        var translatedSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        if AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &translate,
                                      UInt32(MemoryLayout<CFString>.size), &cfUID,
                                      &translatedSize, &translated) == noErr,
           translated != kAudioObjectUnknown {
            return translated
        }

        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
        guard sizeStatus == noErr else { return nil }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        let listStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceIDs)
        guard listStatus == noErr else { return nil }

        for did in deviceIDs {
            var uidAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var uidRef: Unmanaged<CFString>?
            var uidSize = UInt32(MemoryLayout<CFString>.size)
            let st = AudioObjectGetPropertyData(did, &uidAddr, 0, nil, &uidSize, &uidRef)
            if st == noErr, let s = uidRef?.takeRetainedValue() as String?,
               s == uid {
                return did
            }
        }
        return nil
    }
}
