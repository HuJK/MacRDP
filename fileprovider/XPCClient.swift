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
        var offset: Int64 = 0
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
            progress.completedUnitCount = offset
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
