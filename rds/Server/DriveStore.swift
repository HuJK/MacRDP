//
//  DriveStore.swift
//  rds
//
//  Win→Mac drive redirection (RDPDR / MS-RDPEFS). All redirected drives
//  from all sessions live under ONE FileProvider domain ("RDP Drives"),
//  each appearing as a top-level folder — so Finder shows a single
//  Location, not one per drive. The drive folders are published like the
//  clipboard's placeholders (manifest-backed); each folder's CONTENTS are
//  enumerated and read/written LIVE via RDPDR IRPs.
//
//  Item identity encodes the drive:
//    "<driveKey>"            → the drive's root folder
//    "<driveKey>\<winpath>"  → an item inside that drive
//  `driveKey` is a UUID (no backslash), so the first backslash splits it.
//
//  Threading: enumerate/fetch/write run on FileProvider XPC threads (they
//  block). IRPs are issued via `BridgePeer` and answered on the FreeRDP
//  channel thread, which signals the matching pending request by token.
//  `lock` guards the registry + pending/session maps; semaphore waits
//  happen OUTSIDE the lock.
//

import Foundation
import FileProvider
import os

/// One FileProvider domain PER connected client, so two clients that both
/// share "C:" don't collide and a disconnect can tear down just that client's
/// drives. Created lazily when the client's first drive mounts; unregistered
/// when the session ends (`unregisterAll`) or its last drive unmounts. Each
/// redirected drive is a published top-level folder; `DriveStore` serves the
/// live contents. Owned by the `RDPSession`.
@MainActor
final class DriveDomain {

    /// Unique per session. Identifier is `<user>-<n>` (no `MacRDP-` prefix);
    /// macOS auto-prefixes the CloudStorage folder with the app name, giving
    /// `MacRDP-<user>-<n>`. Writability is now keyed in the extension by
    /// `AppGroupShared.isWritableDomain`, not the identifier prefix.
    /// subdir == id (AppGroupShared is 1:1).
    let domainID: String
    let subdir: String
    private let displayName: String
    private let index: Int

    private var inbox: FileProviderInbox?
    private var folders: [String: String] = [:]   // driveKey → display label

    /// Indices currently in use across all live drive domains, so each new
    /// domain takes the smallest free integer. Single client → always 0;
    /// multi-client (future) → 1, 2, … Freed in `unregisterAll`.
    private static var usedIndices: Set<Int> = []

