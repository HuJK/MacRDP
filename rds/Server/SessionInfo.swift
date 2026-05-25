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

struct SessionInfo: Sendable, Identifiable {
    let id: ObjectIdentifier
    let username: String
    let ip: String
    let role: SessionRole
}
