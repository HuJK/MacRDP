//
//  CredentialStore.swift
//  MacRDP
//
//  Backs WinPR's NLA credential lookup. The FreeRDP bridge calls into
//  Swift with a (domain, username) pair; we return the NTLM hash so
//  the SSPI server can validate the NTLM AUTHENTICATE message.
//
//  Storage: JSON file at:
//      ~/Library/Application Support/MacRDP/credentials.json
//  (or the path explicitly set via config.auth.credentialsFile).
//
//  Schema:
//      { "users": [
//          { "username": "alice", "domain": "MACRDP",
//            "ntlmHash": "ABCDEF...32 hex chars..." } ]
//      }
//
//  The hash is the standard NT-hash (MD4(UTF16-LE(password))). Users
//  generate it with:
//      printf '%s' 'MyPassword' | iconv -t UTF-16LE | openssl dgst -md4
//
//  Phase 8 polish: back this with Keychain instead of plaintext.
//

import Foundation
import os

struct CredentialEntry: Codable, Sendable {
    var username: String
    var domain: String
    /// NT-hash as hex (32 hex chars / 16 bytes).
    var ntlmHash: String
}

struct CredentialStoreFile: Codable, Sendable {
    var users: [CredentialEntry]
}

final class CredentialStore: @unchecked Sendable {
    private let entries: [String: CredentialEntry]   // "domain\\username" -> entry

    init(entries: [CredentialEntry]) {
        var dict: [String: CredentialEntry] = [:]
        for e in entries {
            let key = Self.key(domain: e.domain, username: e.username)
            dict[key] = e
        }
        self.entries = dict
    }

    static func load(config: Config) throws -> CredentialStore {
        let path: String
        if let configured = config.auth.credentialsFile {
            path = configured
        } else {
            let fm = FileManager.default
            let base = try fm.url(for: .applicationSupportDirectory,
                                  in: .userDomainMask,
                                  appropriateFor: nil,
                                  create: true)
            let dir = base.appendingPathComponent("MacRDP", isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            path = dir.appendingPathComponent("credentials.json").path
        }

        if !FileManager.default.fileExists(atPath: path) {
            Log.server.notice("No credentials file at \(path, privacy: .public); NLA will reject all logins")
            return CredentialStore(entries: [])
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let file = try JSONDecoder().decode(CredentialStoreFile.self, from: data)
        Log.server.info("Loaded \(file.users.count, privacy: .public) credential entry/entries from \(path, privacy: .public)")
        return CredentialStore(entries: file.users)
    }

    /// Lookup returns the raw NT-hash bytes (16 B) for the bridge.
    /// Domain is matched case-insensitively; an empty client domain
    /// falls through to the first matching username.
    func ntlmHash(forUsername user: String, domain: String) -> Data? {
        if let direct = entries[Self.key(domain: domain, username: user)],
           let bytes = Self.unhex(direct.ntlmHash) {
            return bytes
        }
        // Fallback: ignore domain.
        for (k, v) in entries
            where v.username.lowercased() == user.lowercased() {
            if let bytes = Self.unhex(v.ntlmHash) {
                Log.server.info("Credential lookup matched ignoring domain: \(k, privacy: .public)")
                return bytes
            }
        }
        return nil
    }

    private static func key(domain: String, username: String) -> String {
        "\(domain.uppercased())\\\(username.lowercased())"
    }

    private static func unhex(_ s: String) -> Data? {
        guard s.count == 32 else { return nil }
        var out = Data(); out.reserveCapacity(16)
        var i = s.startIndex
        while i < s.endIndex {
            let next = s.index(i, offsetBy: 2)
            guard let b = UInt8(s[i..<next], radix: 16) else { return nil }
            out.append(b)
            i = next
        }
        return out
    }
}
