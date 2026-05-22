//
//  Permissions.swift
//  MacRDP
//
//  Eager probe of macOS TCC permissions at app launch. Each probe
//  briefly touches the API that requires the permission; if missing,
//  macOS shows its dialog before any client connects. That way users
//  grant permissions once at startup instead of mid-session.
//

import Foundation
import ApplicationServices
@preconcurrency import CoreAudio
import ScreenCaptureKit
import os

enum Permissions {

    /// Probe + prompt for every permission MacRDP will need. Called
    /// from main.swift before the listener starts. Non-blocking —
    /// permissions are async and may not be granted by the time this
    /// returns, but the dialogs will be visible.
    static func probeAllAtLaunch(config: Config) {
        probeAccessibility()
        probeScreenRecording()
        if config.audioOut.enabled {
            probeSystemAudioRecording()
        }
        // AUDIN (client mic → Mac) doesn't capture from a Mac mic — we
        // play received PCM into an output device via AVAudioEngine,
        // which doesn't gate on TCC Microphone. No probe needed.
    }

    // MARK: - Accessibility (CGEvent injection for mouse/keyboard)

    private static func probeAccessibility() {
        // Prompt-style check: AXIsProcessTrustedWithOptions with the
        // kAXTrustedCheckOptionPrompt key shows the dialog if missing.
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as CFString
        let opts: CFDictionary = [key: kCFBooleanTrue!] as CFDictionary
        let granted = AXIsProcessTrustedWithOptions(opts)
        Log.server.info("TCC Accessibility: \(granted ? "GRANTED" : "PENDING/DENIED", privacy: .public)")
    }

    // MARK: - Screen Recording

    private static func probeScreenRecording() {
        // Touching SCShareableContent triggers the Screen Recording
        // prompt the first time. We don't actually need the result —
        // just the side effect of the prompt.
        Task.detached {
            do {
                _ = try await SCShareableContent.current
                Log.server.info("TCC Screen Recording: GRANTED")
            } catch {
                Log.server.notice("TCC Screen Recording: PENDING/DENIED — \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: - System Audio Recording (CATap, macOS 14.2+)

    private static func probeSystemAudioRecording() {
        // Don't actually create a tap at probe time — that's been
        // observed to leave the CoreAudio HAL in a confused state
        // ("HALC_ProxyIOContext: skipping cycle due to overload" +
        // "out of order message" later). The real tap is built when
        // a client connects (AudioOutPipeline.start). If permission
        // is missing the user can grant it via System Settings →
        // Privacy & Security → Screen & System Audio Recording.
        Log.server.info("TCC System Audio Recording: probe deferred to session start")
    }

}
