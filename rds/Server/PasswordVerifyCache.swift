//
//  PasswordVerifyCache.swift
//  MacRDP
//
//  Process-wide cache of NT-hashes learned from a successful plaintext password
//  verification (via OpenDirectory). While an entry is valid, subsequent
//  connections for that user can use NLA (validated against the cached NT-hash)
//  instead of re-sending the plaintext. Only the NT-hash is stored — never the
//  plaintext. The cache is invalidated the moment the account's
//  `passwordLastSetTime` changes, so a since-changed password can't keep
//  accepting the old one.
//

import Foundation

final class PasswordVerifyCache: @unchecked Sendable {
    static let shared = PasswordVerifyCache()

    private let lock = NSLock()
    private struct Entry {
        var ntHashHex: String
        var pwLastSet: Double    // passwordLastSetTime when cached
    }
    private var entries: [String: Entry] = [:]

    private func key(_ user: String) -> String { user.lowercased() }

    /// Cached NT-hash for `user`, valid exactly while the account's
    /// passwordLastSetTime is unchanged. No expiry. If that time can't be read
    /// now (e.g. a different user without root) the cache can't be trusted →
    /// miss (the caller re-verifies via OpenDirectory).
    func cachedNtHash(user: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let e = entries[key(user)] else { return nil }
        guard let now = AccountPolicy.passwordLastSetTime(user: user), now == e.pwLastSet else {
            entries[key(user)] = nil
            return nil
        }
        return e.ntHashHex
    }

    /// Store the NT-hash for `user`, stamped with the current
    /// passwordLastSetTime. Only caches when that time is readable — otherwise
    /// we couldn't later detect a password change, so we don't cache at all.
    func store(user: String, ntHashHex: String, pwLastSet: Double?) {
        guard let pwLastSet else { return }
        lock.lock(); defer { lock.unlock() }
        entries[key(user)] = Entry(ntHashHex: ntHashHex, pwLastSet: pwLastSet)
    }
}
