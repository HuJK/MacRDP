//
//  SSHVerifier.swift
//  MacRDP
//
//  Verifies a plaintext password by attempting an SSH password login to a host
//  (default localhost). macOS sshd authenticates against the real account via
//  PAM/OpenDirectory, so this checks the user's actual login password — without
//  us needing root. Used by the "ssh" login policy.
//
//  The password is fed to ssh via the SSH_ASKPASS mechanism (no tty), passed in
//  the child's environment. We force password-only auth (no keys, no agent, no
//  GSSAPI) so a successful exit means the *password* was correct — not a key.
//
//  Caveat: the password is briefly present in the ssh/askpass process
//  environment (readable by the same user during the ~seconds-long attempt).
//

import Foundation
import os

enum SSHVerifier {
    static func verify(username: String, password: String,
                       host: String, port: Int) -> Bool {
        guard !username.isEmpty, !password.isEmpty else { return false }

        // Askpass helper: echoes the password from the environment.
        let helper = FileManager.default.temporaryDirectory
            .appendingPathComponent("macrdp-askpass-\(UUID().uuidString).sh")
        let script = "#!/bin/sh\nprintf '%s' \"$MACRDP_ASKPASS_PW\"\n"
        do {
            try script.write(to: helper, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                  ofItemAtPath: helper.path)
        } catch {
            Log.server.error("ssh verify: cannot write askpass helper: \(String(describing: error), privacy: .public)")
            return false
        }
        defer { try? FileManager.default.removeItem(at: helper) }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = [
            "-o", "PreferredAuthentications=password,keyboard-interactive",
            "-o", "PubkeyAuthentication=no",
            "-o", "GSSAPIAuthentication=no",
            "-o", "IdentityAgent=none",
            "-o", "NumberOfPasswordPrompts=1",
            "-o", "ConnectTimeout=5",
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "LogLevel=ERROR",
            "-p", String(port),
            "\(username)@\(host)",
            "true",
        ]
        var env = ProcessInfo.processInfo.environment
        env["SSH_ASKPASS"] = helper.path
        env["SSH_ASKPASS_REQUIRE"] = "force"   // OpenSSH 8.4+ : use askpass with no tty
        env["MACRDP_ASKPASS_PW"] = password
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice

        let sem = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in sem.signal() }
        do {
            try p.run()
        } catch {
            Log.server.error("ssh verify: launch failed: \(String(describing: error), privacy: .public)")
            return false
        }
        if sem.wait(timeout: .now() + 12) == .timedOut {
            p.terminate()
            _ = sem.wait(timeout: .now() + 2)
            Log.server.error("ssh verify: timed out")
            return false
        }
        return p.terminationStatus == 0
    }
}
