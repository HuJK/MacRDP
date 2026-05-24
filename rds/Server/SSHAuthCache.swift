//
//  SSHAuthCache.swift
//  MacRDP
//
//  Process-wide cache of NT-hashes learned from a successful SSH password
//  verification. While an entry is valid, subsequent connections for that user
//  can use NLA (validated against the cached NT-hash) instead of re-sending the
//  plaintext. Only the NT-hash is stored — never the plaintext. The TTL bounds
//  how long a since-changed password keeps working.
//

import Foundation

final class SSHAuthCache: @unchecked Sendable {
    static let shared = SSHAuthCache()

    private let lock = NSLock()
    private struct Entry {
        var ntHashHex: String
        var expiry: Date
        var pwLastSet: Double?   // passwordLastSetTime when cached (nil = unknown)
    }
    private var entries: [String: Entry] = [:]

    private func key(_ user: String) -> String { user.lowercased() }

    /// Valid cached NT-hash for `user`, or nil. Invalidated on TTL expiry OR if
    /// the account's passwordLastSetTime has changed since it was cached
    /// (precise change detection; when readable — own account, no root).
    func cachedNtHash(user: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let e = entries[key(user)] else { return nil }
        if e.expiry <= Date() {
            entries[key(user)] = nil
            return nil
        }
        // If we know the password's last-set time and can read it now, a change
        // means the cached hash is stale → drop it (forces SSH re-verify).
        if let cachedTime = e.pwLastSet,
           let now = AccountPolicy.passwordLastSetTime(user: user),
           now != cachedTime {
            entries[key(user)] = nil
            return nil
        }
        return e.ntHashHex
    }

    /// Store the NT-hash for `user` with a TTL (seconds) and the current
    /// passwordLastSetTime. ttl ≤ 0 → don't cache (always re-verify; no NLA).
    func store(user: String, ntHashHex: String, ttlSeconds: Int, pwLastSet: Double?) {
        guard ttlSeconds > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        entries[key(user)] = Entry(ntHashHex: ntHashHex,
                                   expiry: Date().addingTimeInterval(TimeInterval(ttlSeconds)),
                                   pwLastSet: pwLastSet)
    }
}