    /// id = `drive-<user>-<n>` where `n` is the smallest free index. Stable for
    /// the common single-client case (always `…-0`), so a reconnect reuses the
    /// same domain rather than leaking a new one.
    init(clientLabel: String) {
        var n = 0
        while Self.usedIndices.contains(n) { n += 1 }
        Self.usedIndices.insert(n)
        self.index = n

        let base = clientLabel.isEmpty ? "client" : clientLabel
        // Filesystem/identifier-safe token: keep alphanumerics, others → '-'.
        let user = String(base.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) ? Character($0) : "-"
        }).lowercased()
        // Identifier WITHOUT any "MacRDP-" prefix — macOS auto-prefixes the
        // CloudStorage folder with the app name "MacRDP", giving the clean
        // `MacRDP-<user>-<n>`. Putting "MacRDP-" in the identifier would
        // double it ("MacRDP-MacRDP-…").
        self.domainID = "\(user)-\(n)"
        self.subdir = AppGroupShared.domainSubdir(for: domainID)
        // displayName does NOT include "MacRDP" — when an app has more than one
        // FileProvider domain, Finder renders each as "<app> - <displayName>",
        // so any "MacRDP" we put here gets doubled in the sidebar
        // ("MacRDP - MacRDP HuJK"). Just the label → "MacRDP - HuJK".
        self.displayName = clientLabel.isEmpty ? "Drives" : clientLabel
    }

    /// Add (or relabel) a drive folder, registering the domain on first use.
    func addFolder(driveKey: String, label: String) async {
        if inbox == nil {
            let i = FileProviderInbox(domainID: domainID, displayName: displayName)
            inbox = i
            await i.register()
        }
        folders[driveKey] = label
        await republish()
    }

    /// Remove one drive folder; tear the domain down when none remain.
    func removeFolder(driveKey: String) async {
        folders[driveKey] = nil
        guard let inbox else { return }
        if folders.isEmpty {
            await inbox.unregister()
            self.inbox = nil
        } else {
            await inbox.unpublishItem(id: driveKey)
        }
    }

    /// Tear the whole domain down — call on session end.
    func unregisterAll() async {
        folders.removeAll()
        Self.usedIndices.remove(index)
        guard let inbox else { return }
        await inbox.unregister()
        self.inbox = nil
    }

    /// User-visible Finder URL for a drive's root folder (for "open in Finder").
    func userVisibleURL(driveKey: String) async -> URL? {
        guard let inbox, let label = folders[driveKey] else { return nil }
        return await inbox.userVisibleURL(itemID: driveKey, filename: label)
    }

    private func republish() async {
        let items = folders.map {
            FileProviderInbox.PublishItem(id: $0.key, filename: $0.value, parentID: nil,
                                          isDirectory: true, size: 0, modificationMs: nil)
        }
        try? await inbox?.publish(items)
    }

    /// Remove every FileProvider domain this app owns (drive + clipboard).
    /// `getDomains` only returns the current app's domains, so this is scoped
    /// to MacRDP. Run at startup to wipe leftovers from a previous crash /
    /// force-quit (exit-time async removal usually can't finish before the
    /// process dies — startup is the reliable cleanup point).
    @MainActor
    static func removeAllAppDomains() async {
        let domains: [NSFileProviderDomain] = await withCheckedContinuation { cont in
            NSFileProviderManager.getDomainsWithCompletionHandler { domains, _ in
                cont.resume(returning: domains)
            }
        }
        Self.usedIndices.removeAll()
        for d in domains {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                NSFileProviderManager.remove(d) { _ in cont.resume() }
            }
            Log.server.notice("Removed leftover FileProvider domain \(d.identifier.rawValue, privacy: .public)")
        }
    }
}

