//
//  FileProviderXPCService.swift
//  MacRDP
//
//  Host side of the NSFileProviderService channel.
//
//  Stage 1 refactor: the per-event registry + lifecycle that used to
//  live here now lives in `CopyEventStore` (see CopyEvent.swift), which
//  is nonisolated + lock-protected so the extension's XPC threads and
//  the UI share one source of truth.
//
//  This file now holds:
//    * `FileProviderXPCService` — a thin @MainActor facade preserving the
//      registration / cancel API the rds layer calls (ClipboardBridge,
//      FileProviderInbox, CopyProgressTracker). Delegates to
//      `CopyEventStore.shared`.
//    * `HostFileProviderExporter` — the `exportedObject` for the
//      NSFileProviderService connection; the extension calls into this
//      when it needs bytes / children / item resolution. Delegates to
//      `CopyEventStore.shared`.
//
//  The actual NSXPCConnection is opened by `FileProviderInbox` after
//  publishing each manifest, which sets `HostFileProviderExporter` as the
//  connection's `exportedObject`.
//

import Foundation
import FileProvider
import os

@MainActor
final class FileProviderXPCService: NSObject {

    static let shared = FileProviderXPCService()

    // MARK: - Facade (→ CopyEventStore)
    //
    // The rds clipboard path (ClipboardBridge) talks to
    // `CopyEventStore.shared` directly. The only remaining MainActor entry
    // point is the progress UI's Cancel button.

    func cancelSession(sessionID: String) {
        CopyEventStore.shared.cancelSession(sessionID: sessionID)
    }
}

/// `exportedObject` for the NSFileProviderService connection on the host
/// side — the extension calls into this when it needs bytes / children /
/// item resolution. Routes by domain: redirected RDP drives go to the
/// live `DriveStore`, everything else to the clipboard `CopyEventStore`.
final class HostFileProviderExporter: NSObject, ExtensionToHostProtocol {

    nonisolated func fetchBytes(domainSubdir: String,
                                itemID: String,
                                offset: Int64,
                                length: Int64,
                                reply: @escaping (Data?, NSError?) -> Void) {
        if DriveStore.shared.handles(domainSubdir: domainSubdir) {
            DriveStore.shared.handleFetch(
                domainSubdir: domainSubdir, itemID: itemID,
                offset: offset, length: length, reply: reply)
        } else {
            CopyEventStore.shared.handleFetch(
                domainSubdir: domainSubdir, itemID: itemID,
                offset: offset, length: length, reply: reply)
        }
    }

    nonisolated func enumerateChildren(domainSubdir: String,
                                       containerID: String,
                                       reply: @escaping (Data?, NSError?) -> Void) {
        if DriveStore.shared.handles(domainSubdir: domainSubdir) {
            DriveStore.shared.handleEnumerateChildren(
                domainSubdir: domainSubdir, containerID: containerID, reply: reply)
        } else {
            CopyEventStore.shared.handleEnumerateChildren(
                domainSubdir: domainSubdir, containerID: containerID, reply: reply)
        }
    }

    nonisolated func resolveItem(domainSubdir: String,
                                  itemID: String,
                                  reply: @escaping (Bool, NSError?) -> Void) {
        if DriveStore.shared.handles(domainSubdir: domainSubdir) {
            DriveStore.shared.handleResolveItem(
                domainSubdir: domainSubdir, itemID: itemID, reply: reply)
        } else {
            CopyEventStore.shared.handleResolveItem(
                domainSubdir: domainSubdir, itemID: itemID, reply: reply)
        }
    }

    // MARK: Write path — only drive domains; clipboard is read-only.

    nonisolated func openWrite(domainSubdir: String, path: String,
                               reply: @escaping (NSNumber?, NSError?) -> Void) {
        guard DriveStore.shared.handles(domainSubdir: domainSubdir) else {
            reply(nil, Self.readOnly()); return
        }
        if let session = DriveStore.shared.openForWrite(itemID: path) {
            reply(NSNumber(value: session), nil)
        } else {
            reply(nil, Self.ioErr())
        }
    }

    nonisolated func writeChunk(domainSubdir: String, fileID: NSNumber, offset: Int64,
                                data: Data, reply: @escaping (NSError?) -> Void) {
        guard DriveStore.shared.handles(domainSubdir: domainSubdir) else {
            reply(Self.readOnly()); return
        }
        reply(DriveStore.shared.writeChunk(session: fileID.uint32Value,
                                           offset: offset, data: data) ? nil : Self.ioErr())
    }

    nonisolated func closeWrite(domainSubdir: String, fileID: NSNumber,
                                reply: @escaping (NSError?) -> Void) {
        guard DriveStore.shared.handles(domainSubdir: domainSubdir) else {
            reply(Self.readOnly()); return
        }
        reply(DriveStore.shared.closeWrite(session: fileID.uint32Value) ? nil : Self.ioErr())
    }

    nonisolated func createDirectory(domainSubdir: String, path: String,
                                     reply: @escaping (NSError?) -> Void) {
        guard DriveStore.shared.handles(domainSubdir: domainSubdir) else {
            reply(Self.readOnly()); return
        }
        reply(DriveStore.shared.createDirectory(itemID: path) ? nil : Self.ioErr())
    }

    nonisolated func deleteItem(domainSubdir: String, path: String, isDirectory: Bool,
                                reply: @escaping (NSError?) -> Void) {
        guard DriveStore.shared.handles(domainSubdir: domainSubdir) else {
            reply(Self.readOnly()); return
        }
        reply(DriveStore.shared.deleteItem(itemID: path, isDirectory: isDirectory) ? nil : Self.ioErr())
    }

    nonisolated func renameItem(domainSubdir: String, oldPath: String, newPath: String,
                                reply: @escaping (NSError?) -> Void) {
        guard DriveStore.shared.handles(domainSubdir: domainSubdir) else {
            reply(Self.readOnly()); return
        }
        reply(DriveStore.shared.renameItem(oldItemID: oldPath, newItemID: newPath) ? nil : Self.ioErr())
    }

    private static func readOnly() -> NSError {
        NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError,
                userInfo: [NSLocalizedDescriptionKey: "This domain is read-only"])
    }
    private static func ioErr() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(EIO),
                userInfo: [NSLocalizedDescriptionKey: "Drive write failed"])
    }
}
