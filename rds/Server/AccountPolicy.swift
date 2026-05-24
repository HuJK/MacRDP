//
//  AccountPolicy.swift
//  MacRDP
//
//  Reads a local account's `passwordLastSetTime` from OpenDirectory's
//  accountPolicyData (via `dscl`). Readable WITHOUT root for the *current*
//  user; reading another user's needs root (returns nil → caller falls back to
//  TTL-only cache invalidation).
//
//  Used to invalidate the SSH NT-hash cache the moment the macOS password
//  changes, so a stale cached hash can't keep accepting the old password.
//

import Foundation

enum AccountPolicy {
    /// Seconds-since-epoch the user's password was last set, or nil if it
    /// couldn't be read (e.g. another user without root, or no such field).
    static func passwordLastSetTime(user: String) -> Double? {
        guard !user.isEmpty,
              !user.contains("/"), !user.contains("..") else { return nil }   // path-injection guard
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/dscl")
        p.arguments = ["-plist", ".", "-read", "/Users/\(user)", "accountPolicyData"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0, !data.isEmpty else { return nil }

        // dscl -plist wraps the value as an array of XML-plist strings under
        // the native attribute key; parse the outer plist, then the inner one.
        guard let outer = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: Any] else { return nil }
        let key = "dsAttrTypeNative:accountPolicyData"
        guard let arr = outer[key] as? [String], let inner = arr.first,
              let innerData = inner.data(using: .utf8),
              let dict = try? PropertyListSerialization.propertyList(
                from: innerData, options: [], format: nil) as? [String: Any]
        else { return nil }
        if let v = dict["passwordLastSetTime"] as? Double { return v }
        if let n = dict["passwordLastSetTime"] as? NSNumber { return n.doubleValue }
        return nil
    }
}
