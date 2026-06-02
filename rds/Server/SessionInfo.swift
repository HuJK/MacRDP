//
//  SessionInfo.swift
//  MacRDP
//
//  Lightweight, Sendable snapshot of a connected session for the menu-bar UI.
//  The role model is here so multi-session (one controller + viewers) can be
//  built later without reworking the surface; today only "control" is created.
//

import Foundation

enum SessionRole: String, Sendable {
    case control   // full input + view
    case viewer    // view-only (future)
}

/// A redirected drive (RDPDR) the client forwarded. `key` is the DriveStore
/// item id used to open it in Finder; `label` is the drive letter / share name.
struct DriveResource: Sendable, Hashable {
    let key: String
    let label: String
}

/// A redirected camera (RDPECAM). `id` is the per-camera virtual-channel name;
/// `name` is the client-supplied label (falls back to the id).
struct CameraResource: Sendable, Hashable {
    let id: String
    let name: String
}

struct SessionInfo: Sendable, Identifiable {
    let id: ObjectIdentifier
    let username: String
    let ip: String
    let role: SessionRole
    /// Resources the client forwarded over RDP, for the menu-bar list.
    let drives: [DriveResource]
    /// Redirected microphones (AUDIN). Today the protocol carries a single
    /// input stream, so this is 0 or 1; modelled as a count for the UI.
    let micCount: Int
    /// Redirected cameras (RDPECAM enumeration).
    let cameras: [CameraResource]
}
