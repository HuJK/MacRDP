//
//  AudioOutPipeline.swift
//  MacRDP
//
//  Local-mute side-channel for RDP audio. The actual audio capture
//  goes through ScreenCaptureKit (DisplayPipeline.onAudioFrame on
//  macOS 14+ — far more reliable than CATap-on-aggregate-device).
//
//  This class exists *only* to mute the Mac's local speakers while a
//  session is active. We create a CATap with muteBehavior=.muted and
//  no IOProc consumer — its presence alone tells CoreAudio to suppress
//  output on the tapped processes.
//
//  Config flag `audioOut.muteLocalOutput`:
//    "never"        → don't create the tap; Mac plays out loud
//    "whileTapped"  → create tap with .mutedWhenTapped (mute only while
//                     SOMETHING reads from the tap — for our path,
//                     equivalent to "never" since we don't IOProc-read)
//    "always"       → create tap with .muted (always mutes while alive)
//

import Foundation
@preconcurrency import CoreAudio
import os

final class AudioOutPipeline: @unchecked Sendable {
    private let config: Config
    private var tapID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)

    init(config: Config) {
        self.config = config
    }

    deinit {
        destroyTap()
    }

    func start() throws {
        guard config.audioOut.enabled else { return }
        switch config.audioOut.muteLocalOutput {
        case "never":
            Log.audioOut.info("Local mute disabled (Mac plays out loud)")
            return
        case "always":
            try createTap(behavior: .muted)
            Log.audioOut.info("Local Mac audio muted (.muted)")
        default:   // "whileTapped" — kept for backward-compat
            try createTap(behavior: .mutedWhenTapped)
            Log.audioOut.info("Local Mac audio mute=.mutedWhenTapped (mute only while consumer reads)")
        }
    }

    func stop() {
        destroyTap()
    }

    // MARK: - Implementation

    private func createTap(behavior: CATapMuteBehavior) throws {
        let desc = CATapDescription()
        desc.name = "MacRDP Local Mute"
        desc.processes = []        // system-wide
        desc.isPrivate = true
        desc.isMixdown = true
        desc.isMono = false
        desc.muteBehavior = behavior
        desc.isExclusive = false

        var tap: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
        let rc = AudioHardwareCreateProcessTap(desc, &tap)
        guard rc == noErr, tap != AudioObjectID(kAudioObjectUnknown) else {
            Log.audioOut.error("Mute tap create failed: \(rc, privacy: .public)")
            throw MacRDPError.audioPermissionDenied
        }
        self.tapID = tap
    }

    private func destroyTap() {
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            _ = AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }
}
