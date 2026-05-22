//
//  ManifestCache.swift
//  fileprovider
//
//  In-memory cache of the per-domain manifest JSON that the host pushes
//  via `HostToExtensionProtocol.pushManifest`. Replaces the App Group
//  file the extension used to read directly — see commit message and
//  `feedback_fp_extension_ipc.md` for why direct reads are blocked.
//
//  Accessed from XPC reply queues and from enumerator threads, so the
//  storage is guarded by NSLock. Decoding is done on read so we can
//  surface JSON errors at the call site.
//

import Foundation
import os

private let log = Logger(subsystem: "com.macrdp.server", category: "fileprovider")

final class ManifestCache {

    static let shared = ManifestCache()

    private let lock = NSLock()
    private var storage: [String: Data] = [:]

    private init() {}

    func set(_ data: Data, domainSubdir: String) {
        lock.lock()
        storage[domainSubdir] = data
        lock.unlock()
        log.info("ManifestCache set \(domainSubdir, privacy: .public) (\(data.count, privacy: .public) bytes)")
    }

    func data(domainSubdir: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return storage[domainSubdir]
    }

    func manifest(domainSubdir: String) -> ClipboardManifest? {
        guard let d = data(domainSubdir: domainSubdir) else { return nil }
        do {
            return try JSONDecoder().decode(ClipboardManifest.self, from: d)
        } catch {
            log.error("ManifestCache decode failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
