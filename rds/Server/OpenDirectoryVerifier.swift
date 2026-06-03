//
//  OpenDirectoryVerifier.swift
//  MacRDP
//
//  Verifies a plaintext password against the local macOS account database via
//  OpenDirectory (`opendirectoryd`) — the same path login/sshd/sudo/PAM
//  eventually take. In-process, no subprocess, no askpass dance, no
//  /usr/bin/ssh hop, no root. Sub-ms on a hit; tens of ms on a miss (PBKDF2
//  work factor — same anti-brute-force the system itself applies).
//
//  Account-state outcomes are distinguished from "wrong password" so the gate
//  can fail closed with a meaningful log instead of looping retries.
//

import Foundation
import OpenDirectory
import os

enum OpenDirectoryVerifier {
    enum Outcome {
        case ok
        case wrongPassword
        case noSuchUser
        case accountDisabled                // disabled / expired / locked / pw-change-required
        case error(String)                  // OD framework hiccup — caller should fail closed
    }

    static func verify(username: String, password: String) -> Outcome {
        guard !username.isEmpty, !password.isEmpty else { return .wrongPassword }
        do {
            let session = ODSession.default()
            // The authentication node honours the system search policy:
            // vanilla Mac → /Local/Default; AD-bound → the AD plug-in too.
            let node = try ODNode(session: session,
                                  type: ODNodeType(kODNodeTypeAuthentication))
            let record = try node.record(withRecordType: kODRecordTypeUsers,
                                         name: username,
                                         attributes: nil)
            try record.verifyPassword(password)
            return .ok
        } catch let e as NSError where e.domain == ODFrameworkErrorDomain {
            switch e.code {
            case Int(kODErrorCredentialsInvalid.rawValue):
                return .wrongPassword
            case Int(kODErrorCredentialsAccountNotFound.rawValue),
                 Int(kODErrorRecordNoLongerExists.rawValue):
                return .noSuchUser
            case Int(kODErrorCredentialsAccountDisabled.rawValue),
                 Int(kODErrorCredentialsAccountExpired.rawValue),
                 Int(kODErrorCredentialsAccountInactive.rawValue),
                 Int(kODErrorCredentialsAccountTemporarilyLocked.rawValue),
                 Int(kODErrorCredentialsAccountLocked.rawValue),
                 Int(kODErrorCredentialsPasswordExpired.rawValue),
                 Int(kODErrorCredentialsPasswordChangeRequired.rawValue):
                return .accountDisabled
            default:
                return .error("OD \(e.code): \(e.localizedDescription)")
            }
        } catch {
            return .error(String(describing: error))
        }
    }
}
