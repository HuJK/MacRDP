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
import FileProvider
import os

@MainActor
final class FileProviderXPCService: NSObject {

    static let shared = FileProviderXPCService()

    /// Multi-session storage. Each Windows-side clipboard event
    /// creates its OWN session (id, tree, byte fetcher). Sessions
    /// persist after a new copy supersedes them so an in-flight paste
    /// from the previous clipboard contents can still resolve items
    /// and fetch bytes (mstsc keeps the prior FGDW alive while any
    /// paste is using it).
    ///
    /// Root-container enumeration always serves the LATEST session
    /// for a given domain (matches Windows clipboard UX — only the
    /// newest copy is "the clipboard"). Old sessions are reachable
    /// by direct itemID via `itemToSession`.
    nonisolated(unsafe) private let sessionsLock = NSLock()
    nonisolated(unsafe) private var sessions: [String: SessionState] = [:]
    nonisolated(unsafe) private var currentSessionByDomain: [String: String] = [:]
    nonisolated(unsafe) private var itemToSession: [String: String] = [:]

    final class SessionState {
        let id: String
        let domainSubdir: String
        let tree: TreeStore
        let fetcher: (String, Int64, Int64) async -> (Data?, NSError?)
        /// Called once when the session is finally being freed.
        /// Owner uses this to send CLIPRDR `CB_UNLOCK_CLIPDATA` so
        /// mstsc can release the pinned FGDW snapshot.
        let onCleanup: (() -> Void)?
        /// Set when a newer copy event supersedes this session — once
        /// dismissed, the session is cleaned up as soon as it falls
        /// idle (no in-flight fetches for `idleGracePeriod`).
        var dismissed: Bool = false
        /// Set when the user explicitly cancels the session from the
        /// progress UI. New fetches reply with `NSURLErrorCancelled`
        /// immediately so Finder aborts the paste.
        var cancelled: Bool = false
        var inFlight: Int = 0
        var lastActivityAt: Date = Date()
        /// Lazy-mode hook: invoked exactly once, the first time someone
        /// enumerates a non-empty container belonging to this session.
        /// Closure must populate `tree` (via `TreeStore.replaceItems`)
        /// AND `idToListIndex` AND call
        /// `FileProviderXPCService.bindItemsToSession(..)` for every
        /// newly-discovered item id, all *synchronously*, before
        /// returning. Cleared on first invocation so it can't fire
        /// twice.
        var lazyResolver: ((SessionState) -> Void)?
        var lazyResolved: Bool = false
        let lazyLock = NSLock()
        /// FileProvider item id → FGDW listIndex. The byte fetcher
        /// closure looks up here each call (rather than capturing the
        /// map by value) so lazy sessions can populate it from the
        /// resolver without rebuilding the fetcher closure.
        var idToListIndex: [String: Int] = [:]
        /// Set by the lazy resolver when it couldn't produce a tree
        /// (timeout / FAIL / empty FGDW). Subsequent
        /// `enumerateChildren(placeholder)` replies with an error
        /// instead of an empty list, so Finder aborts the paste and
        /// (best-effort) cleans up the empty destination folder
        /// rather than leaving a stub.
        var resolveFailed: Bool = false
        var resolveFailureReason: String?
        init(id: String,
             domainSubdir: String,
             items: [ManifestItem],
             fetcher: @escaping (String, Int64, Int64) async -> (Data?, NSError?),
             onCleanup: (() -> Void)? = nil) {
            self.id = id
            self.domainSubdir = domainSubdir
            self.tree = TreeStore(items: items)
            self.fetcher = fetcher
            self.onCleanup = onCleanup
        }
    }

    /// Wait this long after a dismissed session goes idle (inFlight==0)
    /// before actually freeing it. Finder pauses between chunks
    /// sometimes; this prevents tearing down mid-transfer.
    private static let idleGracePeriod: TimeInterval = 30

    final class TreeStore {
        private(set) var byID: [String: ManifestItem] = [:]
        /// parentID → child ids in deterministic order. Top-level
        /// items are keyed under the empty string.
        private(set) var children: [String: [String]] = [:]

        init(items: [ManifestItem]) {
            byID.reserveCapacity(items.count)
            for it in items {
                byID[it.id] = it
                children[it.parentID ?? "", default: []].append(it.id)
            }
        }

