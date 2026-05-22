//
//  SharedManifest.swift
//  MacRDP — shared between rds (main app) and fileprovider (extension).
//
//  Both targets need to read/write this model + locate the App Group
//  container, so we keep a verbatim copy in each. If you change one,
//  update the other (or move both targets onto a single file via a
//  shared Xcode group).
//
//  The App Group container is the contract between the main app and
//  the extension: main app writes manifest.json + items/<id>.bin,
//  extension reads them on `fetchContents` / `enumerateItems`.
//

import Foundation
import os

// MARK: - On-disk manifest schema

/// JSON document at `<app-group>/<domain-id>/manifest.json`. One per
/// FileProvider domain we register (e.g. one for the clipboard inbox,
/// one per redirected RDP drive).
struct ClipboardManifest: Codable {
    let version: Int
    /// Changes on every fresh publish — drives the sync anchor so
    /// Finder re-enumerates after a new Windows copy event.
    let sessionID: String
    let items: [ManifestItem]
}

/// One file or directory in the manifest. `id` is the rawValue of the
/// corresponding `NSFileProviderItemIdentifier`; `parentID == nil`
/// means the item is at the domain root.
struct ManifestItem: Codable, Equatable {
    let id: String
    let filename: String
    let size: Int64
    let parentID: String?
    let isDirectory: Bool
    /// Unix epoch milliseconds, optional.
    let modificationMs: Int64?
}

// MARK: - App Group layout

enum AppGroupShared {
    /// Must match BOTH:
    ///   - rds.entitlements          → com.apple.security.application-groups
    ///   - fileprovider.entitlements → com.apple.security.application-groups
    static let identifier = "group.com.mac-rdp.rds"

    /// Subdirectory naming so multiple domains (clipboard, redirected
    /// drives) don't collide. The caller picks a stable string per
    /// domain — see `domainSubdir(for:)` below for canonical names.
    static let clipboardDomainID  = "clipboard"
    static let driveDomainPrefix  = "drive-"     // suffixed with the drive name

    /// `~/Library/Group Containers/group.com.mac-rdp.rds/`.
    static func containerURL() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    /// Per-domain subdirectory inside the App Group container.
    static func domainDir(for domainSubdir: String) -> URL? {
        containerURL()?.appendingPathComponent(domainSubdir, isDirectory: true)
    }

    static func manifestURL(domainSubdir: String) -> URL? {
        domainDir(for: domainSubdir)?.appendingPathComponent("manifest.json")
    }

    /// `<domain>/items/<id>.bin` — the raw bytes for a file item.
    static func itemBytesURL(domainSubdir: String, itemID: String) -> URL? {
        domainDir(for: domainSubdir)?
            .appendingPathComponent("items", isDirectory: true)
            .appendingPathComponent(itemID + ".bin")
    }

    /// Extension reads manifest via `ManifestCache` (host pushes over
    /// the NSFileProviderService XPC); the App Group container is no
    /// longer used directly because TCC blocks the sandboxed extension
    /// from reading it. The main app keeps `loadManifest` for its own
    /// reads — see `MacRDP/rds/Shared/SharedManifest.swift`.

    /// Map an `NSFileProviderDomain.identifier` to the App Group
    /// subdirectory that holds its manifest + bytes. The extension
    /// receives a `NSFileProviderDomain` at init; this lets it find
    /// the right files without hardcoding domain identifiers.
    static func domainSubdir(for domainIdentifierRaw: String) -> String {
        // Currently 1:1 — we use the raw identifier as the subdir name.
        // The main app passes well-known strings like "clipboard"
        // or "drive-<letter>" so the layout is predictable.
        domainIdentifierRaw
    }
}
