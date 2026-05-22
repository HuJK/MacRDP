//
//  PermissionGate.swift
//  MacRDP
//
//  Models the TCC permissions MacRDP needs at runtime. Each entry can
//  report its grant status without prompting the user, and knows the
//  System Settings deep-link URL to open. PermissionPromptView reads
//  these to render the Chrome-Remote-Desktop-style consent flow.
//

import AppKit
import ApplicationServices
import CoreGraphics
import ScreenCaptureKit
import Foundation
import os

struct PermissionRequirement: Identifiable {
    enum Kind {
        case accessibility
        case screenRecording
    }
    let id: Kind
    let title: String
    let description: String
    let settingsURL: URL

    /// Polled by the UI. MUST be cheap and side-effect-free — no prompts.
    func isGranted() -> Bool {
        switch id {
        case .accessibility:
            // AXIsProcessTrusted is the no-prompt variant.
            return AXIsProcessTrusted()
        case .screenRecording:
            // CGPreflightScreenCaptureAccess returns Bool without prompting.
            return CGPreflightScreenCaptureAccess()
        }
    }

    /// Trigger the macOS prompting API once. macOS uses this call as the
    /// signal to REGISTER our app with TCC — until we call it (or call
    /// the underlying protected API), our app simply does not appear in
    /// System Settings → Privacy. The user clicks "Allow Later" in the
    /// system dialog; our own gate UI then takes over and guides them
    /// to flip the switch in Settings.
    ///
    /// Safe to call repeatedly — second invocations are no-ops on
    /// granted permissions, and on denied ones just refresh the entry.
    func registerWithTCCIfNeeded() {
        switch id {
        case .accessibility:
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            let opts: CFDictionary = [key: kCFBooleanTrue!] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
        case .screenRecording:
            _ = CGRequestScreenCaptureAccess()
        }
    }
}

enum PermissionGate {

    /// The full set we need. UI iterates this; whatever isn't granted
    /// is shown in the prompt. System Audio Capture rides the Screen
    /// Recording TCC entry on macOS 14+, so it doesn't need its own row.
    static let all: [PermissionRequirement] = [
        PermissionRequirement(
            id: .accessibility,
            title: "Accessibility",
            description: "Inject mouse and keyboard events from the connected client.",
            settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!),
        PermissionRequirement(
            id: .screenRecording,
            title: "Screen & System Audio Recording",
            description: "Capture the Mac desktop and system audio to forward over RDP.",
            settingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!),
    ]

    /// Snapshot the currently-missing requirements. Used by AppDelegate
    /// to decide whether to show the prompt at all.
    static func missing() -> [PermissionRequirement] {
        all.filter { !$0.isGranted() }
    }
}