        /// Atomically swap the tree contents. Used by lazy resolvers
        /// after the FGDW finally arrives — the placeholder session
        /// was created with just the root folder; this replaces it
        /// with the full tree (root + descendants).
        func replaceItems(_ items: [ManifestItem]) {
            byID = [:]
            children = [:]
            byID.reserveCapacity(items.count)
            for it in items {
                byID[it.id] = it
                children[it.parentID ?? "", default: []].append(it.id)
            }
        }

        func childItems(of parentID: String) -> [ManifestItem] {
            guard let ids = children[parentID] else { return [] }
            return ids.compactMap { byID[$0] }
        }
        func allItemIDs() -> [String] { Array(byID.keys) }
    }

    /// Register a fresh copy session for a domain. Old sessions are
    /// kept alive (their items still resolve via `itemToSession`) so
    /// an in-flight paste from a previous clipboard isn't interrupted.
    /// The new session becomes the "current" one for root enumeration.
    func registerSession(domainSubdir: String,
                         sessionID: String,
                         items: [ManifestItem],
                         fetcher: @escaping (_ itemID: String,
                                              _ offset: Int64,
                                              _ length: Int64) async -> (Data?, NSError?),
                         onCleanup: (() -> Void)? = nil) {
        let state = SessionState(id: sessionID,
                                 domainSubdir: domainSubdir,
                                 items: items,
                                 fetcher: fetcher,
                                 onCleanup: onCleanup)
        sessionsLock.lock()
        // Mark the previously-current session as dismissed. It'll be
        // cleaned up the moment it's idle (or, if it has no in-flight
        // transfers right now, almost immediately by tryCleanup).
        var sessionToCheck: String?
        if let prevID = currentSessionByDomain[domainSubdir],
           prevID != sessionID,
           let prev = sessions[prevID] {
            prev.dismissed = true
            sessionToCheck = prevID
        }
        sessions[sessionID] = state
        currentSessionByDomain[domainSubdir] = sessionID
        for it in items { itemToSession[it.id] = sessionID }
        let liveCount = sessions.values.filter { $0.domainSubdir == domainSubdir }.count
        sessionsLock.unlock()
        let topLevel = items.filter { $0.parentID == nil }.count
        Log.clip.info("Session '\(sessionID, privacy: .public)' registered: \(items.count, privacy: .public) items, \(topLevel, privacy: .public) top-level, \(liveCount, privacy: .public) live session(s) for domain")
        if let oldID = sessionToCheck {
            scheduleCleanupCheck(sessionID: oldID)
        }
    }

    /// Decrement in-flight counter for the session that owns `itemID`,
    /// timestamp the activity, and schedule a cleanup probe if the
    /// session is dismissed.
    nonisolated fileprivate func fetchDidComplete(itemID: String) {
        sessionsLock.lock()
        let sessionID = itemToSession[itemID]
        if let sessionID, let s = sessions[sessionID] {
            s.inFlight = max(0, s.inFlight - 1)
            s.lastActivityAt = Date()
        }
        let dismissed = sessionID.flatMap { sessions[$0]?.dismissed } ?? false
        sessionsLock.unlock()
        if dismissed, let sessionID {
            scheduleCleanupCheck(sessionID: sessionID)
        }
    }

    /// Schedule a delayed cleanup probe for a dismissed session.
    /// The probe checks whether the session is still dismissed,
    /// has zero in-flight, AND has been idle for `idleGracePeriod`
    /// — if all true, drops it.
    nonisolated fileprivate func scheduleCleanupCheck(sessionID: String) {
        DispatchQueue.global(qos: .background).asyncAfter(
            deadline: .now() + Self.idleGracePeriod
        ) { [weak self] in
            self?.tryCleanupSession(sessionID: sessionID)
        }
    }

