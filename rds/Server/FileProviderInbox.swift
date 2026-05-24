//
//  FileProviderInbox.swift
//  MacRDP
//
//  Main-app side of the FileProvider integration. Each call to
//  `publish(...)` atomically rewrites a per-domain manifest +
//  associated byte files in the App Group container, then signals
//  the extension to re-enumerate.
//
//  Used by:
//    - ClipboardBridge        → "clipboard" domain (Win→Mac file paste)
//    - (future) RDPDR drives  → "drive-<X>" domains
//

import Foundation
import FileProvider
import os

@MainActor
final class FileProviderInbox {

    /// Stable per-domain identifier — also the App Group subdir name.
    let domainIdentifier: NSFileProviderDomainIdentifier
    let domainDisplayName: String
    let subdir: String

    private var manager: NSFileProviderManager?

    /// Cached XPC connection to the extension (opened via
    /// NSFileProviderService). Lives across publish calls; reopened on
    /// invalidation.
    private var extensionConnection: NSXPCConnection?

    /// Strong reference to the `exportedObject` we set on the
    /// connection — implements `ExtensionToHostProtocol.fetchBytes`.
    private let exporter = HostFileProviderExporter()

    init(domainID: String, displayName: String) {
        self.domainIdentifier = NSFileProviderDomainIdentifier(domainID)
        self.domainDisplayName = displayName
        self.subdir = AppGroupShared.domainSubdir(for: domainID)
    }

    // MARK: - Domain lifecycle

