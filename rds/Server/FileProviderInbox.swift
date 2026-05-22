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
    func register() async {
        let domain = NSFileProviderDomain(
            identifier: domainIdentifier,
            displayName: domainDisplayName)

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

        // Wake the extension so it re-enumerates. Signal BOTH the
        // root container (user-facing tree) AND the working set
        // (framework-level item index). The working set is what
        // backs `getUserVisibleURL` — without re-enumerating it, the
        // framework doesn't learn about our new items and the URL
        // lookup returns nil.
        await signal(.rootContainer)
        await signal(.workingSet)
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

    /// Publish a deterministic 1 MiB test file and register a fetcher
    /// that synthesizes its bytes on demand. No RDP involvement —
    /// purely exercises the FileProvider + XPC plumbing.
    /// Call once at app start. Pasting `~/Library/CloudStorage/<dom>/test1MB.bin`
    /// in Finder should produce a real 1 MiB file via our extension.
    func publishTestFile() async {
        let testID = "test1MB-fixed-id"
        let testFilename = "test1MB.bin"
        let testSize: Int64 = 1024 * 1024

        // Synthetic fetcher: returns `length` bytes of a repeating
        // pattern, starting at `offset`. Pure CPU; no network, no RDP.
        FileProviderXPCService.shared.registerFetcher(
            domainSubdir: subdir
        ) { itemID, offset, length in
            guard itemID == testID else {
                return (nil, NSError(domain: "MacRDP.testFile", code: 404,
                    userInfo: [NSLocalizedDescriptionKey: "no item \(itemID)"]))
            }
            // 1 MiB of incrementing bytes (0,1,2,…,255,0,1,…).
            // Easy to verify by hex-dumping the copied file.
            let want = max(0, min(length, testSize - offset))
            if want == 0 { return (Data(), nil) }
            var data = Data(count: Int(want))
            data.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                for i in 0..<Int(want) {
                    base[i] = UInt8(truncatingIfNeeded: offset + Int64(i))
                }
            }
            return (data, nil)
        }

        do {
            try await publish([PublishItem(
                id: testID,
                filename: testFilename,
                parentID: nil,
                isDirectory: false,
                size: testSize,
                modificationMs: Int64(Date().timeIntervalSince1970 * 1000))])
            Log.clip.info("Test file published: \(testFilename, privacy: .public) (\(testSize, privacy: .public)B)")
        } catch {
            Log.clip.error("Test file publish failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// User-visible URL for an item in this domain. Retries while the
    /// framework ingests the just-published item — `getUserVisibleURL`
    /// returns nil for an item the framework hasn't picked up via its
    /// working-set enumeration. The retry window is ~6 seconds total,
    /// which is enough for the framework to call `enumerateChanges`
    /// on our working-set enumerator after we signal it.
    func userVisibleURL(itemID: String, filename: String) async -> URL? {
        guard let manager else { return nil }
        let id = NSFileProviderItemIdentifier(itemID)
        let delaysMs: [UInt64] = [50, 100, 200, 400, 800, 1600, 2000]
        for delay in delaysMs {
            if let url = try? await manager.getUserVisibleURL(for: id) {
                return url
            }
            try? await Task.sleep(nanoseconds: delay * 1_000_000)
        }
        return try? await manager.getUserVisibleURL(for: id)
    }
}
