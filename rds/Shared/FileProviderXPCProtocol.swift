//
//  FileProviderXPCProtocol.swift
//  MacRDP — shared between rds (main app) and fileprovider (extension).
//
//  IPC between the FileProvider extension and the main app. Uses
//  NSFileProviderService rather than a Mach service or App Group file:
//
//    * App Group reads from the extension are TCC-blocked
//      (kTCCServiceSystemPolicyAppData; the com.apple.fileprovider-nonui
//      extension point disallows the consent prompt, so it's a hard
//      deny without user-granted Full Disk Access).
//    * Non-sandboxed host apps can't register App Group-prefixed Mach
//      services for the sandboxed extension to look up.
//
//  NSFileProviderService bypasses both: the framework gives us a
//  cross-sandbox NSXPCConnection that the extension exposes and the
//  host opens via `NSFileProviderManager.getService(named:for:)`.
//
//  The single connection carries traffic in BOTH directions:
//    host → ext:  pushManifest()       (manifest publishing)
//    ext  → host: fetchBytes()         (lazy byte fetch on read)
//
//  We use two separate protocols so the interface on each side is
//  precisely what it exports.
//
//  Duplicate in both targets (rds/Shared/ and fileprovider/) — keep in
//  lockstep.
//

import Foundation
import FileProvider

/// Service name advertised by the extension and looked up by the host
/// via `NSFileProviderManager.getService(named:for:)`. Must match on
/// both sides.
public let MacRDPFileProviderServiceName =
    NSFileProviderServiceName("com.mac-rdp.clipboard.service")

/// Methods on the EXTENSION, called by the HOST.
@objc(MacRDPHostToExtensionProtocol)
public protocol HostToExtensionProtocol {

    /// Push the current manifest JSON for one domain into the
    /// extension's in-memory cache. Triggered by every
    /// `FileProviderInbox.publish` call on the host side.
    func pushManifest(domainSubdir: String,
                      data: Data,
                      reply: @escaping (Bool) -> Void)

    /// Cheap liveness probe — host can call this to verify the
    /// connection survived a sandbox / XPC restart.
    func ping(reply: @escaping (Bool) -> Void)
}

/// Methods on the HOST, called by the EXTENSION.
@objc(MacRDPExtensionToHostProtocol)
public protocol ExtensionToHostProtocol {

    /// Ask the host to fetch a range of bytes for one manifest item.
    /// Invoked when an app reads a file inside our FileProvider domain
    /// via `fetchContents`. `domainSubdir` lets one host vend bytes
    /// for multiple FileProvider domains (clipboard + RDPDR drives).
    func fetchBytes(domainSubdir: String,
                    itemID: String,
                    offset: Int64,
                    length: Int64,
                    reply: @escaping (Data?, NSError?) -> Void)

    /// Ask the host for the immediate children of a container. Lets
    /// the extension lazy-enumerate large folder trees instead of
    /// eagerly receiving a multi-MB manifest at copy time.
    ///
    /// `containerID` is either the empty string (= top-level / root
    /// container) or a manifest item id. Reply data is a JSON array
    /// of `ManifestItem` (the same encoding `pushManifest` uses for
    /// its `items` field).
    func enumerateChildren(domainSubdir: String,
                           containerID: String,
                           reply: @escaping (Data?, NSError?) -> Void)

    /// Trigger the lazy resolver for the item AND block until it has
    /// finished. After this returns the host has either populated the
    /// session's tree (success) or marked it failed (no tree).
    /// `reply` is `true` if the item now exists, `false` if the
    /// resolver failed — extension uses the boolean to decide
    /// between returning real metadata or NSFileProviderError.noSuchItem.
    /// Items that don't belong to any lazy session reply true
    /// immediately (no resolver needed).
    func resolveItem(domainSubdir: String,
                     itemID: String,
                     reply: @escaping (Bool, NSError?) -> Void)

    // MARK: Write path (RDPDR drives; clipboard replies unsupported)

    /// Open `path` on the drive for writing (create or truncate), returning
    /// an opaque file handle the extension uses for the following chunked
    /// writes. `path` is the backslash item id.
    func openWrite(domainSubdir: String,
                   path: String,
                   reply: @escaping (NSNumber?, NSError?) -> Void)

    /// Write one chunk at `offset` to a handle from `openWrite`.
    func writeChunk(domainSubdir: String,
                    fileID: NSNumber,
                    offset: Int64,
                    data: Data,
                    reply: @escaping (NSError?) -> Void)

    /// Finish a write session (closes the client file handle).
    func closeWrite(domainSubdir: String,
                    fileID: NSNumber,
                    reply: @escaping (NSError?) -> Void)

    /// Create a directory at `path` (backslash item id).
    func createDirectory(domainSubdir: String,
                         path: String,
                         reply: @escaping (NSError?) -> Void)

    /// Delete the file or directory at `path`.
    func deleteItem(domainSubdir: String,
                    path: String,
                    isDirectory: Bool,
                    reply: @escaping (NSError?) -> Void)

    /// Rename / move from `oldPath` to `newPath` (both backslash item ids).
    func renameItem(domainSubdir: String,
                    oldPath: String,
                    newPath: String,
                    reply: @escaping (NSError?) -> Void)
}
