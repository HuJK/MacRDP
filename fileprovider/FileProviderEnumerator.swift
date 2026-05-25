//
//  FileProviderEnumerator.swift
//  fileprovider
//
//  Lazy folder-tree enumerator. The extension's ManifestCache holds
//  ONLY items it has actually been told about (top-level items at
//  publish time, plus any sub-folder children the framework has
//  already drilled into). When `enumerateItems` is called for a
//  container we haven't visited yet, we ask the host for its
//  immediate children via XPC and merge the response into the cache.
//
//  Why: a single eager push for a 40 k-item folder costs multi-MB
//  XPC + multi-second framework indexing; lazy enumeration makes
//  paste-ready time independent of tree size.
//

import FileProvider
import os

private let elog = Logger(subsystem: "com.macrdp.server", category: "fileprovider")

final class FileProviderEnumerator: NSObject, NSFileProviderEnumerator {

    private let domainSubdir: String
    private let containerID: NSFileProviderItemIdentifier
    /// Host service source — used to drive XPC `enumerateChildren`
    /// calls during cache-miss enumeration.
    private weak var serviceSource: ClipboardServiceSource?

    init(domainSubdir: String,
         containerID: NSFileProviderItemIdentifier,
         serviceSource: ClipboardServiceSource?) {
        self.domainSubdir = domainSubdir
        self.containerID = containerID
        self.serviceSource = serviceSource
        super.init()
        elog.info("Enumerator init container=\(containerID.rawValue, privacy: .public)")
    }

    deinit {
        elog.info("Enumerator DEINIT container=\(self.containerID.rawValue, privacy: .public)")
    }

    func invalidate() {
        elog.info("Enumerator invalidate container=\(self.containerID.rawValue, privacy: .public)")
    }

    func enumerateItems(for observer: NSFileProviderEnumerationObserver,
                        startingAt page: NSFileProviderPage) {
        elog.info("enumerateItems container=\(self.containerID.rawValue, privacy: .public) subdir=\(self.domainSubdir, privacy: .public)")
        if containerID == .trashContainer {
            observer.didEnumerate([])
            observer.finishEnumerating(upTo: nil)
            return
        }
        let items = itemsFor(container: containerID)
        elog.info("Returning \(items.count, privacy: .public) item(s)")
        let sessionID = ManifestCache.shared.manifest(domainSubdir: domainSubdir)?.sessionID ?? "lazy"
        let writable = domainSubdir.hasPrefix(AppGroupShared.driveDomainPrefix)
        let fpItems = items.map { FileProviderItem($0, manifestSessionID: sessionID, isWritable: writable) }
        observer.didEnumerate(fpItems)
        observer.finishEnumerating(upTo: nil)
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver,
                          from anchor: NSFileProviderSyncAnchor) {
        let current = currentAnchorValue()
        if anchor.rawValue == current.rawValue {
            observer.finishEnumeratingChanges(upTo: current, moreComing: false)
            return
        }
        // A removal (rename/delete) bumps the removal generation. We don't
        // keep per-item tombstones, so a generation change means "items may
        // have vanished" — expire the anchor to force the framework to re-run
        // a full enumeration, which drops stale items from its replica.
        // (Additive-only changes, e.g. the host's pushManifest, keep the
        // generation and fall through to the incremental didUpdate below.)
        if Self.removalGen(of: anchor) != ManifestCache.shared.removalGeneration(domainSubdir: domainSubdir) {
            elog.info("enumerateChanges: removal-gen changed → syncAnchorExpired (full re-enumerate)")
            observer.finishEnumeratingWithError(NSError(
                domain: NSFileProviderErrorDomain,
                code: NSFileProviderError.syncAnchorExpired.rawValue))
            return
        }
        let items = itemsFor(container: containerID)
        let sessionID = ManifestCache.shared.manifest(domainSubdir: domainSubdir)?.sessionID ?? "lazy"
        let writable = domainSubdir.hasPrefix(AppGroupShared.driveDomainPrefix)
        let fpItems = items.map { FileProviderItem($0, manifestSessionID: sessionID, isWritable: writable) }
        elog.info("enumerateChanges container=\(self.containerID.rawValue, privacy: .public) updating \(fpItems.count, privacy: .public)")
        observer.didUpdate(fpItems)
        observer.finishEnumeratingChanges(upTo: current, moreComing: false)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(currentAnchorValue())
    }

    // MARK: - Lazy resolution

    /// Resolve items for a container — local cache first, fall back to
    /// XPC `enumerateChildren` on the host.
    private func itemsFor(container: NSFileProviderItemIdentifier) -> [ManifestItem] {
        let parentKey: String
        if container == .rootContainer || container == .workingSet {
            parentKey = ""    // host treats "" as top-level
        } else {
            parentKey = container.rawValue
        }

        // Cache hit?
        let cached = ManifestCache.shared.items(domainSubdir: domainSubdir)
        let cachedChildren = cached.filter {
            ($0.parentID ?? "") == parentKey
        }
        if !cachedChildren.isEmpty {
            return cachedChildren
        }

        // Cache miss → ask the host. workingSet is intentionally not
        // round-tripped — we never want to materialise the whole tree.
        if container == .workingSet {
            return cached.filter { $0.parentID == nil }
        }

        guard let source = serviceSource else {
            elog.notice("itemsFor: no serviceSource, returning empty")
            return []
        }
        guard let fetched = HostChildEnumerator.fetchChildrenSync(
            source: source,
            domainSubdir: domainSubdir,
            containerID: parentKey)
        else {
            return []
        }
        ManifestCache.shared.merge(items: fetched, domainSubdir: domainSubdir)
        elog.info("XPC enumerateChildren cid='\(parentKey, privacy: .public)' → \(fetched.count, privacy: .public) item(s)")
        return fetched
    }

    private func currentAnchorValue() -> NSFileProviderSyncAnchor {
        let sid = ManifestCache.shared.manifest(domainSubdir: domainSubdir)?.sessionID ?? "empty"
        let gen = ManifestCache.shared.removalGeneration(domainSubdir: domainSubdir)
        // sessionID never contains '#', so the suffix parses back cleanly.
        return NSFileProviderSyncAnchor("\(sid)#\(gen)".data(using: .utf8) ?? Data([0]))
    }

    /// Extract the removal-generation suffix encoded in an anchor.
    private static func removalGen(of anchor: NSFileProviderSyncAnchor) -> UInt64 {
        guard let s = String(data: anchor.rawValue, encoding: .utf8),
              let suffix = s.split(separator: "#").last,
              let v = UInt64(suffix) else { return 0 }
        return v
    }
}
