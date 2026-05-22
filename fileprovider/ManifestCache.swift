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
    /// Cached decoded form — without this, every enumerator /
    /// item(for:) call re-decodes the full JSON (e.g. 6 MB for a
    /// 39 k-file folder copy), which dominates the framework's
    /// indexing latency and blows past `userVisibleURL`'s timeout.
    private var decodedCache: [String: ClipboardManifest] = [:]

    private init() {}

    /// Ingest a freshly-pushed manifest from the host. We MERGE
    /// instead of replacing so items from a previous clipboard
    /// session aren't evicted while an in-flight paste is still
    /// resolving them. The most recent session wins for any item ID
    /// the host pushes again.
    func set(_ data: Data, domainSubdir: String) {
        do {
            let incoming = try JSONDecoder().decode(ClipboardManifest.self, from: data)
            // Update sessionID/version to incoming. Merge items by id.
            lock.lock()
            var byID: [String: ManifestItem] = [:]
            if let existing = decodedCache[domainSubdir] {
                byID.reserveCapacity(existing.items.count + incoming.items.count)
                for it in existing.items { byID[it.id] = it }
            }
            for it in incoming.items { byID[it.id] = it }
            let merged = ClipboardManifest(version: incoming.version,
                                            sessionID: incoming.sessionID,
                                            items: Array(byID.values))
            decodedCache[domainSubdir] = merged
            // storage[] is only used for back-compat / first-time decode
            // paths; not strictly needed once decodedCache is populated
            // but keep it consistent.
            storage[domainSubdir] = data
            lock.unlock()
            log.info("ManifestCache merged \(incoming.items.count, privacy: .public) item(s) (total: \(merged.items.count, privacy: .public))")
        } catch {
            log.error("ManifestCache set: decode failed, falling back to raw store: \(String(describing: error), privacy: .public)")
            lock.lock()
            storage[domainSubdir] = data
            decodedCache.removeValue(forKey: domainSubdir)
            lock.unlock()
        }
    }

    func data(domainSubdir: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return storage[domainSubdir]
    }

    /// Merge a freshly-fetched batch of children into the decoded
    /// cache for a domain. Used by the lazy enumerator when it asks
    /// the host for a sub-folder's contents via XPC.
    func merge(items: [ManifestItem], domainSubdir: String) {
        lock.lock()
        var current = decodedCache[domainSubdir]
            ?? ClipboardManifest(version: 1,
                                  sessionID: "lazy-\(UUID().uuidString)",
                                  items: [])
        // Replace any existing entry with the same id, then append
        // anything new. O(n+m), fine for per-folder batches.
        var byID = Dictionary(uniqueKeysWithValues: current.items.map { ($0.id, $0) })
        for it in items { byID[it.id] = it }
        current = ClipboardManifest(version: current.version,
                                     sessionID: current.sessionID,
                                     items: Array(byID.values))
        decodedCache[domainSubdir] = current
        lock.unlock()
    }

    /// All items currently known by the extension for this domain.
    /// Filtered by the enumerator into per-container slices.
    func items(domainSubdir: String) -> [ManifestItem] {
        lock.lock()
        defer { lock.unlock() }
        return decodedCache[domainSubdir]?.items ?? []
    }

    func manifest(domainSubdir: String) -> ClipboardManifest? {
        lock.lock()
        if let cached = decodedCache[domainSubdir] {
            lock.unlock()
            return cached
        }
        let raw = storage[domainSubdir]
        lock.unlock()
        guard let raw else { return nil }
        let t0 = DispatchTime.now().uptimeNanoseconds
        do {
            let m = try JSONDecoder().decode(ClipboardManifest.self, from: raw)
            let ms = (DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
            log.info("ManifestCache decoded \(m.items.count, privacy: .public) items in \(ms, privacy: .public)ms")
            lock.lock()
            decodedCache[domainSubdir] = m
            lock.unlock()
            return m
        } catch {
            log.error("ManifestCache decode failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
