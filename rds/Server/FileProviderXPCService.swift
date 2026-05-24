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
/// item resolution. Delegates to the shared `CopyEventStore`.
final class HostFileProviderExporter: NSObject, ExtensionToHostProtocol {

    nonisolated func fetchBytes(domainSubdir: String,
                                itemID: String,
                                offset: Int64,
                                length: Int64,
                                reply: @escaping (Data?, NSError?) -> Void) {
        CopyEventStore.shared.handleFetch(
            domainSubdir: domainSubdir,
            itemID: itemID,
            offset: offset,
            length: length,
            reply: reply)
    }

    nonisolated func enumerateChildren(domainSubdir: String,
                                       containerID: String,
                                       reply: @escaping (Data?, NSError?) -> Void) {
        CopyEventStore.shared.handleEnumerateChildren(
            domainSubdir: domainSubdir,
            containerID: containerID,
            reply: reply)
    }

    nonisolated func resolveItem(domainSubdir: String,
                                  itemID: String,
                                  reply: @escaping (Bool, NSError?) -> Void) {
        CopyEventStore.shared.handleResolveItem(
            domainSubdir: domainSubdir,
            itemID: itemID,
            reply: reply)
    }
}
