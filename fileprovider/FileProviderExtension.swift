//
//  FileProviderExtension.swift
//  fileprovider
//
//  Read-only NSFileProviderReplicatedExtension. Manifest lives in
//  `ManifestCache` (in-memory, pushed by the host via XPC). Byte
//  fetches call back into the host over the same NSFileProviderService
//  connection. The App Group container is no longer used directly —
//  see `feedback_fp_extension_ipc.md` for why.
//

import FileProvider
import Foundation
import os

private let log = Logger(subsystem: "com.macrdp.server", category: "fileprovider")

final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension, NSFileProviderServicing {

    let domain: NSFileProviderDomain
    let domainSubdir: String

    // Strong references to enumerators we've vended. Without this, ARC
    // can drop the enumerator the moment enumerator(for:) returns —
    // before the framework's XPC marshaling actually invokes
    // enumerateItems/enumerateChanges on it — and Finder ends up with
    // an empty directory.
    private let enumeratorsLock = NSLock()
    private var enumerators: [NSFileProviderItemIdentifier: FileProviderEnumerator] = [:]

    // The single NSFileProviderServiceSource we vend for this domain.
    // Held strongly so its NSXPCListeners + accepted host connections
    // stay alive across enumerator / fetchContents calls.
    private let serviceSource: ClipboardServiceSource

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        self.domainSubdir = AppGroupShared.domainSubdir(for: domain.identifier.rawValue)
        self.serviceSource = ClipboardServiceSource(domainSubdir: self.domainSubdir)
        super.init()
        log.info("FileProviderExtension init domain=\(domain.identifier.rawValue, privacy: .public) subdir=\(self.domainSubdir, privacy: .public)")
    }

    func invalidate() {
        log.info("invalidate() called — extension shutting down")
    }

    func item(for identifier: NSFileProviderItemIdentifier,
              request: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        log.info("item(for:) id=\(identifier.rawValue, privacy: .public)")
        if identifier == .rootContainer {
            completionHandler(RootFileProviderItem(displayName: domain.displayName), nil)
            return Progress()
        }
        if identifier == .workingSet {
            completionHandler(RootFileProviderItem(displayName: "Working Set"), nil)
            return Progress()
        }
        if identifier == .trashContainer {
            completionHandler(RootFileProviderItem(displayName: "Trash"), nil)
            return Progress()
        }
        // Ask the host whether the item has a lazy resolver that
        // needs to run. The call blocks until the resolver has
        // finished (or returns immediately for non-lazy items).
        // After it returns, the manifest cache is authoritative:
        //   - exists=true  → item is in cache (or about to be);
        //                    proceed with normal lookup.
        //   - exists=false → resolver failed; return noSuchItem
        //                    so Finder aborts the paste and
        //                    (best-effort) cleans up the dest dir.
        // The blocking is required to make the "Finder created an
        // empty MacRDP_<UUID> wrapper at the paste destination"
        // outcome avoidable: by the time we say "this item is a
        // folder", we already know whether its contents will
        // materialise.
        let exists = HostLazyResolver.resolveSync(
            source: serviceSource,
            domainSubdir: domainSubdir,
            itemID: identifier.rawValue)
        guard exists else {
            log.notice("item(for:) lazy-resolver said the item is gone id=\(identifier.rawValue, privacy: .public)")
            completionHandler(nil, NSError(domain: NSFileProviderErrorDomain,
                                            code: NSFileProviderError.noSuchItem.rawValue))
            return Progress()
        }
        guard let manifest = ManifestCache.shared.manifest(domainSubdir: domainSubdir),
              let entry = manifest.items.first(where: { $0.id == identifier.rawValue }) else {
            log.notice("item(for:) noSuchItem id=\(identifier.rawValue, privacy: .public)")
            completionHandler(nil, NSError(domain: NSFileProviderErrorDomain,
                                            code: NSFileProviderError.noSuchItem.rawValue))
            return Progress()
        }
        completionHandler(FileProviderItem(entry, manifestSessionID: manifest.sessionID), nil)
        return Progress()
    }

    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier,
                       version requestedVersion: NSFileProviderItemVersion?,
                       request: NSFileProviderRequest,
                       completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        log.info("fetchContents START id=\(itemIdentifier.rawValue, privacy: .public)")
        guard let manifest = ManifestCache.shared.manifest(domainSubdir: domainSubdir),
              let entry = manifest.items.first(where: { $0.id == itemIdentifier.rawValue }) else {
            log.error("fetchContents noSuchItem id=\(itemIdentifier.rawValue, privacy: .public)")
            completionHandler(nil, nil, NSError(domain: NSFileProviderErrorDomain,
                                                 code: NSFileProviderError.noSuchItem.rawValue))
            return Progress()
        }
        log.info("fetchContents resolved '\(entry.filename, privacy: .public)' size=\(entry.size, privacy: .public)")
        if entry.isDirectory {
            completionHandler(nil, nil, NSError(domain: NSFileProviderErrorDomain,
                                                 code: NSFileProviderError.noSuchItem.rawValue))
            return Progress()
        }

        // Allocate the temp file the FP framework will move/copy from.
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension((entry.filename as NSString).pathExtension)
        FileManager.default.createFile(atPath: tempURL.path, contents: nil, attributes: nil)
        guard let handle = try? FileHandle(forWritingTo: tempURL) else {
            completionHandler(nil, nil, NSError(domain: NSFileProviderErrorDomain,
                                                 code: NSFileProviderError.serverUnreachable.rawValue))
            return Progress()
        }

        // The File Provider framework observes the Progress object we
        // RETURN from this method directly (KVO on completedUnitCount /
        // totalUnitCount). That is the only channel Finder reads from for
        // a materialization, so we drive byte-level units here.
        //
        // Do NOT set kind = .file / fileTotalCount / fileCompletedCount:
        // those make NSProgress report "files completed" instead of bytes,
        // so a single-file fetch shows 0-of-1 ("Preparing…") for the whole
        // transfer and jumps to done at the end — no bar in between.
        //
        // Do NOT call publish()/set fileURL: that registers with the
        // separate addSubscriber(forFileURL:) system, which the FP
        // framework does not use.
        let progress = Progress(totalUnitCount: max(entry.size, 1))
        progress.isCancellable = true
        progress.isPausable = false
        let domainSubdir = self.domainSubdir
        let sessionID = manifest.sessionID
        let source = self.serviceSource

        // Lazy fetch: stream bytes from the host over the
        // NSFileProviderService XPC connection (extension → host
        // direction). Chunked so a multi-GB file doesn't balloon memory.
        let itemID = entry.id
        let totalSize = entry.size
        Task.detached {
            defer { try? handle.close() }
            let startMs = DispatchTime.now().uptimeNanoseconds / 1_000_000
            do {
                try await HostByteFetcher.fetchInto(
                    handle: handle,
                    source: source,
                    domainSubdir: domainSubdir,
                    itemID: itemID,
                    totalSize: totalSize,
                    progress: progress)
                let endMs = DispatchTime.now().uptimeNanoseconds / 1_000_000
                log.info("fetchContents DONE id=\(itemID, privacy: .public) bytes=\(totalSize, privacy: .public) took=\(endMs - startMs, privacy: .public)ms")
                progress.completedUnitCount = progress.totalUnitCount
                completionHandler(tempURL,
                                  FileProviderItem(entry, manifestSessionID: sessionID),
                                  nil)
            } catch {
                log.error("Host fetch failed: \(String(describing: error), privacy: .public)")
                try? FileManager.default.removeItem(at: tempURL)
                completionHandler(nil, nil, error)
            }
        }
        return progress
    }

    // MARK: - NSFileProviderService vending

    func supportedServiceSources(for itemIdentifier: NSFileProviderItemIdentifier,
                                 completionHandler: @escaping ([NSFileProviderServiceSource]?, Error?) -> Void) -> Progress {
        log.info("supportedServiceSources(for:) id=\(itemIdentifier.rawValue, privacy: .public)")
        // We expose the host bridge for any item — the host typically
        // asks on .rootContainer, but framework may probe others.
        completionHandler([serviceSource], nil)
        return Progress()
    }

    // MARK: - Read-only stubs

    func createItem(basedOn itemTemplate: NSFileProviderItem,
                    fields: NSFileProviderItemFields,
                    contents url: URL?,
                    options: NSFileProviderCreateItemOptions = [],
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        completionHandler(itemTemplate, [], false,
                          NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError))
        return Progress()
    }

    func modifyItem(_ item: NSFileProviderItem,
                    baseVersion version: NSFileProviderItemVersion,
                    changedFields: NSFileProviderItemFields,
                    contents newContents: URL?,
                    options: NSFileProviderModifyItemOptions = [],
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        completionHandler(nil, [], false,
                          NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError))
        return Progress()
    }

    func deleteItem(identifier: NSFileProviderItemIdentifier,
                    baseVersion version: NSFileProviderItemVersion,
                    options: NSFileProviderDeleteItemOptions = [],
                    request: NSFileProviderRequest,
                    completionHandler: @escaping (Error?) -> Void) -> Progress {
        completionHandler(NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError))
        return Progress()
    }

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier,
                    request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        log.info("enumerator(for:) container=\(containerItemIdentifier.rawValue, privacy: .public)")
        enumeratorsLock.lock()
        defer { enumeratorsLock.unlock() }
        if let existing = enumerators[containerItemIdentifier] {
            log.info("enumerator(for:) reusing existing for \(containerItemIdentifier.rawValue, privacy: .public)")
            return existing
        }
        let e = FileProviderEnumerator(domainSubdir: domainSubdir,
                                       containerID: containerItemIdentifier,
                                       serviceSource: serviceSource)
        enumerators[containerItemIdentifier] = e
        return e
    }
}
