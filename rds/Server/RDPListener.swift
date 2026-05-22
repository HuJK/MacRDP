//
//  RDPListener.swift
//  MacRDP
//
//  POSIX socket listener. FreeRDP's freerdp_peer_new() needs a raw
//  file descriptor, so we use socket/bind/listen/accept directly.
//

import Foundation
import Darwin
import os

@MainActor
final class RDPListener {
    private let config: Config
    private var listenFD: Int32 = -1
    private var acceptThread: Thread?
    private var sessions: [ObjectIdentifier: RDPSession] = [:]
    private var stopping = false

    init(config: Config) {
        self.config = config
    }

    func start() throws {
        let fd = socket(AF_INET6, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw MacRDPError.bindFailure(port: config.listen.port,
                                          underlying: POSIXError(.EACCES))
        }
        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes,
                       socklen_t(MemoryLayout<Int32>.size))
        var no: Int32 = 0
        _ = setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &no,
                       socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in6()
        addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_port = in_port_t(config.listen.port).bigEndian
        addr.sin6_addr = in6addr_any

        let bindRC = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        guard bindRC == 0 else {
            let savedErrno = errno
            close(fd)
            throw MacRDPError.bindFailure(port: config.listen.port,
                                          underlying: POSIXError(POSIXErrorCode(rawValue: savedErrno) ?? .EACCES))
        }
        guard listen(fd, 16) == 0 else {
            let savedErrno = errno
            close(fd)
            throw MacRDPError.bindFailure(port: config.listen.port,
                                          underlying: POSIXError(POSIXErrorCode(rawValue: savedErrno) ?? .EACCES))
        }

        self.listenFD = fd
        Log.listener.notice("Listening on tcp/[::]:\(self.config.listen.port, privacy: .public)")

        // Capture the fd by value for the accept thread — must NOT touch
        // MainActor-isolated state from there.
        let acceptFD = fd
        let thread = Thread { [weak self] in
            Self.acceptLoop(listenFD: acceptFD, owner: self)
        }
        thread.name = "com.macrdp.listener.accept"
        thread.start()
        self.acceptThread = thread
    }

    func stop() {
        stopping = true
        if listenFD >= 0 {
            shutdown(listenFD, SHUT_RDWR)
            close(listenFD)
            listenFD = -1
        }
        for s in sessions.values { s.shutdown() }
        sessions.removeAll()
    }

    // MARK: - Accept loop (background thread; NOT @MainActor)

    private nonisolated static func acceptLoop(listenFD: Int32,
                                               owner: RDPListener?) {
        while true {
            var addr = sockaddr_storage()
            var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let client = withUnsafeMutablePointer(to: &addr) { ptr -> Int32 in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    accept(listenFD, sa, &len)
                }
            }
            if client < 0 {
                let err = errno
                if err == EINTR { continue }
                // Either we were shut down (fd closed) or a real error.
                Log.listener.notice("accept() loop exiting: \(String(cString: strerror(err)), privacy: .public)")
                return
            }
            // Disable Nagle's algorithm on the accepted socket. RDP is
            // interactive — small control / ACK PDUs must hit the wire
            // immediately, not batch up waiting for 40ms.
            var on: Int32 = 1
            _ = setsockopt(client, IPPROTO_TCP, TCP_NODELAY,
                           &on, socklen_t(MemoryLayout<Int32>.size))
            // Bump the kernel send buffer. Default ~128 KiB stalls writes
            // for large IDR frames at 1080p (200-400 KiB) — every IDR
            // would otherwise add a few ms of socket-blocking latency.
            var sndBuf: Int32 = 1 * 1024 * 1024
            _ = setsockopt(client, SOL_SOCKET, SO_SNDBUF,
                           &sndBuf, socklen_t(MemoryLayout<Int32>.size))

            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let owner else {
                        close(client)
                        return
                    }
                    owner.handleAccepted(fd: client)
                }
            }
        }
    }

    private func handleAccepted(fd: Int32) {
        let session = RDPSession(fd: fd, config: config)
        let id = ObjectIdentifier(session)
        sessions[id] = session
        session.onTerminated = { [weak self] in
            Task { @MainActor [weak self] in
                self?.sessions.removeValue(forKey: id)
            }
        }
        Log.listener.info("Accepted client fd=\(fd, privacy: .public)")
        session.start()
    }
}