    nonisolated fileprivate func tryCleanupSession(sessionID: String) {
        sessionsLock.lock()
        guard let s = sessions[sessionID] else {
            sessionsLock.unlock(); return
        }
        guard s.dismissed else {
            sessionsLock.unlock(); return
        }
        guard s.inFlight == 0 else {
            sessionsLock.unlock(); return
        }
        guard Date().timeIntervalSince(s.lastActivityAt) >= Self.idleGracePeriod else {
            sessionsLock.unlock()
            // Activity since the probe was scheduled — re-arm.
            DispatchQueue.global(qos: .background).asyncAfter(
                deadline: .now() + Self.idleGracePeriod
            ) { [weak self] in
                self?.tryCleanupSession(sessionID: sessionID)
            }
            return
        }
        // Remove every item mapping owned by this session. Items the
        // user has since re-pushed (same id) shouldn't be removed —
        // itemToSession[id] would point to the NEWER session.
        for itemID in s.tree.allItemIDs() where itemToSession[itemID] == sessionID {
            itemToSession.removeValue(forKey: itemID)
        }
        sessions.removeValue(forKey: sessionID)
        let cleanup = s.onCleanup
        let remaining = sessions.values.filter { $0.domainSubdir == s.domainSubdir }.count
        sessionsLock.unlock()
        Log.clip.info("Session '\(sessionID, privacy: .public)' cleaned up; \(remaining, privacy: .public) live session(s) remain for domain")
        // Fire onCleanup OUTSIDE the lock — typically sends a CLIPRDR
        // CB_UNLOCK_CLIPDATA so the client can free the snapshot.
        cleanup?()
    }

    /// Register a session that doesn't yet know its tree contents — it
    /// only has a placeholder root folder. The first time anyone
    /// enumerates that root's children, `lazyResolver` runs
    /// synchronously and is responsible for populating the tree,
    /// `idToListIndex`, and registering item IDs via
    /// `bindItemsToSession`.
    ///
    /// Used by the "lazy" file fetch mode: pasteboard is claimed with
    /// just the placeholder URL on `CB_FORMAT_LIST`, and we defer the
    /// `CB_FORMAT_DATA_REQUEST` for the FGDW until Finder actually
    /// asks for the placeholder's contents (i.e. user paste).
    func registerLazySession(domainSubdir: String,
                             sessionID: String,
                             placeholderItem: ManifestItem,
                             fetcher: @escaping (_ itemID: String,
                                                  _ offset: Int64,
                                                  _ length: Int64) async -> (Data?, NSError?),
                             lazyResolver: @escaping (SessionState) -> Void,
                             onCleanup: (() -> Void)? = nil) {
        let state = SessionState(id: sessionID,
                                 domainSubdir: domainSubdir,
                                 items: [placeholderItem],
                                 fetcher: fetcher,
                                 onCleanup: onCleanup)
        state.lazyResolver = lazyResolver
        sessionsLock.lock()
        var sessionToCheck: String?
        if let prevID = currentSessionByDomain[domainSubdir],
           prevID != sessionID,
           let prev = sessions[prevID] {
            prev.dismissed = true
            sessionToCheck = prevID
        }
        sessions[sessionID] = state
        currentSessionByDomain[domainSubdir] = sessionID
        itemToSession[placeholderItem.id] = sessionID
        let liveCount = sessions.values.filter { $0.domainSubdir == domainSubdir }.count
        sessionsLock.unlock()
        Log.clip.info("Session '\(sessionID, privacy: .public)' registered (lazy) with placeholder '\(placeholderItem.filename, privacy: .public)'; \(liveCount, privacy: .public) live session(s) for domain")
        if let oldID = sessionToCheck {
            scheduleCleanupCheck(sessionID: oldID)
        }
    }

    /// Bind a set of newly-discovered FileProvider item IDs to a
    /// session. Called by lazy resolvers after they expand the
    /// placeholder into the full tree.
    nonisolated func bindItemsToSession(_ items: [ManifestItem], sessionID: String) {
        sessionsLock.lock()
        for it in items { itemToSession[it.id] = sessionID }
        sessionsLock.unlock()
    }

    /// Look up the FGDW listIndex bound to a FileProvider item id.
    /// Used by lazy-mode byte fetchers: rather than capturing a
    /// pre-built map at closure creation time, they look up via the
    /// service so the lazy resolver can populate the map later.
    nonisolated func listIndex(for itemID: String) -> Int? {
        sessionsLock.lock(); defer { sessionsLock.unlock() }
        guard let sid = itemToSession[itemID] else { return nil }
        return sessions[sid]?.idToListIndex[itemID]
    }

    /// True if the session has been cancelled (user clicked Cancel
    /// in the copy-progress UI). Read under sessionsLock so it's
    /// safe to poll from nonisolated contexts like the lazy resolver.
    nonisolated func isSessionCancelled(sessionID: String) -> Bool {
        sessionsLock.lock(); defer { sessionsLock.unlock() }
        return sessions[sessionID]?.cancelled ?? false
    }

