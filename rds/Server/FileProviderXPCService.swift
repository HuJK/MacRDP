//
//  FileProviderXPCService.swift
//  MacRDP
//
//  Host side of the NSFileProviderService channel. Holds the per-domain
//  fetcher closures (clipboard + future RDPDR drives) and exposes them
//  to the extension via the `ExtensionToHostProtocol` interface, which
//  the extension calls into during `fetchContents`.
//
//  The actual NSXPCConnection is opened by `FileProviderInbox` after
//  publishing each manifest (via `NSFileProviderManager.getService(...)`),
//  and the host sets THIS object as the connection's `exportedObject`.
//

import Foundation
import os

@MainActor
final class FileProviderXPCService: NSObject {

    static let shared = FileProviderXPCService()

    /// Per-domain byte fetchers keyed by subdir name. The shared bridge
    /// (FileProviderInbox) reads this from the XPC reply queue without
    /// a MainActor hop, so we use `nonisolated(unsafe)` + NSLock.
    nonisolated(unsafe) private let fetchersLock = NSLock()
    nonisolated(unsafe) private var fetchers:
        [String: (String, Int64, Int64) async -> (Data?, NSError?)] = [:]

    /// Register a per-domain byte fetcher. The closure is invoked on
    /// the XPC reply queue; implementations are responsible for any
    /// MainActor hops they need internally.
    func registerFetcher(domainSubdir: String,
                         _ fetcher: @escaping (_ itemID: String,
                                                _ offset: Int64,
                                                _ length: Int64) async -> (Data?, NSError?)) {
        fetchersLock.lock()
        fetchers[domainSubdir] = fetcher
        fetchersLock.unlock()
        Log.clip.info("XPC fetcher registered for domain '\(domainSubdir, privacy: .public)'")
    }

    func unregisterFetcher(domainSubdir: String) {
        fetchersLock.lock()
        fetchers.removeValue(forKey: domainSubdir)
        fetchersLock.unlock()
    }

    nonisolated fileprivate func handleFetch(domainSubdir: String,
                                             itemID: String,
                                             offset: Int64,
                                             length: Int64,
                                             reply: @escaping (Data?, NSError?) -> Void) {
        let fetcher: ((String, Int64, Int64) async -> (Data?, NSError?))?
        fetchersLock.lock()
        fetcher = fetchers[domainSubdir]
        fetchersLock.unlock()
        guard let fetcher else {
            reply(nil, NSError(domain: "MacRDP.xpc", code: 404,
                userInfo: [NSLocalizedDescriptionKey: "No fetcher for domain \(domainSubdir)"]))
            return
        }
        Task.detached {
            let (data, err) = await fetcher(itemID, offset, length)
            reply(data, err)
        }
    }
}

/// `exportedObject` for the NSFileProviderService connection on the
/// host side — the extension calls into this when it needs bytes.
final class HostFileProviderExporter: NSObject, ExtensionToHostProtocol {

    nonisolated func fetchBytes(domainSubdir: String,
                                itemID: String,
                                offset: Int64,
                                length: Int64,
                                reply: @escaping (Data?, NSError?) -> Void) {
        FileProviderXPCService.shared.handleFetch(
            domainSubdir: domainSubdir,
            itemID: itemID,
            offset: offset,
            length: length,
            reply: reply)
    }
}
