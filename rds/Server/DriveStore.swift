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

/// The single "RDP Drives" FileProvider domain. Registered when the first
/// drive mounts, unregistered when the last unmounts. Each drive is a
/// published top-level folder; `DriveStore` serves the live contents.
@MainActor
final class DriveDomains {
    static let shared = DriveDomains()
    private init() {}

    /// Fixed id; the "drive-" prefix marks the domain writable (see the
    /// extension's `isWritable`). subdir == id (AppGroupShared is 1:1).
    nonisolated static let domainID = "\(AppGroupShared.driveDomainPrefix)shared"
    nonisolated static var domainSubdir: String { AppGroupShared.domainSubdir(for: domainID) }

    private var inbox: FileProviderInbox?
    private var folders: [String: String] = [:]   // driveKey → display label

    /// Add (or relabel) a drive folder, registering the domain on first use.
    func addFolder(driveKey: String, label: String) async {
        if inbox == nil {
            let i = FileProviderInbox(domainID: Self.domainID, displayName: "RDP Drives")
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

    private func republish() async {
        let items = folders.map {
            FileProviderInbox.PublishItem(id: $0.key, filename: $0.value, parentID: nil,
                                          isDirectory: true, size: 0, modificationMs: nil)
        }
        try? await inbox?.publish(items)
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
        var openFiles: [String: UInt32] = [:]   // winPath → client fileId (reads)
        init(adapter: BridgePeer, deviceID: UInt32, label: String) {
            self.adapter = adapter; self.deviceID = deviceID; self.label = label
        }
    }
    private var drives: [String: Drive] = [:]   // driveKey → Drive

    /// All requests for the single drives domain route here.
    func handles(domainSubdir: String) -> Bool {
        domainSubdir == DriveDomains.domainSubdir
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

    func addDrive(adapter: BridgePeer, deviceID: UInt32, dosName: String) {
        // DOS names arrive as e.g. "D:" — strip the trailing colon (and any
        // NUL padding). A literal ":" in the display name is rendered by
        // Finder as "/", because macOS swaps ':' and '/' at the Carbon layer.
        let trimmed = dosName.trimmingCharacters(in: CharacterSet(charactersIn: " \0:"))
        let label = trimmed.isEmpty ? "Drive" : trimmed
        // STABLE key derived from the drive name, NOT a per-mount UUID. The
        // key is the prefix of every FileProvider item id under this drive;
        // a fresh UUID each mount made all ids go stale after a reconnect, so
        // resolve() failed and delete/rename silently no-op'd on Windows while
        // Finder optimistically updated. The drive letter is stable across
        // reconnects, so ids stay valid. (Must be backslash-free — it is: the
        // label has had any ':' stripped and DOS names carry no '\'.)
        let driveKey = label
        lock.lock(); drives[driveKey] = Drive(adapter: adapter, deviceID: deviceID, label: label); lock.unlock()
        Log.session.notice("RDPDR mounting drive '\(label, privacy: .public)' id=\(deviceID, privacy: .public) key=\(driveKey, privacy: .public)")
        Task { @MainActor in await DriveDomains.shared.addFolder(driveKey: driveKey, label: label) }
    }

    func removeDrive(adapter: BridgePeer, deviceID: UInt32) {
        teardown { $0.adapter === adapter && $0.deviceID == deviceID }
    }

    func removeAllDrives(adapter: BridgePeer) {
        teardown { $0.adapter === adapter }
    }

    private func teardown(_ match: (Drive) -> Bool) {
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
        for (key, d) in victims {
            for (_, fid) in d.openFiles {   // fire-and-forget close (token 0 = no pending)
                d.adapter.rdpdrCloseFile(token: 0, deviceID: d.deviceID, fileID: fid)
            }
            Task { @MainActor in await DriveDomains.shared.removeFolder(driveKey: key) }
        }
    }

    // MARK: - XPC read entry points

    func handleEnumerateChildren(domainSubdir: String, containerID: String,
                                 reply: @escaping (Data?, NSError?) -> Void) {
        // Root: list the drive folders (normally served from the published
        // manifest, but answer defensively if asked).
        if containerID.isEmpty {
            lock.lock()
            let folders = drives.map { (key, d) in
                ManifestItem(id: key, filename: d.label, size: 0,
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
