//
//  CopyEvent.swift
//  MacRDP
//
//  Unified Win→Mac copy-event model + its registry.
//
//  A `CopyEvent` is the single source of truth for one Windows-side
//  clipboard event (one Ctrl+C). It owns the file tree, the byte
//  fetcher, and (eventually) the lifecycle state machine. It is
//  deliberately MODE-AGNOSTIC — there is no eager/lazy flag here. The
//  difference between eager and lazy lives entirely in the rds layer
//  (ClipboardBridge): who calls `resolve()` and when, and what gets
//  bound to the pasteboard.
//
//  `CopyEventStore` is the lock-protected registry that both the
//  FileProvider extension's XPC handlers (sandbox threads) and the UI
//  read from. It replaces the per-session maps that used to live inside
//  `FileProviderXPCService`.
//
//  Stage 1 note: this is the structural extraction of the former
//  `FileProviderXPCService.SessionState` + its session maps. Behavior is
//  intentionally identical to the previous implementation. The
//  `State`/`EndReason` machine declared on `CopyEvent` is scaffolding —
//  Stage 2 wires the transitions and the two-phase `end()`; today the
//  legacy `dismissed`/`cancelled` flags + idle-grace cleanup still drive
//  teardown.
//

import Foundation
import FileProvider
import os

