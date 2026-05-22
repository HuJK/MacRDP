//
//  CLIOptions.swift
//  MacRDP
//
//  Minimal arg parsing in Phase 0 (no third-party deps). Replace with
//  swift-argument-parser in Phase 0b once SPM is wired up.
//

import Foundation

struct CLIOptions {
    var configPath: String?
    var listenHost: String?
    var listenPort: UInt16?
    var verbose: Bool = false
    var showHelp: Bool = false

    static func parse(_ argv: [String]) -> CLIOptions {
        var opts = CLIOptions()
        var i = 1
        while i < argv.count {
            let a = argv[i]
            switch a {
            case "-h", "--help":
                opts.showHelp = true
            case "-v", "--verbose":
                opts.verbose = true
            case "-c", "--config":
                i += 1
                if i < argv.count { opts.configPath = argv[i] }
            case "--host":
                i += 1
                if i < argv.count { opts.listenHost = argv[i] }
            case "--port":
                i += 1
                if i < argv.count, let p = UInt16(argv[i]) {
                    opts.listenPort = p
                }
            default:
                FileHandle.standardError.write(Data("warning: unrecognised arg '\(a)'\n".utf8))
            }
            i += 1
        }
        return opts
    }

    static let usage: String = """
    macrdp-server — RDP server with H.264 acceleration

    Usage:
      macrdp-server [options]

    Options:
      -c, --config <path>   Path to config JSON (default: search ~/Library/Application Support/MacRDP/, /etc/)
          --host <addr>     Listen address (default from config, fallback 0.0.0.0)
          --port <n>        Listen port    (default from config, fallback 3389)
      -v, --verbose         Verbose logging
      -h, --help            This help
    """
}
