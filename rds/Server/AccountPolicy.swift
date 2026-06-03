//
//  AccountPolicy.swift
//  MacRDP
//
//  Reads a local account's `passwordLastSetTime` via the OpenDirectory
//  framework (in-process, no subprocess). Readable WITHOUT root for the
//  *current* user; another user's needs root (returns nil → caller falls back
//  to TTL-only cache invalidation).
//
//  Used to invalidate the PasswordVerifyCache NT-hash the moment the macOS
//  password changes, so a stale cached hash can't keep accepting the old one.
//

import Foundation
import OpenDirectory

enum AccountPolicy {
    private static let attr = "dsAttrTypeNative:accountPolicyData"

    /// Seconds-since-epoch the user's password was last set, or nil if it
    /// couldn't be read.
    static func passwordLastSetTime(user: String) -> Double? {
        guard !user.isEmpty else { return nil }
        guard let node = try? ODNode(session: ODSession.default(), name: "/Local/Default"),
              let record = try? node.record(withRecordType: kODRecordTypeUsers,
                                             name: user, attributes: [attr]),
              let values = try? record.values(forAttribute: attr)
        else { return nil }

        for value in values {
            let data: Data?
            if let s = value as? String { data = s.data(using: .utf8) }
            else if let d = value as? Data { data = d }
            else { data = nil }
            guard let data,
                  let dict = try? PropertyListSerialization.propertyList(
                    from: data, options: [], format: nil) as? [String: Any]
            else { continue }
            if let n = dict["passwordLastSetTime"] as? NSNumber { return n.doubleValue }
            if let v = dict["passwordLastSetTime"] as? Double { return v }
        }
        return nil
    }
}
