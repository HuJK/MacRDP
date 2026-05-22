//
//  ClipboardServiceSource.swift
//  fileprovider
//
//  `NSFileProviderServiceSource` that exposes our bidirectional IPC
//  channel to the host app. The framework brokers the cross-sandbox
//  connection, sidestepping the TCC and Mach-service issues that block
//  direct App Group reads.
//
//  Lifecycle:
//    1. The framework asks `FileProviderExtension.supportedServiceSources(
//       for:)` for the root container.
//    2. We return one source. The framework calls `makeListenerEndpoint`
//       and ships the endpoint to the host.
//    3. Host opens an NSXPCConnection on it. We accept, install both
//       export + remote interfaces (the connection is bidirectional),
//       and cache it so the extension can call back into the host for
//       fetchBytes during `fetchContents`.
//

import Foundation
import FileProvider
import os

private let log = Logger(subsystem: "com.macrdp.server", category: "fileprovider")

final class ClipboardServiceSource: NSObject,
                                     NSFileProviderServiceSource,
                                     NSXPCListenerDelegate,
                                     HostToExtensionProtocol {

    let domainSubdir: String

    /// Strong references to listeners we've vended. Each call to
    /// `makeListenerEndpoint` makes a new one — we keep them alive
    /// until invalidation.
    private let lock = NSLock()
    private var listeners: [NSXPCListener] = []
    private var hostConnections: [NSXPCConnection] = []

    init(domainSubdir: String) {
        self.domainSubdir = domainSubdir
        super.init()
    }

    // MARK: - NSFileProviderServiceSource

    var serviceName: NSFileProviderServiceName { MacRDPFileProviderServiceName }

    func makeListenerEndpoint() throws -> NSXPCListenerEndpoint {
        let listener = NSXPCListener.anonymous()
        listener.delegate = self
        listener.resume()
        lock.lock()
        listeners.append(listener)
        lock.unlock()
        log.info("ClipboardServiceSource vended endpoint (subdir=\(self.domainSubdir, privacy: .public))")
        return listener.endpoint
    }

    var isRestricted: Bool { false }

    // MARK: - NSXPCListenerDelegate

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection conn: NSXPCConnection) -> Bool {
        conn.exportedInterface = NSXPCInterface(with: HostToExtensionProtocol.self)
        conn.exportedObject = self
        conn.remoteObjectInterface = NSXPCInterface(with: ExtensionToHostProtocol.self)
        conn.invalidationHandler = { [weak self] in
            log.notice("Host XPC connection invalidated")
            self?.forget(conn)
        }
        conn.interruptionHandler = { [weak self] in
            log.notice("Host XPC connection interrupted")
            self?.forget(conn)
        }
        conn.resume()
        lock.lock()
        hostConnections.append(conn)
        lock.unlock()
        log.info("ClipboardServiceSource accepted host XPC connection")
        return true
    }

    private func forget(_ conn: NSXPCConnection) {
        lock.lock()
        hostConnections.removeAll { $0 === conn }
        lock.unlock()
    }

    // MARK: - HostToExtensionProtocol

    func pushManifest(domainSubdir: String,
                      data: Data,
                      reply: @escaping (Bool) -> Void) {
        ManifestCache.shared.set(data, domainSubdir: domainSubdir)
        reply(true)
    }

    func ping(reply: @escaping (Bool) -> Void) { reply(true) }

    // MARK: - Reverse direction (extension → host)

    /// Returns a proxy to the host's `ExtensionToHostProtocol` impl on
    /// the most recent active connection. Used by `fetchContents` to
    /// stream bytes back from the host (the active RDP session). Nil if
    /// no host has connected yet (manifest was published but host
    /// never opened the service).
    func hostProxy(errorHandler: @escaping (Error) -> Void) -> ExtensionToHostProtocol? {
        lock.lock()
        let conn = hostConnections.last
        lock.unlock()
        guard let conn else { return nil }
        let proxy = conn.remoteObjectProxyWithErrorHandler(errorHandler)
        return proxy as? ExtensionToHostProtocol
    }
}
