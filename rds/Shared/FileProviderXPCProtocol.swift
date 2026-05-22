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
}