    /// Mark a lazy session as failed so the next `enumerateChildren`
    /// for its placeholder replies with an error rather than an empty
    /// list. Called by the lazy resolver when the FGDW can't be
    /// obtained.
    nonisolated func markResolveFailed(sessionID: String, reason: String) {
        sessionsLock.lock()
        if let s = sessions[sessionID] {
            s.resolveFailed = true
            s.resolveFailureReason = reason
        }
        sessionsLock.unlock()
    }

    /// Synthetic test-file path. The synthetic fetcher (no real
    /// clipboard) needs to coexist with a single fixed itemID across
    /// app lifetime, so we treat it as its own session.
    func registerSyntheticFetcher(domainSubdir: String,
                                  sessionID: String,
                                  items: [ManifestItem],
                                  fetcher: @escaping (String, Int64, Int64) async -> (Data?, NSError?)) {
        registerSession(domainSubdir: domainSubdir,
                         sessionID: sessionID,
                         items: items,
                         fetcher: fetcher)
    }

    /// Cancel every live session in a domain except the one named.
    /// Used by ClipboardBridge so a new copy event aborts any
    /// previously-in-flight paste — the wire-level FGDW is single-slot
    /// without LOCK_CLIPDATA, so the previous paste would otherwise
    /// silently start receiving the new session's bytes.
    func cancelAllSessions(domainSubdir: String, except keep: String) {
        sessionsLock.lock()
        let victims = sessions.values
            .filter { $0.domainSubdir == domainSubdir && $0.id != keep && !$0.cancelled }
            .map { $0.id }
        for sid in victims {
            sessions[sid]?.cancelled = true
            sessions[sid]?.dismissed = true
        }
        sessionsLock.unlock()
        for sid in victims {
            Log.clip.notice("Session '\(sid, privacy: .public)' auto-cancelled — superseded by new clipboard event")
            scheduleCleanupCheck(sessionID: sid)
        }
    }

    /// Cancel an in-flight copy session. Marks the session so that
    /// further fetches reply with an error immediately; also dismisses
    /// it so the host's normal cleanup tears it down on idle.
    func cancelSession(sessionID: String) {
        sessionsLock.lock()
        guard let s = sessions[sessionID] else {
            sessionsLock.unlock(); return
        }
        s.cancelled = true
        s.dismissed = true
        sessionsLock.unlock()
        Log.clip.notice("Session '\(sessionID, privacy: .public)' cancelled by user")
        scheduleCleanupCheck(sessionID: sessionID)
    }

    /// XPC entry point for the extension's `item(for:)`. If the
    /// item belongs to a lazy session whose resolver hasn't run
    /// yet, fire the resolver synchronously here. After this
    /// returns:
    ///   - reply(true)  : the resolver populated the tree; the
    ///                    extension may now return the item from
    ///                    the local manifest cache.
    ///   - reply(false) : the resolver failed (cancel / empty
    ///                    FGDW). Extension should return
    ///                    NSFileProviderError.noSuchItem so Finder
    ///                    doesn't create a destination wrapper
    ///                    folder for a source that won't materialise.
    nonisolated fileprivate func handleResolveItem(
        domainSubdir: String,
        itemID: String,
        reply: @escaping (Bool, NSError?) -> Void)
    {
        sessionsLock.lock()
        let session = itemToSession[itemID].flatMap { sessions[$0] }
        sessionsLock.unlock()
        guard let session else {
            // Item we don't know about — extension's local cache
            // will decide whether to return it or noSuchItem.
            reply(true, nil)
            return
        }
        // Run the lazy resolver if it hasn't fired yet. The lock
        // ensures only one of (resolveItem, enumerateChildren)
        // actually invokes the closure.
        session.lazyLock.lock()
        let resolver = session.lazyResolver
        if !session.lazyResolved, let resolver {
            session.lazyResolved = true
            session.lazyResolver = nil
            session.lazyLock.unlock()
            resolver(session)   // blocking
        } else {
            session.lazyLock.unlock()
        }
        // After the resolver, report success / failure to the
        // extension so it can choose between returning the item
        // or noSuchItem.
        sessionsLock.lock()
        let failed = session.resolveFailed
        sessionsLock.unlock()
        reply(!failed, nil)
    }

