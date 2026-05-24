//
//  AuthProvisioner.swift
//  MacRDP
//
//  Turns the auth config into a concrete NLA setup for the FreeRDP bridge.
//  NLA validates against an NT-hash the server holds; we derive that hash
//  (from the serial, or a configured NT-hash) and write a WinPR SAM file that
//  FreeRDP points at via FreeRDP_NtlmSamFile.
//
//  SAM line format (from WinPR's parser): "user:domain:LM:NT:" — 5
//  colon-separated fields, LM empty, NT = 32 hex chars.
//

import Foundation
import IOKit
import CommonCrypto   // CC_MD4 — required for the NT-hash; no modern alternative
import os

enum AuthResolution {
    case noAuth                          // NLA off, accept everyone (policy "none")
    case nla(samFilePath: String)        // NLA on, validate against this SAM file
    case gate                            // NLA off, verify client password at logon (ssh)
    case deny(reason: String)            // misconfigured / unsupported → refuse
}

enum AuthProvisioner {

    /// NT-hash (MD4 of the UTF-16LE password) as 32 uppercase hex chars.
    static func ntHashHex(_ password: String) -> String {
        var bytes = [UInt8]()
        bytes.reserveCapacity(password.utf16.count * 2)
        for u in password.utf16 {            // UTF-16LE: low byte, high byte
            bytes.append(UInt8(u & 0xff))
            bytes.append(UInt8(u >> 8))
        }
        var digest = [UInt8](repeating: 0, count: Int(CC_MD4_DIGEST_LENGTH))
        _ = CC_MD4(bytes, CC_LONG(bytes.count), &digest)
        return digest.map { String(format: "%02X", $0) }.joined()
    }

    /// The Mac's hardware serial number (IOKit; no special permission).
    static func serialNumber() -> String? {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault,
                                              IOServiceMatching("IOPlatformExpertDevice"))
        guard svc != 0 else { return nil }
        defer { IOObjectRelease(svc) }
        guard let cf = IORegistryEntryCreateCFProperty(
            svc, "IOPlatformSerialNumber" as CFString, kCFAllocatorDefault, 0) else { return nil }
        return cf.takeRetainedValue() as? String
    }

    static func effectiveUsername(_ auth: Config.AuthConfig) -> String {
        if auth.authUserPolicy.lowercased() == "fixed",
           let u = auth.username, !u.isEmpty {
            return u
        }
        return NSUserName()   // "self" (default)
    }

    static func effectiveDomain(_ auth: Config.AuthConfig) -> String {
        auth.domain ?? ""
    }

    /// Resolve the configured policy into an NLA setup. For policies that need
    /// a held NT-hash this writes a 0600 SAM file and returns its path.
    static func resolve(_ auth: Config.AuthConfig) -> AuthResolution {
        let user = effectiveUsername(auth)
        let domain = effectiveDomain(auth)
        switch auth.passwordPolicy.lowercased() {
        case "none":
            Log.server.warning("Auth policy \"none\": ANY client may connect with no password")
            return .noAuth

        case "serial":
            guard let serial = serialNumber(), !serial.isEmpty else {
                return .deny(reason: "serial policy: could not read the Mac serial number")
            }
            return writeSAM(user: user, domain: domain, ntHex: ntHashHex(serial))

        case "nthash":
            guard let hex = auth.ntHash, isValidNtHash(hex) else {
                return .deny(reason: "nthash policy: auth.ntHash must be 32 hex chars (run `rds nthash`)")
            }
            return writeSAM(user: user, domain: domain, ntHex: hex.uppercased())

        case "ssh":
            // If we have a still-valid cached NT-hash for this user, use NLA
            // (no plaintext this connection). Otherwise gate: verify the
            // client-submitted password via SSH at logon.
            if let nt = SSHAuthCache.shared.cachedNtHash(user: user) {
                return writeSAM(user: user, domain: domain, ntHex: nt)
            }
            return .gate

        default:
            return .deny(reason: "unknown passwordPolicy \"\(auth.passwordPolicy)\"")
        }
    }

    static func isValidNtHash(_ s: String) -> Bool {
        s.count == 32 && s.allSatisfy { $0.isHexDigit }
    }

    /// Write a 0600 SAM file with one entry; return its path (or .deny).
    private static func writeSAM(user: String, domain: String, ntHex: String) -> AuthResolution {
        let line = "\(user):\(domain)::\(ntHex):\n"
        let dir = FileManager.default.temporaryDirectory
        let path = dir.appendingPathComponent("macrdp-sam-\(UUID().uuidString)").path
        do {
            try line.write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        } catch {
            return .deny(reason: "could not write SAM file: \(error.localizedDescription)")
        }
        Log.server.info("NLA enabled for user \(user, privacy: .public)@\(domain.isEmpty ? "(no domain)" : domain, privacy: .public)")
        return .nla(samFilePath: path)
    }
}