/// One Windows clipboard event. Data plane, manually synchronized via
/// `CopyEventStore.lock` (and `lazyLock` for the resolver fields), hence
/// `@unchecked Sendable`. Not actor-isolated — touched from the
/// extension's XPC threads.
nonisolated final class CopyEvent: @unchecked Sendable {

    /// Lifecycle phase. Stage 2 drives cleanup / idle-clearing off this;
    /// Stage 1 leaves it inert (defaults to `.idle`, not yet read by the
    /// teardown logic).
    ///   idle      — on the clipboard, real content pending / not pasted
    ///   marquee   — FGDW fetch in flight (resolving the file list)
    ///   resolved  — tree known, no active transfer; ready to (re)paste
    ///   transfer  — ≥1 in-flight byte fetch (actively being pasted)
    ///   ended     — terminal; being reaped
    enum State {
        case idle, marquee, resolved, transfer, ended
        /// User cancelled the in-progress paste. The NEXT fetch fails (so
        /// Finder aborts), then the state returns to `.resolved` — keeping the
        /// clipboard valid so a later paste (here or elsewhere) runs normally.
        case cancelled
    }

    /// Why an event ended. Stage 2 uses this to decide notification vs
    /// silent teardown.
    enum EndReason {
        case superseded            // a newer copy replaced it on the clipboard
        case clientDisconnected    // RDP session went away
        case resolveFailed(String) // never produced a usable tree
        case cancelled             // user aborted (Stage 2: per-transfer, not whole event)
    }

    let id: String
    let domainSubdir: String
    /// Human-ish label for the progress UI row (the placeholder name).
    let displayTitle: String
    let tree: TreeStore
    let fetcher: (_ itemID: String, _ offset: Int64, _ length: Int64) async -> (Data?, NSError?)
    /// Called once when the event is finally freed. Owner uses this to
    /// send CLIPRDR `CB_UNLOCK_CLIPDATA` so mstsc can release the pinned
    /// FGDW snapshot.
    let onCleanup: (() -> Void)?

    // MARK: State machine (Stage 2)
    var state: State = .idle
    var endReason: EndReason?

    // MARK: Legacy lifecycle flags (Stage 1 — still drive teardown)
    /// Set when a newer copy event supersedes this event — once
    /// dismissed it is cleaned up as soon as it falls idle (no in-flight
    /// fetches for `idleGracePeriod`).
    var dismissed: Bool = false
    var inFlight: Int = 0
    var lastActivityAt: Date = Date()

    /// Per-file fetch count over the event's whole life. Drives the
    /// progress denominator: fetchCount == 0 → never fetched → seeded into
    /// a new transfer's denominator (so the first paste seeds the whole
    /// tree); fetchCount != 0 → was fetched before, so if it comes back it
    /// was cache-evicted → added lazily.
    var fetchCount: [String: Int] = [:]

    // MARK: - Progress accounting (per transfer; lock-protected by store)
    //
    // The progress/speed stats live HERE (data layer), not in the UI. The
    // UI just polls `makeSnapshot`. A "transfer" is one paste; it resets
    // only when a NEW transfer begins — i.e. a fetch arrives AFTER the
    // previous transfer both finished AND went idle (a genuine re-paste),
    // never on a mid-paste lull (which kept "20 files → 1 file" from
    // happening). The denominator only grows within a transfer.
    var transferStartedAt: Date?            // nil ⇒ no active transfer
    var transferLastChunkAt: Date = .distantPast
    var transferCancelled: Bool = false
    var accounted: Set<String> = []          // items in this transfer's denominator
    var bytesSeen: [String: Int64] = [:]
    var totalWeight: Int64 = 0               // denominator (progress bar)
    var totalReal: Int64 = 0                 // denominator (bytes/eta)
    var weightedSeen: Int64 = 0              // numerator (progress bar), running
    var realSeen: Int64 = 0                  // numerator (bytes), running
    var filesCompletedCount: Int = 0
    var filesTotalCount: Int = 0
    /// Realtime-speed sliding window: (time, real-byte-delta) + running sum.
    var rtWindow: [(t: Date, bytes: Int64)] = []
    var rtAccum: Int64 = 0
    /// Chart checkpoints, committed every ~N weighted bytes.
    var history: [(t: Date, weighted: Int64, raw: Int64)] = []
    /// Name of the file most recently receiving bytes (for the row's
    /// "Name:" line) — cached so the snapshot needn't scan all items.
    var currentItemName: String = "—"
    /// True while a paste-triggered resolve is in flight (lazy). Eager's
    /// proactive pre-paste resolve leaves this false → no marquee row.
    var resolvingForPaste: Bool = false
    /// Set the moment Finder touches this event's CONTENTS — enumerating
    /// the placeholder's children, resolving an item, or fetching bytes.
    /// All of those only happen because the user pasted (or opened) it. It
    /// is the reliable "this event has been used" signal: a superseding
    /// copy must NEVER tear down an engaged event (that would cancel a
    /// paste that's still resolving / between fetches), only a never-
    /// touched placeholder.
    var finderEngaged: Bool = false

    // MARK: Lazy resolution
    /// Invoked exactly once, the first time someone enumerates a
    /// non-empty container belonging to this event (or the rds layer
    /// proactively calls it, for eager). Must populate `tree` (via
    /// `TreeStore.replaceItems`) AND `idToListIndex` AND call
    /// `CopyEventStore.bindItemsToEvent(..)` for every newly-discovered
    /// item id, all *synchronously*, before returning. Cleared on first
    /// invocation so it can't fire twice.
    var lazyResolver: ((CopyEvent) -> Void)?
    var lazyResolved: Bool = false
    let lazyLock = NSLock()

    /// FileProvider item id → FGDW listIndex. The byte fetcher looks up
    /// here each call (rather than capturing the map by value) so lazy
    /// events can populate it from the resolver without rebuilding the
    /// fetcher closure.
    var idToListIndex: [String: Int] = [:]

    /// Set when the resolver couldn't build a tree and instead populated
    /// the placeholder with a single unreadable `broken.bin` — the trick
    /// that makes Finder clean up the destination folder (a file read
    /// error does; an empty enumerate doesn't). Such an event shows no
    /// progress row (Finder surfaces the read error itself) and is dropped
    /// a few seconds later once Finder has reaped its destination.
    var isBrokenPlaceholder: Bool = false

    init(id: String,
         domainSubdir: String,
         displayTitle: String,
         items: [ManifestItem],
         fetcher: @escaping (String, Int64, Int64) async -> (Data?, NSError?),
         onCleanup: (() -> Void)? = nil) {
        self.id = id
        self.domainSubdir = domainSubdir
        self.displayTitle = displayTitle
        self.tree = TreeStore(items: items)
        self.fetcher = fetcher
        self.onCleanup = onCleanup
    }

    // MARK: - Progress: ingest + snapshot (called by store, under lock)

    private static let fileWeightPad: Int64 = 4096   // small files still move the bar
    private static let finishedIdleHide: TimeInterval = 1.5

    private func weight(_ size: Int64) -> Int64 { size + Self.fileWeightPad }

    /// True once the current transfer is done AND has been idle long
    /// enough that the next fetch should count as a NEW paste (reset).
    private func transferFinishedAndIdle(_ now: Date) -> Bool {
        guard transferStartedAt != nil else { return false }
        let complete = transferCancelled
            || (totalWeight > 0 && weightedSeen >= totalWeight)
        return complete && now.timeIntervalSince(transferLastChunkAt) > Self.finishedIdleHide
    }

    /// Begin a fresh transfer's accounting. Seeds the denominator with
    /// files that have never been fetched (whole tree on the first paste;
    /// nothing on a fully-cached re-paste — those come back lazily).
    private func startTransfer(_ now: Date) {
        transferStartedAt = now
        transferLastChunkAt = now
        transferCancelled = false
        accounted = []
        bytesSeen = [:]
        totalWeight = 0; totalReal = 0
        weightedSeen = 0; realSeen = 0
        filesCompletedCount = 0; filesTotalCount = 0
        rtWindow = []; rtAccum = 0
        history = [(now, 0, 0)]
        currentItemName = "—"
        for id in tree.allItemIDs() where id != self.id {
            guard let m = tree.byID[id], !m.isDirectory,
                  fetchCount[id, default: 0] == 0 else { continue }
            accounted.insert(id)
            totalWeight += weight(m.size); totalReal += m.size; filesTotalCount += 1
        }
    }

    /// Record bytes delivered for one item (called per chunk, under lock).
    func ingest(itemID: String, offset: Int64, length: Int64, now: Date) {
        if transferStartedAt == nil || transferFinishedAndIdle(now) {
            startTransfer(now)
        }
        transferLastChunkAt = now
        fetchCount[itemID, default: 0] += 1
        guard let m = tree.byID[itemID], !m.isDirectory else { return }
        let size = m.size
        // Lazily account a cache-evicted file not in the seed.
        if !accounted.contains(itemID) {
            accounted.insert(itemID)
            totalWeight += weight(size); totalReal += size; filesTotalCount += 1
        }
        let oldBytes = bytesSeen[itemID] ?? 0
        let newBytes = max(oldBytes, offset + length)
        guard newBytes > oldBytes else { return }
        let oldReal = min(size, oldBytes), newReal = min(size, newBytes)
        let oldCW = oldBytes >= size ? weight(size) : oldBytes
        let newCW = newBytes >= size ? weight(size) : newBytes
        bytesSeen[itemID] = newBytes
        if newBytes < size { currentItemName = m.filename }   // file still in progress
        realSeen += newReal - oldReal
        weightedSeen += newCW - oldCW
        if newBytes >= size, oldBytes < size, size > 0 { filesCompletedCount += 1 }
        let dReal = newReal - oldReal
        if dReal > 0 { rtWindow.append((now, dReal)); rtAccum += dReal }
        let n = max(Int64(1024), totalWeight / 100)
        if weightedSeen - (history.last?.weighted ?? 0) >= n {
            history.append((now, weightedSeen, realSeen))
        }
    }

    private func evictSpeedWindow(_ now: Date, _ windowSec: TimeInterval) {
        let cutoff = now.addingTimeInterval(-windowSec)
        var drop = 0
        for rec in rtWindow { if rec.t < cutoff { rtAccum -= rec.bytes; drop += 1 } else { break } }
        if drop > 0 { rtWindow.removeFirst(drop) }
    }

    /// Build the UI snapshot (or nil = no row). MUTATES (ages the speed
    /// window by `now` — the "0-byte tick" folded into the poll). Called
    /// by the store under lock.
    func makeSnapshot(now: Date, windowSec: TimeInterval) -> ClipProgressSnapshot? {
        // Broken placeholder: Finder shows its own "couldn't read" error;
        // we deliberately show no progress row for it.
        if isBrokenPlaceholder { return nil }
        // A row shows only while this event is actually being pasted: lazy
        // from its (paste-triggered) marquee, eager/others from the first
        // fetch. Idle / eager-waiting / ended events show nothing.
        let beingPasted = resolvingForPaste || state == .transfer || transferStartedAt != nil
        guard beingPasted else { return nil }

        // Kind is 1:1 with state — marquee → resolving (no info yet).
        if state == .marquee {
            return ClipProgressSnapshot(id: id, title: displayTitle, kind: .resolving,
                progressFraction: 0, completedRealBytes: 0,
                totalRealBytes: 0, bytesPerSec: 0, etaSeconds: 0, filesCompleted: 0,
                filesTotal: 0, currentName: "—", cancelled: false, isComplete: false, chart: [])
        }

        // Transferring. Two sub-cases:
        //   • not yet started (resolved, waiting for the first byte): the
        //     tree already knows the file count + total size → show those
        //     at 0% (no blank gap, no "0 files").
        //   • started: live progress + speed + chart.
        let started = transferStartedAt != nil
        if started {
            evictSpeedWindow(now, windowSec)
            let complete = totalWeight > 0 && weightedSeen >= totalWeight
            if (complete || transferCancelled),
               now.timeIntervalSince(transferLastChunkAt) > Self.finishedIdleHide {
                return nil   // finished + idle → drop the row (re-paste resets)
            }
        }

        let fileCount: Int, totalBytes: Int64, doneBytes: Int64, frac: Double, bps: Double
        var currentName = "—"
        var chart: [ChartPoint] = []
        if started {
            frac = totalWeight > 0 ? Double(weightedSeen) / Double(totalWeight) : 0
            bps = Double(rtAccum) / max(0.001, windowSec)
            fileCount = filesTotalCount; totalBytes = totalReal; doneBytes = realSeen
            currentName = currentItemName   // O(1) — cached in ingest
            if let f = history.first {
                var prev = f
                for i in 1..<max(1, history.count) {
                    let cur = history[i]
                    let dt = cur.t.timeIntervalSince(prev.t)
                    chart.append(ChartPoint(pct: Double(cur.weighted) / Double(max(1, totalWeight)),
                                            bps: dt > 0 ? max(0, Double(cur.raw - prev.raw) / dt) : 0))
                    prev = cur
                }
                let dt = now.timeIntervalSince(prev.t)
                if dt > 0.05 {
                    chart.append(ChartPoint(pct: frac, bps: max(0, Double(realSeen - prev.raw) / dt)))
                }
            }
        } else {
            // Resolved, waiting for bytes — totals straight from the tree.
            let t = treeFileTotals()
            fileCount = t.count; totalBytes = t.bytes; doneBytes = 0; frac = 0; bps = 0
        }
        let eta = (bps > 1 && frac < 1) ? Double(max(0, totalBytes - doneBytes)) / bps : 0
        let complete = started && totalWeight > 0 && weightedSeen >= totalWeight
        return ClipProgressSnapshot(id: id, title: displayTitle, kind: .transferring,
            progressFraction: frac, completedRealBytes: doneBytes,
            totalRealBytes: totalBytes, bytesPerSec: bps, etaSeconds: eta,
            filesCompleted: started ? filesCompletedCount : 0, filesTotal: fileCount,
            currentName: currentName, cancelled: transferCancelled,
            isComplete: complete, chart: chart)
    }

    /// File count + total size from the resolved tree (known at resolve
    /// time, before any byte transfers).
    private func treeFileTotals() -> (count: Int, bytes: Int64) {
        var count = 0; var bytes: Int64 = 0
        for itemID in tree.allItemIDs() where itemID != self.id {
            if let m = tree.byID[itemID], !m.isDirectory { count += 1; bytes += m.size }
        }
        return (count, bytes)
    }

    /// The file tree for an event. Manually synchronized (mutated by the
    /// resolver before the registry re-locks to read it), hence
    /// `@unchecked Sendable`.
    nonisolated final class TreeStore: @unchecked Sendable {
        private(set) var byID: [String: ManifestItem] = [:]
        /// parentID → child ids in deterministic order. Top-level items
        /// are keyed under the empty string.
        private(set) var children: [String: [String]] = [:]

        init(items: [ManifestItem]) {
            byID.reserveCapacity(items.count)
            for it in items {
                byID[it.id] = it
                children[it.parentID ?? "", default: []].append(it.id)
            }
        }

        /// Atomically swap the tree contents. Used by resolvers after the
        /// FGDW finally arrives — the placeholder event was created with
        /// just the root folder; this replaces it with the full tree.
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
}

/// One chart point: speed (bps) at a fraction of progress.
struct ChartPoint: Sendable {
    let pct: Double
    let bps: Double
}

/// Immutable progress snapshot the UI polls. The store builds these under
/// its lock; the UI just renders them — no shared mutable state, no
/// ordered events, so no reordering bugs.
struct ClipProgressSnapshot: Sendable {
    enum Kind: Sendable { case resolving, transferring }
    let id: String
    let title: String
    let kind: Kind
    let progressFraction: Double
    let completedRealBytes: Int64
    let totalRealBytes: Int64
    let bytesPerSec: Double
    let etaSeconds: TimeInterval
    let filesCompleted: Int
    let filesTotal: Int
    let currentName: String
    let cancelled: Bool
    let isComplete: Bool
    let chart: [ChartPoint]
}

/// Lock-protected registry of all live `CopyEvent`s. Single source of
/// truth shared by the FileProvider XPC handlers and the UI. Nonisolated
/// (touched from sandbox XPC threads) and `@unchecked Sendable` (its
/// maps are guarded by `lock`).
nonisolated final class CopyEventStore: @unchecked Sendable {

    static let shared = CopyEventStore()

    // MARK: - UI hooks (poll model)

    /// Realtime-speed averaging window (seconds). Set once from config.
    var speedWindowSec: TimeInterval = 4
    /// After Cancel, keep failing fetches until the cancelled paste has been
    /// quiet this long — then a fresh request counts as a NEW paste and is
    /// allowed. Set once from config (clipboard.cancelReleaseMs).
    var cancelReleaseSec: TimeInterval = 3
    /// One-shot "activity started" wake so the UI can begin polling
    /// without a perpetual timer. Set by the UI at startup; called when a
    /// transfer or a paste-triggered resolve begins.
    private let wakeLock = NSLock()
    private var onActivity: (@Sendable () -> Void)?

    func setActivityWake(_ wake: @escaping @Sendable () -> Void) {
        wakeLock.lock(); onActivity = wake; wakeLock.unlock()
    }
    private func wakeUI() {
        wakeLock.lock(); let w = onActivity; wakeLock.unlock()
        w?()
    }

    /// Poll entry point for the UI: a consistent snapshot of every active
    /// row for a domain. Ages each event's speed window by `now` (the
    /// stall-decay "0-byte tick", folded into the poll — no extra timer).
    func progressSnapshots(domainSubdir: String, now: Date = Date()) -> [ClipProgressSnapshot] {
        lock.lock(); defer { lock.unlock() }
        return events.values
            .filter { $0.domainSubdir == domainSubdir }
            .compactMap { $0.makeSnapshot(now: now, windowSec: speedWindowSec) }
            .sorted { $0.id < $1.id }
    }

    /// Wait this long after a dismissed event goes idle (inFlight==0)
    /// before actually freeing it. Finder pauses between chunks
    /// sometimes; this prevents tearing down mid-transfer.
    private static let idleGracePeriod: TimeInterval = 30

    /// Debounce window for declaring a transfer burst drained. A paste's
    /// fetches dip to inFlight==0 between batches (sub-second); the user
    /// pasting again is seconds apart. A grace in between cleanly tells
    /// "same burst, brief lull" from "new paste". Tunable.

    private let lock = NSLock()
    /// All live events. Events persist after a newer copy supersedes them
    /// so an in-flight paste from the previous clipboard can still
    /// resolve items and fetch bytes.
    private var events: [String: CopyEvent] = [:]
    /// Root-container enumeration serves the LATEST event for a domain
    /// (matches Windows clipboard UX — only the newest copy is "the
    /// clipboard"). Old events stay reachable by direct itemID.
    private var currentByDomain: [String: String] = [:]
    private var itemToEvent: [String: String] = [:]

    // MARK: - Registration

    /// Create a copy event for one Windows clipboard copy. The event
    /// starts with just a placeholder root folder and doesn't yet know
    /// its tree — `resolver` fetches the FGDW and populates the tree.
    /// `resolver` runs exactly once, synchronously, the first time either
    /// (a) the rds layer calls `resolve()` proactively (eager mode) or
    /// (b) someone enumerates the placeholder's children (lazy mode, on
    /// paste). It must populate the event's `tree`, `idToListIndex`, and
    /// call `bindItemsToEvent` for every discovered item before returning.
    ///
    /// This single path serves BOTH eager and lazy — the event itself is
    /// mode-agnostic. Eager vs lazy is purely the rds layer's choice of
    /// whether to call `resolve()` up front and what to bind to the
    /// pasteboard.
    func create(domainSubdir: String,
                sessionID: String,
                placeholderItem: ManifestItem,
                fetcher: @escaping (_ itemID: String,
                                    _ offset: Int64,
                                    _ length: Int64) async -> (Data?, NSError?),
                resolver: @escaping (CopyEvent) -> Void,
                onCleanup: (() -> Void)? = nil) {
        let lazyResolver = resolver
        let event = CopyEvent(id: sessionID,
                              domainSubdir: domainSubdir,
                              displayTitle: placeholderItem.filename,
                              items: [placeholderItem],
                              fetcher: fetcher,
                              onCleanup: onCleanup)
        event.lazyResolver = lazyResolver
        lock.lock()
        let (cleanups, dismissed) = supersedeLocked(domainSubdir: domainSubdir, except: sessionID)
        events[sessionID] = event
        currentByDomain[domainSubdir] = sessionID
        itemToEvent[placeholderItem.id] = sessionID
        let liveCount = events.values.filter { $0.domainSubdir == domainSubdir }.count
        lock.unlock()
        Log.clip.info("Event '\(sessionID, privacy: .public)' created with placeholder '\(placeholderItem.filename, privacy: .public)'; \(liveCount, privacy: .public) live event(s) for domain")
        for c in cleanups { c() }
        for sid in dismissed { scheduleCleanupCheck(sessionID: sid) }
    }

    /// Proactively run an event's resolver (eager mode). Blocks until the
    /// FGDW has been fetched and the tree populated (or the resolve
    /// failed). No-op if already resolved. Safe to call off the main
    /// actor — the resolver does the wire I/O.
    func resolve(sessionID: String) {
        lock.lock()
        let event = events[sessionID]
        lock.unlock()
        guard let event else { return }
        runResolverIfNeeded(event, paste: false)
    }

    /// After an event is resolved, the placeholder root's children are
    /// the real top-level items the user copied. Eager mode publishes
    /// these + binds their URLs so Finder pastes with real names (no
    /// `MacRDP_<uuid>` wrapper). Returns nil if the event is gone or
    /// resolution failed.
    func resolvedTopLevel(sessionID: String) -> (placeholder: ManifestItem,
                                                  children: [ManifestItem])? {
        lock.lock(); defer { lock.unlock() }
        guard let event = events[sessionID] else { return nil }
        let roots = event.tree.childItems(of: "")          // placeholder folder(s)
        guard let placeholder = roots.first(where: { $0.id == sessionID }) else { return nil }
        let children = event.tree.childItems(of: sessionID) // real top-level items
        return (placeholder, children)
    }

    /// Bind a set of newly-discovered FileProvider item IDs to an event.
    /// Called by resolvers after they expand the placeholder into the
    /// full tree.
    func bindItemsToEvent(_ items: [ManifestItem], sessionID: String) {
        lock.lock()
        for it in items { itemToEvent[it.id] = sessionID }
        lock.unlock()
    }

    /// Look up the FGDW listIndex bound to a FileProvider item id. Used
    /// by byte fetchers: rather than capturing a pre-built map at closure
    /// creation time, they look up via the store so the resolver can
    /// populate the map later.
    func listIndex(for itemID: String) -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard let sid = itemToEvent[itemID] else { return nil }
        return events[sid]?.idToListIndex[itemID]
    }

    /// True if the event has been cancelled (user clicked Cancel in the
    /// copy-progress UI).
    func isSessionCancelled(sessionID: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let e = events[sessionID] else { return true }   // reaped → abandon
        if e.state == .ended || e.state == .cancelled || e.dismissed { return true }
        return false
    }

    /// The resolver couldn't build a tree, so it gave the placeholder a
    /// single unreadable `broken.bin` instead (see `isBrokenPlaceholder`).
    /// Flag the event so it shows no progress row; the caller schedules
    /// the drop once Finder has read-failed and reaped its destination.
    func serveBrokenPlaceholder(sessionID: String) {
        lock.lock()
        events[sessionID]?.isBrokenPlaceholder = true
        lock.unlock()
    }

    /// Tear an event down unconditionally (used after a broken placeholder
    /// has served its purpose). Removes it from the store + fires its
    /// cleanup (UNLOCK_CLIPDATA). The source placeholder is unpublished by
    /// the caller.
    func dropEvent(sessionID: String) {
        lock.lock()
        let cleanup = events[sessionID].flatMap {
            endEventLocked($0, reason: .resolveFailed("broken placeholder"))
        }
        lock.unlock()
        cleanup?()
    }

    /// User clicked Cancel in the progress UI. Move the event to `.cancelled`:
    /// the next fetch fails (Finder aborts the paste) and the state returns to
    /// `.resolved`, so the event stays alive and re-pasteable — a later paste
    /// (here or elsewhere) transfers normally.
    func cancelSession(sessionID: String) {
        lock.lock()
        if let e = events[sessionID] {
            e.state = .cancelled
            e.transferCancelled = true   // snapshot shows cancelled until the row drops
        }
        lock.unlock()
        Log.clip.notice("Event '\(sessionID, privacy: .public)' transfer cancelled by user (event kept)")
    }

    // MARK: - Supersede / end

    /// Called under `lock`. A new copy event is taking over the domain.
    /// An older event is ended immediately ONLY if it has never transferred
    /// a single byte (`transferStartedAt == nil`) — i.e. a never-pasted
    /// placeholder (idle, or eager-resolved-but-unpasted). Anything that
    /// has EVER transferred is merely dismissed and reaped once it's truly
    /// idle, so a paste that's mid-flight — including the gap *between* two
    /// FILECONTENTS request/response cycles (inFlight momentarily 0) — is
    /// never torn down (which would UNLOCK its FGDW and break the copy).
    /// Returns cleanups to fire and dismissed ids to schedule after unlock.
    private func supersedeLocked(domainSubdir: String, except keep: String)
        -> (cleanups: [() -> Void], dismissed: [String]) {
        var cleanups: [() -> Void] = []
        var dismissed: [String] = []
        for e in events.values where e.domainSubdir == domainSubdir && e.id != keep {
            // End immediately when it's safe: either Finder never touched it
            // (untouched placeholder) OR its transfer is DONE — all bytes
            // received (weightedSeen >= totalWeight) or cancelled. Reliable
            // signals, unlike a time gap: a paste that's resolving / between
            // fetches / partway through is NOT done, so it's kept and reaped
            // on idle rather than torn down mid-paste.
            let done = e.transferCancelled
                || (e.transferStartedAt != nil && e.totalWeight > 0
                    && e.weightedSeen >= e.totalWeight)
            let safeToEnd = e.inFlight == 0 && (!e.finderEngaged || done)
            if safeToEnd {
                if let c = endEventLocked(e, reason: .superseded) { cleanups.append(c) }
            } else if !e.dismissed {
                e.dismissed = true
                dismissed.append(e.id)
            }
        }
        return (cleanups, dismissed)
    }

    /// Called under `lock`. Logical end + physical removal from the maps.
    /// Returns the event's `onCleanup` to fire OUTSIDE the lock.
    @discardableResult
    private func endEventLocked(_ e: CopyEvent, reason: CopyEvent.EndReason) -> (() -> Void)? {
        e.state = .ended
        if e.endReason == nil { e.endReason = reason }
        for itemID in e.tree.allItemIDs() where itemToEvent[itemID] == e.id {
            itemToEvent.removeValue(forKey: itemID)
        }
        events.removeValue(forKey: e.id)
        if currentByDomain[e.domainSubdir] == e.id {
            currentByDomain.removeValue(forKey: e.domainSubdir)
        }
        return e.onCleanup
    }

    /// End and immediately free every event in a domain. Used on RDP
    /// client disconnect: the fetcher is dead, so nothing can complete —
    /// there's no point waiting for `inFlight` to drain. Fires each
    /// event's `onCleanup` (best-effort `CB_UNLOCK_CLIPDATA`).
    func endAll(domainSubdir: String, reason: CopyEvent.EndReason) {
        lock.lock()
        let victims = events.values.filter { $0.domainSubdir == domainSubdir }
        var cleanups: [() -> Void] = []
        for e in victims {
            if let c = endEventLocked(e, reason: reason) { cleanups.append(c) }
        }
        lock.unlock()
        Log.clip.info("All events for domain '\(domainSubdir, privacy: .public)' ended (\(victims.count, privacy: .public) victim(s))")
        for c in cleanups { c() }
    }

    // MARK: - Cleanup

    /// Decrement in-flight counter for the event that owns `itemID`,
    /// timestamp the activity, and schedule a cleanup probe if dismissed.
    private func fetchDidComplete(itemID: String) {
        lock.lock()
        let sessionID = itemToEvent[itemID]
        if let sessionID, let e = events[sessionID] {
            e.inFlight = max(0, e.inFlight - 1)
            e.lastActivityAt = Date()
            // State drains immediately (no debounce needed): the PROGRESS
            // bar no longer keys off this — its reset lives in
            // `CopyEvent.ingest` (finished-and-idle), so a mid-paste lull
            // flapping .transfer↔.resolved won't reset the row. State is
            // just for supersede/marquee bookkeeping.
            if e.inFlight == 0, e.state == .transfer {
                e.state = .resolved
            }
        }
        let dismissed = sessionID.flatMap { events[$0]?.dismissed } ?? false
        lock.unlock()
        if dismissed, let sessionID {
            scheduleCleanupCheck(sessionID: sessionID)
        }
    }

    /// Schedule a delayed cleanup probe for a dismissed event.
    private func scheduleCleanupCheck(sessionID: String) {
        DispatchQueue.global(qos: .background).asyncAfter(
            deadline: .now() + Self.idleGracePeriod
        ) { [weak self] in
            self?.tryCleanupSession(sessionID: sessionID)
        }
    }

    private func tryCleanupSession(sessionID: String) {
        lock.lock()
        guard let e = events[sessionID] else {
            lock.unlock(); return
        }
        guard e.dismissed else {
            lock.unlock(); return
        }
        guard e.inFlight == 0 else {
            lock.unlock(); return
        }
        guard Date().timeIntervalSince(e.lastActivityAt) >= Self.idleGracePeriod else {
            lock.unlock()
            // Activity since the probe was scheduled — re-arm.
            DispatchQueue.global(qos: .background).asyncAfter(
                deadline: .now() + Self.idleGracePeriod
            ) { [weak self] in
                self?.tryCleanupSession(sessionID: sessionID)
            }
            return
        }
        // Remove every item mapping owned by this event. Items the user
        // has since re-pushed (same id) shouldn't be removed —
        // itemToEvent[id] would point to the NEWER event.
        let cleanup = endEventLocked(e, reason: .superseded)
        let remaining = events.values.filter { $0.domainSubdir == e.domainSubdir }.count
        lock.unlock()
        Log.clip.info("Event '\(sessionID, privacy: .public)' cleaned up; \(remaining, privacy: .public) live event(s) remain for domain")
        // Fire onCleanup OUTSIDE the lock — typically sends CLIPRDR
        // CB_UNLOCK_CLIPDATA so the client can free the snapshot.
        cleanup?()
    }

    // MARK: - XPC handlers (called by HostFileProviderExporter)

    /// XPC entry point for the extension's `item(for:)`. If the item
    /// belongs to an unresolved event, fire the resolver synchronously
    /// here, then always reply(true) — the resolver guarantees a tree
    /// (real list, or a `broken.bin` stub whose byte fetch fails).
    func handleResolveItem(domainSubdir: String,
                           itemID: String,
                           reply: @escaping (Bool, NSError?) -> Void) {
        lock.lock()
        let event = itemToEvent[itemID].flatMap { events[$0] }
        event?.finderEngaged = true   // Finder is resolving an item → pasted
        lock.unlock()
        guard let event else {
            // Item we don't know about — extension's local cache decides.
            reply(true, nil)
            return
        }
        runResolverIfNeeded(event, paste: true)
        // The resolver always yields a usable tree now — either the real
        // file list or a single unreadable `broken.bin` whose byte fetch
        // fails (so Finder cleans up). Either way the item exists.
        reply(true, nil)
    }

    func handleEnumerateChildren(domainSubdir: String,
                                 containerID: String,
                                 reply: @escaping (Data?, NSError?) -> Void) {
        // If the container belongs to an unresolved event, run the
        // resolver synchronously here BEFORE computing children. Done
        // outside the global lock so the resolver can re-enter the store
        // (it must, to call bindItemsToEvent).
        if !containerID.isEmpty {
            lock.lock()
            let event = itemToEvent[containerID].flatMap { events[$0] }
            event?.finderEngaged = true   // Finder is reading the contents → pasted
            lock.unlock()
            if let event { runResolverIfNeeded(event, paste: true) }
        }

        lock.lock()
        let kids: [ManifestItem]
        if containerID.isEmpty {
            // Root: aggregate the synthetic event-folder entries from
            // every live event in this domain so the user sees all
            // concurrent copies. Sorted oldest-first via UUID ordering.
            var roots: [ManifestItem] = []
            for event in events.values where event.domainSubdir == domainSubdir {
                roots.append(contentsOf: event.tree.childItems(of: ""))
            }
            roots.sort { $0.id < $1.id }
            kids = roots
        } else {
            // A resolve failure now yields a `broken.bin` child (whose byte
            // fetch fails) rather than an enumerate error — so we always
            // return the tree's children as-is.
            let event = itemToEvent[containerID].flatMap { events[$0] }
            kids = event?.tree.childItems(of: containerID) ?? []
        }
        lock.unlock()
        do {
            let data = try JSONEncoder().encode(kids)
            reply(data, nil)
        } catch {
            reply(nil, error as NSError)
        }
    }

    func handleFetch(domainSubdir: String,
                     itemID: String,
                     offset: Int64,
                     length: Int64,
                     reply: @escaping (Data?, NSError?) -> Void) {
        lock.lock()
        let event = itemToEvent[itemID].flatMap { events[$0] }
        var startedTransfer = false
        if let event {
            // Ended (superseded / client-disconnected) → reject.
            if event.state == .ended {
                lock.unlock()
                reply(nil, NSError(domain: NSCocoaErrorDomain,
                                   code: NSUserCancelledError,
                                   userInfo: [NSLocalizedDescriptionKey: "Copy event ended"]))
                return
            }
            // User cancelled: keep failing every request (Finder retries the
            // materialization; one error doesn't make it give up) until the
            // cancelled paste stops asking for `cancelReleaseSec`. Only then
            // is a fresh request a NEW paste — drop back to .resolved and let
            // it transfer. The clipboard stays valid the whole time (event
            // kept), so a later paste here or elsewhere works.
            if event.state == .cancelled {
                let now = Date()
                if now.timeIntervalSince(event.lastActivityAt) <= cancelReleaseSec {
                    event.lastActivityAt = now   // still being retried → keep failing
                    lock.unlock()
                    // Use the SAME read-error the broken.bin path uses: Finder
                    // gives up a copy on a POSIX read error (EIO) but NOT on
                    // NSUserCancelledError (it just retries / keeps going).
                    reply(nil, NSError(domain: NSPOSIXErrorDomain, code: Int(EIO),
                                       userInfo: [NSLocalizedDescriptionKey: "Copy cancelled"]))
                    return
                }
                // Quiet long enough → the cancelled paste was abandoned.
                event.state = .resolved
                event.transferCancelled = false
                // fall through to the normal resolved → transfer path
            }
            // resolved/marquee → transfer. A new burst clears the cancelled
            // flag (carried only for the snapshot until the row drops).
            if event.state != .transfer {
                event.state = .transfer
                event.transferCancelled = false
                startedTransfer = true
            }
            event.finderEngaged = true   // bytes being copied → pasted
            event.inFlight += 1
            event.lastActivityAt = Date()
        }
        let fetcher = event?.fetcher
        lock.unlock()
        if startedTransfer { wakeUI() }   // nudge the UI to start polling
        guard let fetcher else {
            reply(nil, NSError(domain: "MacRDP.xpc", code: 404,
                userInfo: [NSLocalizedDescriptionKey:
                    "No event owns itemID \(itemID)"]))
            return
        }
        Task.detached {
            let (data, err) = await fetcher(itemID, offset, length)
            reply(data, err)
            self.fetchDidComplete(itemID: itemID)
            if err == nil, let data {
                self.recordChunk(itemID: itemID, offset: offset, length: Int64(data.count))
            }
        }
    }

    /// Fold delivered bytes into the owning event's progress accounting.
    private func recordChunk(itemID: String, offset: Int64, length: Int64) {
        lock.lock()
        itemToEvent[itemID].flatMap { events[$0] }?
            .ingest(itemID: itemID, offset: offset, length: length, now: Date())
        lock.unlock()
    }

    /// Run an event's lazy resolver if it hasn't fired yet. The lazyLock
    /// ensures only one of (resolveItem, enumerateChildren, proactive
    /// eager resolve) actually invokes the closure. The resolver runs
    /// OUTSIDE the global `lock`.
    private func runResolverIfNeeded(_ event: CopyEvent, paste: Bool) {
        event.lazyLock.lock()
        let resolver = event.lazyResolver
        if !event.lazyResolved, let resolver {
            event.lazyResolved = true
            event.lazyResolver = nil
            event.lazyLock.unlock()
            // idle → marquee: FGDW fetch in flight. `resolvingForPaste`
            // gates the marquee ROW — only a real paste shows it; eager's
            // proactive pre-paste resolve (paste == false) stays silent.
            lock.lock()
            let entered = (event.state == .idle)
            if entered { event.state = .marquee; event.resolvingForPaste = paste }
            lock.unlock()
            if entered, paste { wakeUI() }   // start the UI poller
            resolver(event)   // blocking; populates tree (real list or broken.bin)
            // marquee → resolved once the tree is known.
            lock.lock()
            if event.state == .marquee {
                event.state = .resolved
            }
            lock.unlock()
        } else {
            event.lazyLock.unlock()
        }
    }
}
