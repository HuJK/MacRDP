//
//  FileProviderEnumerator.swift
//  fileprovider
//
//  Walks the App-Group manifest and reports children of a given
//  container. SyncAnchor is keyed off the manifest's sessionID, so
//  Finder re-enumerates whenever the main app publishes a new one
//  (e.g. a fresh Windows file-copy event).
//

import FileProvider
import os

private let elog = Logger(subsystem: "com.macrdp.server", category: "fileprovider")

final class FileProviderEnumerator: NSObject, NSFileProviderEnumerator {

    private let domainSubdir: String
    private let containerID: NSFileProviderItemIdentifier

    init(domainSubdir: String, containerID: NSFileProviderItemIdentifier) {
        self.domainSubdir = domainSubdir
        self.containerID = containerID
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
        guard let manifest = ManifestCache.shared.manifest(domainSubdir: domainSubdir) else {
            elog.notice("No manifest — empty enumeration")
            observer.didEnumerate([])
            observer.finishEnumerating(upTo: nil)
            return
        }
        // Working set must contain EVERY item the framework should
        // track. Without this, NSFileProviderManager.getUserVisibleURL
        // returns nil because the framework doesn't know our items
        // exist. Root container is the user-facing top level.
        let items: [ManifestItem]
        if containerID == .workingSet {
            items = manifest.items
        } else if containerID == .rootContainer {
            items = manifest.items.filter { $0.parentID == nil }
        } else {
            items = manifest.items.filter { $0.parentID == containerID.rawValue }
        }
        elog.info("Returning \(items.count, privacy: .public) item(s); manifest has \(manifest.items.count, privacy: .public), sessionID=\(manifest.sessionID, privacy: .public)")
        let fpItems = items.map {
            FileProviderItem($0, manifestSessionID: manifest.sessionID)
        }
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
        // New session: report ALL current items as updates. (We don't
        // diff — every clipboard claim is a fresh manifest.)
        guard let manifest = ManifestCache.shared.manifest(domainSubdir: domainSubdir) else {
            observer.finishEnumeratingChanges(upTo: current, moreComing: false)
            return
        }
        let items: [ManifestItem]
        if containerID == .workingSet {
            items = manifest.items
        } else if containerID == .rootContainer {
            items = manifest.items.filter { $0.parentID == nil }
        } else {
            items = manifest.items.filter { $0.parentID == containerID.rawValue }
        }
        elog.info("enumerateChanges container=\(self.containerID.rawValue, privacy: .public) updating \(items.count, privacy: .public)")
        let fpItems = items.map {
            FileProviderItem($0, manifestSessionID: manifest.sessionID)
        }
        observer.didUpdate(fpItems)
        observer.finishEnumeratingChanges(upTo: current, moreComing: false)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(currentAnchorValue())
    }

    private func currentAnchorValue() -> NSFileProviderSyncAnchor {
        let sid = ManifestCache.shared.manifest(domainSubdir: domainSubdir)?.sessionID ?? "empty"
        return NSFileProviderSyncAnchor(sid.data(using: .utf8) ?? Data([0]))
    }
}
