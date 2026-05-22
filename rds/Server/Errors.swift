//
//  Errors.swift
//  MacRDP
//

import Foundation

enum MacRDPError: Error, CustomStringConvertible {
    case configNotFound(String)
    case configParseFailure(String)
    case bindFailure(port: UInt16, underlying: Error)
    case missingResizeHook
    case resizeHookFailed(reason: String)
    case capturePermissionDenied
    case accessibilityPermissionDenied
    case audioPermissionDenied
    case encoderInitFailed(osStatus: Int32)
    case bridgeFailed(rc: Int32)
    case freerdpUnavailable
    case notImplementedYet(String)

    var description: String {
        switch self {
        case .configNotFound(let p):
            return "Config file not found at \(p)"
        case .configParseFailure(let r):
            return "Config parse error: \(r)"
        case .bindFailure(let port, let err):
            return "Failed to bind tcp/\(port): \(err)"
        case .missingResizeHook:
            return "Client requested a resize but no resize_hook is configured"
        case .resizeHookFailed(let r):
            return "Resize hook failed: \(r)"
        case .capturePermissionDenied:
            return "Screen Recording permission is required. Grant it in System Settings → Privacy & Security → Screen Recording, then restart."
        case .accessibilityPermissionDenied:
            return "Accessibility permission is required to inject input. Grant it in System Settings → Privacy & Security → Accessibility, then restart."
        case .audioPermissionDenied:
            return "System Audio Recording permission is required. Grant it in System Settings → Privacy & Security → Microphone (System Audio), then restart."
        case .encoderInitFailed(let s):
            return "VideoToolbox encoder init failed (OSStatus=\(s))"
        case .bridgeFailed(let rc):
            return "FreeRDP bridge call failed (rc=\(rc))"
        case .freerdpUnavailable:
            return "FreeRDP backend not yet wired in (Phase 0b)."
        case .notImplementedYet(let what):
            return "Not implemented yet: \(what)"
        }
    }
}
