//
//  TLSCertificateGenerator.swift
//  MacRDP
//
//  Generates a self-signed TLS server cert + key, stored at
//  ~/Library/Application Support/MacRDP/{cert,key}.pem. Used by the
//  FreeRDP bridge to satisfy WinPR's "load PEM" calls.
//
//  We deliberately use `openssl` if it's on PATH (system or Homebrew)
//  rather than reimplementing X.509 generation in pure Swift — RDP
//  clients are picky about cert details (CN must be parseable, EKU
//  serverAuth required, etc.) and `openssl req` gets this right out of
//  the box.
//

import Foundation
import os

enum TLSCertificateGenerator {

    static func ensureCertificate(config: Config) throws -> (certPath: String,
                                                              keyPath: String) {
        if let cert = config.auth.certificateFile,
           let key  = config.auth.privateKeyFile {
            return (cert, key)
        }

        let dir = try appSupportDirectory()
        let cert = dir.appendingPathComponent("cert.pem")
        let key  = dir.appendingPathComponent("key.pem")

        let fm = FileManager.default
        if fm.fileExists(atPath: cert.path),
           fm.fileExists(atPath: key.path) {
            Log.server.info("Using existing TLS cert at \(cert.path, privacy: .public)")
            return (cert.path, key.path)
        }

        try generate(certURL: cert, keyURL: key,
                     rsaKeyBits: config.auth.rsaKeyBits,
                     validityDays: config.auth.certificateValidityDays)
        Log.server.notice("Generated new self-signed TLS cert at \(cert.path, privacy: .public)")
        return (cert.path, key.path)
    }

    private static func appSupportDirectory() throws -> URL {
        let fm = FileManager.default
        let base = try fm.url(for: .applicationSupportDirectory,
                              in: .userDomainMask,
                              appropriateFor: nil,
                              create: true)
        let dir = base.appendingPathComponent("MacRDP", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func generate(certURL: URL, keyURL: URL,
                                 rsaKeyBits: Int,
                                 validityDays: Int) throws {
        let openssl = try findOpenSSL()

        // 1. Generate an RSA key of the configured bit length.
        try run(openssl, ["genrsa", "-out", keyURL.path, String(rsaKeyBits)])
        // 2. Self-signed cert with EKU=serverAuth + SAN for local hostname.
        let hostname = (Host.current().localizedName ?? "macrdp").lowercased()
        let subj = "/CN=MacRDP"
        let san  = "subjectAltName=DNS:\(hostname),DNS:localhost,IP:127.0.0.1"
        try run(openssl, [
            "req", "-new", "-x509",
            "-key", keyURL.path,
            "-out", certURL.path,
            "-days", String(validityDays),
            "-sha256",
            "-subj", subj,
            "-addext", "extendedKeyUsage=serverAuth",
            "-addext", san
        ])

        // Permissions: key must not be world-readable.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
    }

    private static func findOpenSSL() throws -> URL {
        let candidates = [
            "/opt/homebrew/bin/openssl",
            "/usr/local/bin/openssl",
            "/usr/bin/openssl",            // LibreSSL on stock macOS — works for our use
        ]
        let fm = FileManager.default
        for path in candidates where fm.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        throw MacRDPError.resizeHookFailed(reason: "openssl not found on PATH; please install via Homebrew")
    }

    private static func run(_ exe: URL, _ args: [String]) throws {
        let proc = Process()
        proc.executableURL = exe
        proc.arguments = args
        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = Pipe()
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            let err = String(data: (try? errPipe.fileHandleForReading.readToEnd()) ?? Data(),
                             encoding: .utf8) ?? "<binary>"
            throw MacRDPError.resizeHookFailed(
                reason: "openssl exit=\(proc.terminationStatus): \(err)")
        }
    }
}