    nonisolated fileprivate func handleEnumerateChildren(
        domainSubdir: String,
        containerID: String,
        reply: @escaping (Data?, NSError?) -> Void)
    {
        // If the container belongs to a lazy session whose tree hasn't
        // been resolved yet, run the resolver synchronously here BEFORE
        // computing children. The resolver populates `tree` +
        // `idToListIndex` and calls `bindItemsToSession`. Done outside
        // the global sessionsLock so the resolver can re-enter the
        // service (it must, to call bindItemsToSession).
        if !containerID.isEmpty {
            sessionsLock.lock()
            let session = itemToSession[containerID].flatMap { sessions[$0] }
            sessionsLock.unlock()
            if let session {
                session.lazyLock.lock()
                let resolver = session.lazyResolver
                if !session.lazyResolved, let resolver {
                    session.lazyResolved = true
                    session.lazyResolver = nil
                    session.lazyLock.unlock()
                    resolver(session)   // blocking
                } else {
                    session.lazyLock.unlock()
                }
            }
        }

        sessionsLock.lock()
        let kids: [ManifestItem]
        var failedReason: String? = nil
        if containerID.isEmpty {
            // Root: aggregate the synthetic session-folder entries
            // from every live session in this domain so the user sees
            // all concurrent copies. Sorted oldest—first via UUID
            // ordering — stable, good enough for now.
            var roots: [ManifestItem] = []
            for state in sessions.values
                where state.domainSubdir == domainSubdir {
                roots.append(contentsOf: state.tree.childItems(of: ""))
            }
            roots.sort { $0.id < $1.id }
            kids = roots
        } else {
            let sessionID = itemToSession[containerID]
            let session = sessionID.flatMap { sessions[$0] }
            // If the lazy resolver couldn't build a tree, signal
            // failure up to Finder so it aborts the paste rather
            // than landing an empty wrapper folder at the
            // destination.
            if let session, session.resolveFailed,
               containerID == session.id {
                failedReason = session.resolveFailureReason
                    ?? "Could not resolve file list from Windows"
                kids = []
            } else {
                kids = session?.tree.childItems(of: containerID) ?? []
            }
        }
        sessionsLock.unlock()
        if let failedReason {
            reply(nil, NSError(
                domain: NSFileProviderErrorDomain,
                code: NSFileProviderError.serverUnreachable.rawValue,
                userInfo: [NSLocalizedDescriptionKey: failedReason]))
            return
        }
        do {
            let data = try JSONEncoder().encode(kids)
            reply(data, nil)
        } catch {
            reply(nil, error as NSError)
        }
    }

    nonisolated fileprivate func handleFetch(domainSubdir: String,
                                             itemID: String,
                                             offset: Int64,
                                             length: Int64,
                                             reply: @escaping (Data?, NSError?) -> Void) {
        sessionsLock.lock()
        let sessionID = itemToSession[itemID]
        let session = sessionID.flatMap { sessions[$0] }
        // Cancelled sessions short-circuit: reply with an error and
        // don't even invoke the fetcher closure. Finder will abort.
        if let session, session.cancelled {
            sessionsLock.unlock()
            reply(nil, NSError(domain: NSCocoaErrorDomain,
                               code: NSUserCancelledError,
                               userInfo: [NSLocalizedDescriptionKey: "User cancelled"]))
            return
        }
        let fetcher = session?.fetcher
        if let s = session {
            s.inFlight += 1
            s.lastActivityAt = Date()
        }
        sessionsLock.unlock()
        guard let fetcher else {
            reply(nil, NSError(domain: "MacRDP.xpc", code: 404,
                userInfo: [NSLocalizedDescriptionKey:
                    "No session owns itemID \(itemID)"]))
            return
        }
        let svc = self
        Task.detached {
            let (data, err) = await fetcher(itemID, offset, length)
            reply(data, err)
            svc.fetchDidComplete(itemID: itemID)
            if err == nil, let data {
                CopyProgressTracker.shared.chunkDelivered(
                    itemID: itemID,
                    offset: offset,
                    length: Int64(data.count))
            }
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

    nonisolated func enumerateChildren(domainSubdir: String,
                                       containerID: String,
                                       reply: @escaping (Data?, NSError?) -> Void) {
        FileProviderXPCService.shared.handleEnumerateChildren(
            domainSubdir: domainSubdir,
            containerID: containerID,
            reply: reply)
    }

    nonisolated func resolveItem(domainSubdir: String,
                                  itemID: String,
                                  reply: @escaping (Bool, NSError?) -> Void) {
        FileProviderXPCService.shared.handleResolveItem(
            domainSubdir: domainSubdir,
            itemID: itemID,
            reply: reply)
    }
}