    /// Register the domain with the system. Async because
    /// `NSFileProviderManager.add` is callback-based; we await it so
    /// callers can publish manifests immediately after.
    ///
    /// We FORCE remove-then-add so a stuck "scanCount=0, anchor:empty"
    /// daemon cache (left over from earlier broken extension binaries)
    /// gets wiped — without this, fileproviderd can keep serving an
    /// empty domain even after we publish a fresh manifest.
    /// `hidden` registers the domain without showing it in Finder's
    /// sidebar (still fully functional — storage on disk, paste URLs
    /// resolve). Used for the clipboard staging domain.
    func register(hidden: Bool = false) async {
        let domain = NSFileProviderDomain(
            identifier: domainIdentifier,
            displayName: domainDisplayName)
        domain.isHidden = hidden

        // Pre-add scrub: remove any prior registration of this domain.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            NSFileProviderManager.remove(domain) { error in
                if let error {
                    Log.clip.info("FileProvider domain remove (pre-add): \(String(describing: error), privacy: .public)")
                }
                cont.resume()
            }
        }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            NSFileProviderManager.add(domain) { error in
                if let error = error as NSError? {
                    // "Already exists" is benign — we just keep using
                    // the existing domain. Anything else is logged.
                    if error.domain == NSFileProviderErrorDomain {
                        Log.clip.info("FileProvider domain \(self.domainIdentifier.rawValue, privacy: .public) add returned: \(String(describing: error), privacy: .public)")
                    } else {
                        Log.clip.error("FileProvider domain add failed: \(String(describing: error), privacy: .public)")
                    }
                }
                self.manager = NSFileProviderManager(for: domain)
                // Seed an empty manifest so the extension has
                // something valid to return on the system's initial
                // probe. Without this, the first item(for:) /
                // enumerateItems call before any Windows copy would
                // surface as "FP -1005" errors in the log.
                self.seedEmptyManifestIfNeeded()
                Log.clip.info("FileProvider domain ready: \(self.domainIdentifier.rawValue, privacy: .public)")
                cont.resume()
            }
        }
    }

    /// Write a tiny empty-state manifest at register time so the
    /// extension's first probe (item(for: rootContainer), enumerate,
    /// etc.) has something valid to return. Otherwise the system logs
    /// FP -1005 errors and may invalidate the extension connection
    /// during the first few seconds while we wait for a client copy.
    private func seedEmptyManifestIfNeeded() {
        guard let containerURL = AppGroupShared.containerURL() else { return }
        let domainDir = containerURL.appendingPathComponent(subdir, isDirectory: true)
        try? FileManager.default.createDirectory(at: domainDir, withIntermediateDirectories: true)
        let manifestURL = domainDir.appendingPathComponent("manifest.json")
        if FileManager.default.fileExists(atPath: manifestURL.path) { return }
        let manifest = ClipboardManifest(version: 1,
                                          sessionID: "empty-\(UUID().uuidString)",
                                          items: [])
        if let data = try? JSONEncoder().encode(manifest) {
            try? data.write(to: manifestURL, options: .atomic)
        }
    }

    /// Unregister the domain (call on session/app shutdown).
    func unregister() async {
        let domain = NSFileProviderDomain(
            identifier: domainIdentifier,
            displayName: domainDisplayName)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            NSFileProviderManager.remove(domain) { error in
                if let error {
                    Log.clip.notice("FileProvider domain remove: \(String(describing: error), privacy: .public)")
                }
                cont.resume()
            }
        }
    }

    // MARK: - Manifest publishing

    /// One file's metadata ready for publishing. Bytes are fetched
    /// lazily through XPC when an app actually reads the file via
    /// FileProvider — no need to pre-fetch up front.
    struct PublishItem {
        let id: String            // ManifestItem.id (UUID)
        let filename: String
        let parentID: String?
        let isDirectory: Bool
        let size: Int64           // file size (or 0 for dirs)
        let modificationMs: Int64?
    }

    /// Atomically replace the inbox contents with a new metadata
    /// manifest. Bytes are NOT written — they're fetched lazily over
    /// XPC when an app reads the file. Re-signals the FP extension so
    /// Finder picks up the change immediately.
    func publish(_ items: [PublishItem]) async throws {
        guard let containerURL = AppGroupShared.containerURL() else {
            throw NSError(domain: "MacRDP.inbox", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "App Group container unavailable — entitlement?"])
        }
        let domainDir = containerURL.appendingPathComponent(subdir, isDirectory: true)
        try FileManager.default.createDirectory(at: domainDir, withIntermediateDirectories: true)

        var manifestEntries: [ManifestItem] = []
        manifestEntries.reserveCapacity(items.count)
        for it in items {
            manifestEntries.append(ManifestItem(
                id: it.id,
                filename: it.filename,
                size: it.size,
                parentID: it.parentID,
                isDirectory: it.isDirectory,
                modificationMs: it.modificationMs))
        }

        let manifest = ClipboardManifest(
            version: 1,
            sessionID: UUID().uuidString,
            items: manifestEntries)
        let manifestData = try JSONEncoder().encode(manifest)
        let manifestURL = domainDir.appendingPathComponent("manifest.json")
        try manifestData.write(to: manifestURL, options: .atomic)

        Log.clip.info("Inbox published: domain=\(self.domainIdentifier.rawValue, privacy: .public) items=\(items.count, privacy: .public)")

        // Push the JSON to the extension's in-memory cache via
        // NSFileProviderService. The extension can't read the App Group
        // file directly (TCC denies cross-bundle app-data access for
        // sandboxed FP extensions), so this XPC push is the canonical
        // path.
        await pushManifestToExtension(manifestData)

        // Wake the extension so it re-enumerates. Signal BOTH the
        // root container (user-facing tree) AND the working set
        // (framework-level item index). The working set is what
        // backs `getUserVisibleURL` — without re-enumerating it, the
        // framework doesn't learn about our new items and the URL
        // lookup returns nil.
        await signal(.rootContainer)
        await signal(.workingSet)
    }

    /// Remove the given item ID (and any descendants whose parent
    /// chain points at it) from the manifest, then push the updated
    /// manifest to the extension and re-signal the root container so
    /// Finder drops the now-deleted item from view.
    ///
    /// Used by the lazy-mode resolver when FGDW resolution fails:
    /// the placeholder folder we published on `CB_FORMAT_LIST` is no
    /// longer a useful copy source, so we evict it to discourage
    /// Finder from leaving a stale empty wrapper at the paste
    /// destination.
    func unpublishItem(id: String) async {
        guard let containerURL = AppGroupShared.containerURL() else { return }
        let domainDir = containerURL.appendingPathComponent(subdir, isDirectory: true)
        let manifestURL = domainDir.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let current = try? JSONDecoder().decode(ClipboardManifest.self, from: data) else {
            return
        }
        // Drop the target item and anything whose parent chain leads
        // to it. Build the descendant closure iteratively (works for
        // the typical small placeholder-only manifest; would be
        // O(N²) if ever called on a huge tree but that's not the
        // current use case).
        var toRemove: Set<String> = [id]
        var grew = true
        while grew {
            grew = false
            for it in current.items where !toRemove.contains(it.id) {
                if let p = it.parentID, toRemove.contains(p) {
                    toRemove.insert(it.id); grew = true
                }
            }
        }
        let keptItems = current.items.filter { !toRemove.contains($0.id) }
        // Nothing to do if the item wasn't in the manifest.
        guard keptItems.count != current.items.count else { return }
        let updated = ClipboardManifest(
            version: current.version,
            sessionID: UUID().uuidString,
            items: keptItems)
        guard let newData = try? JSONEncoder().encode(updated) else { return }
        do {
            try newData.write(to: manifestURL, options: .atomic)
        } catch {
            Log.clip.error("unpublishItem: manifest write failed: \(String(describing: error), privacy: .public)")
            return
        }
        Log.clip.info("Inbox unpublished item \(id, privacy: .public) (+\(toRemove.count - 1, privacy: .public) descendants); \(keptItems.count, privacy: .public) item(s) remain")
        await pushManifestToExtension(newData)
        await signal(.rootContainer)
        await signal(.workingSet)
    }

    /// Open (or reuse) the NSFileProviderService XPC connection to our
    /// extension and call `pushManifest` on it. Best-effort: if the
    /// extension isn't up yet (or the framework can't reach it), we
    /// log and continue — the next publish will retry.
    private func pushManifestToExtension(_ data: Data) async {
        do {
            let proxy = try await ensureExtensionProxy()
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                proxy.pushManifest(domainSubdir: self.subdir, data: data) { ok in
                    if !ok {
                        Log.clip.notice("pushManifest returned !ok")
                    }
                    cont.resume()
                }
            }
            Log.clip.info("Pushed manifest to extension via NSFileProviderService (\(data.count, privacy: .public)B)")
        } catch {
            Log.clip.error("pushManifest failed: \(String(describing: error), privacy: .public)")
            // Drop a possibly-broken connection so the next attempt
            // re-opens.
            self.extensionConnection?.invalidate()
            self.extensionConnection = nil
        }
    }

    /// Ensure we have an open XPC connection to the extension's service
    /// source, returning its `HostToExtensionProtocol` remote proxy.
    /// Sets up `exportedObject` so the extension can call back into us
    /// for byte fetches (`fetchBytes`).
    private func ensureExtensionProxy() async throws -> HostToExtensionProtocol {
        if let existing = extensionConnection,
           let proxy = existing.remoteObjectProxy as? HostToExtensionProtocol {
            return proxy
        }
        guard let manager else {
            throw NSError(domain: "MacRDP.inbox", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Manager not initialized — register() not awaited?"])
        }
        let service: NSFileProviderService = try await withCheckedThrowingContinuation { cont in
            manager.getService(named: MacRDPFileProviderServiceName,
                                for: .rootContainer) { svc, err in
                if let err {
                    cont.resume(throwing: err)
                } else if let svc {
                    cont.resume(returning: svc)
                } else {
                    cont.resume(throwing: NSError(
                        domain: "MacRDP.inbox", code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "getService returned nil"]))
                }
            }
        }
        let conn: NSXPCConnection = try await withCheckedThrowingContinuation { cont in
            service.getFileProviderConnection { c, err in
                if let err {
                    cont.resume(throwing: err)
                } else if let c {
                    cont.resume(returning: c)
                } else {
                    cont.resume(throwing: NSError(
                        domain: "MacRDP.inbox", code: 4,
                        userInfo: [NSLocalizedDescriptionKey: "fileProviderConnection nil"]))
                }
            }
        }
        conn.remoteObjectInterface = NSXPCInterface(with: HostToExtensionProtocol.self)
        conn.exportedInterface = NSXPCInterface(with: ExtensionToHostProtocol.self)
        conn.exportedObject = exporter
        conn.invalidationHandler = { [weak self] in
            Log.clip.notice("Extension XPC connection invalidated")
            Task { @MainActor in self?.extensionConnection = nil }
        }
        conn.interruptionHandler = { [weak self] in
            Log.clip.notice("Extension XPC connection interrupted")
            Task { @MainActor in
                self?.extensionConnection?.invalidate()
                self?.extensionConnection = nil
            }
        }
        conn.resume()
        self.extensionConnection = conn
        guard let proxy = conn.remoteObjectProxy as? HostToExtensionProtocol else {
            throw NSError(domain: "MacRDP.inbox", code: 5,
                userInfo: [NSLocalizedDescriptionKey: "remoteObjectProxy doesn't conform to HostToExtensionProtocol"])
        }
        Log.clip.info("Extension XPC connection opened (NSFileProviderService)")
        return proxy
    }

    private func signal(_ container: NSFileProviderItemIdentifier) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            guard let manager else { cont.resume(); return }
            manager.signalEnumerator(for: container) { error in
                if let error {
                    Log.clip.notice("signalEnumerator(\(container.rawValue, privacy: .public)) failed: \(String(describing: error), privacy: .public)")
                }
                cont.resume()
            }
        }
    }

    /// User-visible URL for an item in this domain. Retries while the
    /// framework ingests the just-published item — `getUserVisibleURL`
    /// returns nil for an item the framework hasn't picked up via its
    /// working-set enumeration.
    ///
    /// Budget is generous (~30 s total) because for large folder
    /// copies (40 k items, 6+ MB manifest JSON), the framework has to
    /// (a) call our enumerator, (b) wait for the extension to decode
    /// the manifest, (c) build its own index of every item — that
    /// can easily take 10–20 s the first time on slower Macs. Once
    /// the index is built subsequent lookups are instant.
    func userVisibleURL(itemID: String, filename: String) async -> URL? {
        guard let manager else { return nil }
        let id = NSFileProviderItemIdentifier(itemID)
        // 100, 200, 400, 800, 1600, 2 × 2 s, 5 × 5 s ≈ 32 s total.
        let delaysMs: [UInt64] = [100, 200, 400, 800, 1600, 2000, 2000, 5000, 5000, 5000, 5000, 5000]
        for delay in delaysMs {
            if let url = try? await manager.getUserVisibleURL(for: id) {
                return url
            }
            try? await Task.sleep(nanoseconds: delay * 1_000_000)
        }
        return try? await manager.getUserVisibleURL(for: id)
    }
}
