//
//  AudioInPipeline.swift
//  MacRDP
//
//  Decoded mic PCM frames (from AUDIN, supplied by the FreeRDP bridge)
//  are queued through an AVAudioEngine playback chain whose output
//  device is the user-configured one (typically a loopback driver like
//  BlackHole, so Mac apps can pick up "MacRDP Mic" as an input).
//
//  Phase 5b alternative: ship a system extension that exposes the
//  virtual mic natively. Out of scope for v1.
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
            Log.audioIn.info("audio in disabled by config")
            return
        }

        // Route policy:
        //  - Use config.audioIn.outputDeviceUID if explicitly set.
        //  - Otherwise auto-detect a known loopback driver (BlackHole)
        //    so Mac apps can pick it as their microphone source.
        //  - Otherwise fall back to default output (audible — diagnostic only).
        if let wantedUID = config.audioIn.outputDeviceUID {
            try applyOutputDevice(uid: wantedUID)
            Log.audioIn.info("AUDIN → output device UID=\(wantedUID, privacy: .public)")
        } else if let bh = Self.findLoopbackDevice() {
            try applyOutputDevice(uid: bh.uid)
            Log.audioIn.notice("AUDIN auto-routed to loopback device: \(bh.name, privacy: .public) (UID=\(bh.uid, privacy: .public))")
        } else {
            Log.audioIn.notice("AUDIN: no loopback device (BlackHole/Loopback) detected; mic audio will play on default output. Install BlackHole to route into Mac apps as a virtual mic.")
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
        Log.audioIn.info("Audio in playback ready")
    }

    func stop() {
        player.stop()
        engine.stop()
        engine.reset()
    }

    /// Called by the FreeRDP bridge for each PCM frame received over AUDIN.
    /// pcm is Int16LE interleaved stereo at 48 kHz (or whatever we
    /// negotiated — Phase 5 narrows this once AUDIN format-negotiation
    /// is in place).
    func feedPCM(_ pcm: Data) {
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

    private func applyOutputDevice(uid: String) throws {
        guard let deviceID = Self.findDevice(byUID: uid) else {
            Log.audioIn.error("output device UID \(uid, privacy: .public) not found")
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
            Log.audioIn.error("AudioUnitSetProperty(CurrentDevice) failed: \(status, privacy: .public)")
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