nonisolated final class DriveStore: @unchecked Sendable {
    static let shared = DriveStore()
    private init() {}

    private let lock = NSLock()

    // MARK: NT create constants (passed to DriveOpenFile)
    private static let FILE_READ_DATA:        UInt32 = 0x0001
    private static let FILE_WRITE_DATA:       UInt32 = 0x0002
    private static let FILE_READ_ATTRIBUTES:  UInt32 = 0x0080
    private static let FILE_OPEN:             UInt32 = 1       // open existing
    private static let FILE_OVERWRITE_IF:     UInt32 = 5       // create/truncate
    private static let FILE_ATTRIBUTE_DIRECTORY: UInt32 = 0x10
    private static let STATUS_SUCCESS:        UInt32 = 0
    private static let ioTimeout: DispatchTimeInterval = .seconds(30)

    // MARK: - Drive registry (keyed by driveKey)

    private final class Drive {
        let adapter: BridgePeer
        let deviceID: UInt32
        let label: String
        /// The owning client's per-session FileProvider domain subdir.
        let domainSubdir: String
        var openFiles: [String: UInt32] = [:]   // winPath → client fileId (reads)
        init(adapter: BridgePeer, deviceID: UInt32, label: String, domainSubdir: String) {
            self.adapter = adapter; self.deviceID = deviceID
            self.label = label; self.domainSubdir = domainSubdir
        }
    }
    private var drives: [String: Drive] = [:]   // driveKey → Drive

    /// True if any active drive belongs to this (per-client) domain.
    func handles(domainSubdir: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return drives.values.contains { $0.domainSubdir == domainSubdir }
    }

    /// Drives belonging to one client (by its bridge), for the menu-bar list.
    func drives(adapter: BridgePeer) -> [(key: String, label: String)] {
        lock.lock(); defer { lock.unlock() }
        return drives.compactMap { (k, d) in d.adapter === adapter ? (k, d.label) : nil }
            .sorted { $0.label < $1.label }
    }

    /// Split an item id into its owning drive + the backslash path within
    /// it ("" = the drive's root folder).
    private func resolve(_ itemID: String) -> (drive: Drive, winPath: String)? {
        let key: String, path: String
        if let slash = itemID.firstIndex(of: "\\") {
            key = String(itemID[..<slash]); path = String(itemID[slash...])
        } else {
            key = itemID; path = ""
        }
        lock.lock(); let d = drives[key]; lock.unlock()
        guard let d else { return nil }
        return (d, path)
    }

    // MARK: - Pending IRP correlation (token → request)

    private final class Pending {
        let sem = DispatchSemaphore(value: 0)
        var ioStatus: UInt32 = 0
        var fileID: UInt32 = 0
        var data = Data()
        var bytesWritten: UInt32 = 0
        var entries: [RawEntry] = []
    }
    private struct RawEntry { let name: String; let isDir: Bool; let size: UInt64; let mtimeMs: Int64 }

    private var nextToken: UInt64 = 1
    private var pending: [UInt64: Pending] = [:]

    // Write sessions: a raw RDP fileId isn't unique across drives, so a
    // write hands the extension an opaque session id mapping to the drive.
    private var nextWriteSession: UInt32 = 1
    private var writeSessions: [UInt32: (driveKey: String, fileID: UInt32)] = [:]

    private func startRequest() -> (UInt64, Pending) {
        lock.lock(); defer { lock.unlock() }
        let t = nextToken; nextToken &+= 1; if nextToken == 0 { nextToken = 1 }
        let p = Pending(); pending[t] = p
        return (t, p)
    }
    private func endRequest(_ token: UInt64) {
        lock.lock(); pending[token] = nil; lock.unlock()
    }

    // MARK: - Drive lifecycle (called from RDPSession sinks)

    /// Register a drive in the routing registry. Returns the (globally unique)
    /// driveKey + display label so the caller can publish a matching folder
    /// into the session's `DriveDomain`. Returns nil for non-filesystem
    /// devices. The session owns the domain (per-client), so publishing is the
    /// caller's responsibility — this keeps DriveStore free of MainActor hops.
    func addDrive(adapter: BridgePeer, deviceID: UInt32, dosName: String,
                  domainSubdir: String) -> (key: String, label: String)? {
        // DOS names arrive as e.g. "D:" — strip the trailing colon (and any
        // NUL padding). A literal ":" in the display name is rendered by
        // Finder as "/", because macOS swaps ':' and '/' at the Carbon layer.
        let trimmed = dosName.trimmingCharacters(in: CharacterSet(charactersIn: " \0:"))
        let label = trimmed.isEmpty ? "Drive" : trimmed
        // Globally unique key = domain subdir + label. Scoping by the
        // per-client domain means two clients sharing "C:" no longer collide
        // in the shared registry. Must be backslash-free (it is: subdir is
        // "drive-<hex>", label has ':' stripped, DOS names carry no '\') since
        // the key is the prefix of every FileProvider item id under this drive.
        let driveKey = "\(domainSubdir)~\(label)"
        lock.lock()
        drives[driveKey] = Drive(adapter: adapter, deviceID: deviceID,
                                 label: label, domainSubdir: domainSubdir)
        lock.unlock()
        Log.session.notice("RDPDR mounting drive '\(label, privacy: .public)' id=\(deviceID, privacy: .public) key=\(driveKey, privacy: .public)")
        return (driveKey, label)
    }

    /// Remove one drive; returns its driveKey so the caller can unpublish the
    /// matching folder from its `DriveDomain`.
    @discardableResult
    func removeDrive(adapter: BridgePeer, deviceID: UInt32) -> String? {
        teardown { $0.adapter === adapter && $0.deviceID == deviceID }.first
    }

    func removeAllDrives(adapter: BridgePeer) {
        _ = teardown { $0.adapter === adapter }
    }

    @discardableResult
    private func teardown(_ match: (Drive) -> Bool) -> [String] {
        lock.lock()
        let victims = drives.filter { match($0.value) }
        for (key, _) in victims { drives[key] = nil }
        // Drop write sessions belonging to removed drives.
        for (sid, s) in writeSessions where victims[s.driveKey] != nil { writeSessions[sid] = nil }
        // If no drives remain (e.g. the RDP session dropped), wake every
        // in-flight IRP waiter with a failure so blocked XPC calls return an
        // error immediately instead of hanging for `ioTimeout`. Otherwise a
        // disconnect mid-operation looks like a silent stall to Finder.
        if drives.isEmpty {
            for (_, p) in pending {
                p.ioStatus = 0xC0000120   // STATUS_CANCELLED
                p.sem.signal()
            }
        }
        lock.unlock()
        for (_, d) in victims {
            for (_, fid) in d.openFiles {   // fire-and-forget close (token 0 = no pending)
                d.adapter.rdpdrCloseFile(token: 0, deviceID: d.deviceID, fileID: fid)
            }
        }
        // The caller (session) unpublishes folders + unregisters the domain.
        return Array(victims.keys)
    }

    // MARK: - XPC read entry points

    func handleEnumerateChildren(domainSubdir: String, containerID: String,
                                 reply: @escaping (Data?, NSError?) -> Void) {
        // Root: list this domain's drive folders (normally served from the
        // published manifest, but answer defensively if asked). Filter by
        // domainSubdir so each client's domain only shows its own drives.
        if containerID.isEmpty {
            lock.lock()
            let folders = drives.compactMap { (key, d) -> ManifestItem? in
                guard d.domainSubdir == domainSubdir else { return nil }
                return ManifestItem(id: key, filename: d.label, size: 0,
                                    parentID: nil, isDirectory: true, modificationMs: nil)
            }
            lock.unlock()
            do { reply(try JSONEncoder().encode(folders), nil) }
            catch { reply(nil, error as NSError) }
            return
        }
        guard let (d, winPath) = resolve(containerID) else { reply(nil, Self.gone()); return }
        let (token, p) = startRequest()
        guard d.adapter.rdpdrQueryDir(token: token, deviceID: d.deviceID, path: winPath) else {
            endRequest(token); reply(nil, Self.gone()); return
        }
        let waited = p.sem.wait(timeout: .now() + Self.ioTimeout)
        let entries = p.entries
        endRequest(token)
        guard waited == .success else { reply(nil, Self.timedOut()); return }

        let kids: [ManifestItem] = entries.map { e in
            let childID = containerID + "\\" + e.name
            return ManifestItem(id: childID, filename: e.name, size: Int64(e.size),
                                parentID: containerID, isDirectory: e.isDir,
                                modificationMs: e.mtimeMs > 0 ? e.mtimeMs : nil)
        }
        do { reply(try JSONEncoder().encode(kids), nil) }
        catch { reply(nil, error as NSError) }
    }

    func handleFetch(domainSubdir: String, itemID: String, offset: Int64, length: Int64,
                     reply: @escaping (Data?, NSError?) -> Void) {
        guard let (d, winPath) = resolve(itemID) else { reply(nil, Self.gone()); return }
        guard let fileID = openForRead(d, path: winPath) else { reply(nil, Self.ioError()); return }
        let (token, p) = startRequest()
        guard d.adapter.rdpdrReadFile(token: token, deviceID: d.deviceID, fileID: fileID,
                                      length: UInt32(clamping: length),
                                      offset: UInt32(truncatingIfNeeded: offset)) else {
            endRequest(token); reply(nil, Self.ioError()); return
        }
        let waited = p.sem.wait(timeout: .now() + Self.ioTimeout)
        let status = p.ioStatus, data = p.data
        endRequest(token)
        guard waited == .success, status == Self.STATUS_SUCCESS else {
            reply(nil, Self.ioError()); return
        }
        reply(data, nil)
    }

    func handleResolveItem(domainSubdir: String, itemID: String,
                           reply: @escaping (Bool, NSError?) -> Void) {
        reply(true, nil)   // live drive — the actual read/enumerate validates
    }

    private func openForRead(_ d: Drive, path: String) -> UInt32? {
        lock.lock()
        if let fid = d.openFiles[path] { lock.unlock(); return fid }
        lock.unlock()
        let (token, p) = startRequest()
        guard d.adapter.rdpdrOpenFile(token: token, deviceID: d.deviceID, path: path,
                                      desiredAccess: Self.FILE_READ_DATA | Self.FILE_READ_ATTRIBUTES,
                                      createDisposition: Self.FILE_OPEN) else {
            endRequest(token); return nil
        }
        let waited = p.sem.wait(timeout: .now() + Self.ioTimeout)
        let status = p.ioStatus, fid = p.fileID
        endRequest(token)
        guard waited == .success, status == Self.STATUS_SUCCESS else { return nil }
        lock.lock(); d.openFiles[path] = fid; lock.unlock()
        return fid
    }

    // MARK: - XPC write entry points

    /// Open `itemID` for writing (create or truncate). Returns an opaque
    /// write-session id the caller passes to `writeChunk`/`closeWrite`.
    func openForWrite(itemID: String) -> UInt32? {
        guard let (d, winPath) = resolve(itemID) else { return nil }
        let (token, p) = startRequest()
        guard d.adapter.rdpdrOpenFile(token: token, deviceID: d.deviceID, path: winPath,
                                      desiredAccess: Self.FILE_WRITE_DATA | Self.FILE_READ_DATA,
                                      createDisposition: Self.FILE_OVERWRITE_IF) else {
            endRequest(token); return nil
        }
        let waited = p.sem.wait(timeout: .now() + Self.ioTimeout)
        let status = p.ioStatus, fid = p.fileID
        endRequest(token)
        guard waited == .success, status == Self.STATUS_SUCCESS else { return nil }
        let driveKey = String(itemID[..<(itemID.firstIndex(of: "\\") ?? itemID.endIndex)])
        lock.lock()
        let sid = nextWriteSession; nextWriteSession &+= 1; if nextWriteSession == 0 { nextWriteSession = 1 }
        writeSessions[sid] = (driveKey, fid)
        lock.unlock()
        return sid
    }

    func writeChunk(session: UInt32, offset: Int64, data: Data) -> Bool {
        guard let (d, fileID) = writeSession(session) else { return false }
        let (token, p) = startRequest()
        guard d.adapter.rdpdrWriteFile(token: token, deviceID: d.deviceID, fileID: fileID,
                                       data: data, offset: UInt32(truncatingIfNeeded: offset)) else {
            endRequest(token); return false
        }
        let waited = p.sem.wait(timeout: .now() + Self.ioTimeout)
        let status = p.ioStatus
        endRequest(token)
        return waited == .success && status == Self.STATUS_SUCCESS
    }

    func closeWrite(session: UInt32) -> Bool {
        guard let (d, fileID) = writeSession(session) else { return false }
        lock.lock(); writeSessions[session] = nil; lock.unlock()
        return issue { token in d.adapter.rdpdrCloseFile(token: token, deviceID: d.deviceID, fileID: fileID) }
    }

    func createDirectory(itemID: String) -> Bool {
        guard let (d, winPath) = resolve(itemID) else { return false }
        return issue { token in d.adapter.rdpdrCreateDir(token: token, deviceID: d.deviceID, path: winPath) }
    }

    func deleteItem(itemID: String, isDirectory: Bool) -> Bool {
        guard let (d, winPath) = resolve(itemID) else { return false }
        lock.lock(); d.openFiles[winPath] = nil; lock.unlock()
        return issue { token in
            isDirectory ? d.adapter.rdpdrDeleteDir(token: token, deviceID: d.deviceID, path: winPath)
                        : d.adapter.rdpdrDeleteFile(token: token, deviceID: d.deviceID, path: winPath)
        }
    }

    func renameItem(oldItemID: String, newItemID: String) -> Bool {
        guard let (d, oldPath) = resolve(oldItemID), let (_, newPath) = resolve(newItemID) else { return false }
        lock.lock(); d.openFiles[oldPath] = nil; lock.unlock()
        return issue { token in
            d.adapter.rdpdrRenameFile(token: token, deviceID: d.deviceID,
                                      oldPath: oldPath, newPath: newPath)
        }
    }

    private func writeSession(_ sid: UInt32) -> (Drive, UInt32)? {
        lock.lock(); defer { lock.unlock() }
        guard let s = writeSessions[sid], let d = drives[s.driveKey] else { return nil }
        return (d, s.fileID)
    }

    /// Issue an IRP that only reports an ioStatus, and block for it.
    private func issue(_ send: (UInt64) -> Bool) -> Bool {
        let (token, p) = startRequest()
        guard send(token) else { endRequest(token); return false }
        let waited = p.sem.wait(timeout: .now() + Self.ioTimeout)
        let status = p.ioStatus
        endRequest(token)
        return waited == .success && status == Self.STATUS_SUCCESS
    }

    // MARK: - IRP completions (called from BridgePeer sinks, channel thread)

    func onDirEntry(token: UInt64, isEntry: Bool, ioStatus: UInt32,
                    name: String, attributes: UInt32, size: UInt64, mtimeMs: Int64) {
        lock.lock()
        guard let p = pending[token] else { lock.unlock(); return }
        if isEntry {
            if name != "." && name != ".." {
                p.entries.append(RawEntry(name: name,
                                          isDir: (attributes & Self.FILE_ATTRIBUTE_DIRECTORY) != 0,
                                          size: size, mtimeMs: mtimeMs))
            }
            lock.unlock()
        } else {
            p.ioStatus = ioStatus
            lock.unlock()
            p.sem.signal()   // terminal: no more entries
        }
    }

    func onOpenComplete(token: UInt64, ioStatus: UInt32, deviceID: UInt32, fileID: UInt32) {
        signal(token) { $0.ioStatus = ioStatus; $0.fileID = fileID }
    }
    func onReadComplete(token: UInt64, ioStatus: UInt32, data: Data) {
        signal(token) { $0.ioStatus = ioStatus; $0.data = data }
    }
    func onWriteComplete(token: UInt64, ioStatus: UInt32, bytesWritten: UInt32) {
        signal(token) { $0.ioStatus = ioStatus; $0.bytesWritten = bytesWritten }
    }
    func onCloseComplete(token: UInt64, ioStatus: UInt32) {
        signal(token) { $0.ioStatus = ioStatus }
    }
    func onSimpleComplete(token: UInt64, ioStatus: UInt32) {
        signal(token) { $0.ioStatus = ioStatus }
    }

    private func signal(_ token: UInt64, _ fill: (Pending) -> Void) {
        lock.lock()
        guard let p = pending[token] else { lock.unlock(); return }
        fill(p)
        lock.unlock()
        p.sem.signal()
    }

    // MARK: - Errors

    private static func gone() -> NSError {
        NSError(domain: NSFileProviderErrorDomain,
                code: NSFileProviderError.noSuchItem.rawValue,
                userInfo: [NSLocalizedDescriptionKey: "Drive no longer mounted"])
    }
    private static func timedOut() -> NSError {
        NSError(domain: NSFileProviderErrorDomain,
                code: NSFileProviderError.serverUnreachable.rawValue,
                userInfo: [NSLocalizedDescriptionKey: "RDPDR request timed out"])
    }
    private static func ioError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(EIO),
                userInfo: [NSLocalizedDescriptionKey: "Could not read from the redirected drive"])
    }
}
