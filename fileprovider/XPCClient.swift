//
//  XPCClient.swift
//  fileprovider
//
//  Drives the EXTENSION → HOST direction of the NSFileProviderService
//  XPC connection — i.e. byte fetches during `fetchContents`.
//
//  The connection itself is OPENED by the host (`getService(named:)`),
//  accepted by `ClipboardServiceSource.listener(_:shouldAcceptNewConnection:)`,
//  and the proxy is obtained via `ClipboardServiceSource.hostProxy(...)`.
//

import Foundation
import os

private let log = Logger(subsystem: "com.macrdp.server", category: "fileprovider-xpc")

enum HostChildEnumerator {

    /// Synchronously ask the host for one container's immediate
    /// children. Returns nil on transport error / timeout — caller
    /// should fall back to local cache or empty enumeration.
    /// Blocking-by-design: FileProvider enumerator paths are
    /// synchronous-ish, so we use a semaphore.
    static func fetchChildrenSync(source: ClipboardServiceSource,
                                  domainSubdir: String,
                                  containerID: String,
                                  timeout: TimeInterval = 30) -> [ManifestItem]? {
        let sem = DispatchSemaphore(value: 0)
        var result: Data?
        var errored = false
        let proxy = source.hostProxy { err in
            log.error("enumerateChildren proxy error: \(String(describing: err), privacy: .public)")
            errored = true
            sem.signal()
        }
        guard let proxy else {
            log.error("enumerateChildren: no host connection")
            return nil
        }
        proxy.enumerateChildren(domainSubdir: domainSubdir,
                                 containerID: containerID) { data, err in
            if let err {
                log.error("enumerateChildren reply error: \(String(describing: err), privacy: .public)")
            }
            result = data
            sem.signal()
        }
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            log.notice("enumerateChildren timed out (\(timeout, privacy: .public)s) cid=\(containerID, privacy: .public)")
            return nil
        }
        if errored { return nil }
        guard let data = result else { return nil }
        do {
            return try JSONDecoder().decode([ManifestItem].self, from: data)
        } catch {
            log.error("enumerateChildren decode failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}

/// Blocking helper around the new `resolveItem` XPC method. Used by
/// FileProviderExtension.item(for:) to ensure that the lazy
/// resolver has run before we tell Finder the placeholder folder
/// exists. Returns true iff the item exists post-resolve.
enum HostLazyResolver {
    static func resolveSync(source: ClipboardServiceSource,
                            domainSubdir: String,
                            itemID: String,
                            timeout: TimeInterval = 600) -> Bool {
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        var errored = false
        let proxy = source.hostProxy { err in
            log.error("resolveItem proxy error: \(String(describing: err), privacy: .public)")
            errored = true
            sem.signal()
        }
        guard let proxy else {
            log.error("resolveItem: no host connection")
            return false
        }
        proxy.resolveItem(domainSubdir: domainSubdir,
                          itemID: itemID) { exists, err in
            if let err {
                log.error("resolveItem reply error: \(String(describing: err), privacy: .public)")
            }
            ok = exists
            sem.signal()
        }
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            log.notice("resolveItem timed out (\(timeout, privacy: .public)s) itemID=\(itemID, privacy: .public)")
            return false
        }
        if errored { return false }
        return ok
    }
}

enum HostByteFetcher {

    /// Tunables. mstsc / RDP transfer is the bottleneck; 1 MiB chunks
    /// keep per-request overhead low without blowing memory.
    static let chunkSize: Int64 = 1024 * 1024

    /// Stream a file from the host into `handle`, `chunkSize` bytes per
    /// RPC. Updates `progress` after each chunk.
    static func fetchInto(handle: FileHandle,
                          source: ClipboardServiceSource,
                          domainSubdir: String,
                          itemID: String,
                          totalSize: Int64,
                          progress: Progress) async throws {
        if totalSize == 0 { return }
        log.info("HostByteFetcher start id=\(itemID, privacy: .public) total=\(totalSize, privacy: .public)")
        var offset: Int64 = 0
        var lastLogMs = DispatchTime.now().uptimeNanoseconds / 1_000_000
        var lastLogOffset: Int64 = 0
        while offset < totalSize {
            try Task.checkCancellation()
            let want = min(chunkSize, totalSize - offset)
            let data = try await fetchOne(source: source,
                                          domainSubdir: domainSubdir,
                                          itemID: itemID,
                                          offset: offset,
                                          length: want)
            if data.isEmpty {
                throw NSError(domain: "MacRDP.xpc.client", code: 1,
                    userInfo: [NSLocalizedDescriptionKey:
                        "Empty response at offset \(offset) (server gave up?)"])
            }
            try handle.write(contentsOf: data)
            offset += Int64(data.count)
            // willChangeValue/didChangeValue isn't needed — Progress
            // emits KVO automatically on completedUnitCount assignment.
            // We DO update throughput so Finder's ETA stabilises.
            progress.completedUnitCount = offset
            progress.setUserInfoObject(NSNumber(value: Int(data.count)),
                                        forKey: .throughputKey)
            // Throughput log every ~1s of wall time.
            let nowMs = DispatchTime.now().uptimeNanoseconds / 1_000_000
            if nowMs - lastLogMs >= 1000 {
                let deltaB = offset - lastLogOffset
                let mbps = Double(deltaB) / Double(nowMs - lastLogMs) / 1024.0 * 1000.0 / 1024.0
                let pct = totalSize > 0 ? (Double(offset) / Double(totalSize) * 100.0) : 0
                log.info("HostByteFetcher \(itemID, privacy: .public): \(offset, privacy: .public)/\(totalSize, privacy: .public)B (\(pct, format: .fixed(precision: 1), privacy: .public)%) ~\(mbps, format: .fixed(precision: 2), privacy: .public) MiB/s")
                lastLogMs = nowMs
                lastLogOffset = offset
            }
        }
    }

    private static func fetchOne(source: ClipboardServiceSource,
                                 domainSubdir: String,
                                 itemID: String,
                                 offset: Int64,
                                 length: Int64) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            var resumed = false
            let proxy = source.hostProxy { err in
                guard !resumed else { return }
                resumed = true
                log.error("Host proxy error: \(String(describing: err), privacy: .public)")
                cont.resume(throwing: err)
            }
            guard let proxy else {
                cont.resume(throwing: NSError(
                    domain: "MacRDP.xpc.client", code: 3,
                    userInfo: [NSLocalizedDescriptionKey:
                        "No host connection — main app didn't open the service yet"]))
                return
            }
            proxy.fetchBytes(domainSubdir: domainSubdir,
                             itemID: itemID,
                             offset: offset,
                             length: length) { data, err in
                guard !resumed else { return }
                resumed = true
                if let err {
                    cont.resume(throwing: err)
                } else if let data {
                    cont.resume(returning: data)
                } else {
                    cont.resume(throwing: NSError(
                        domain: "MacRDP.xpc.client", code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "nil data and no error"]))
                }
            }
        }
    }
}
