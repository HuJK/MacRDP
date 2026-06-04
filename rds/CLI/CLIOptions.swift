//
//  CLIOptions.swift
//  MacRDP
//
//  Minimal arg parsing. Phase 1 swap to swift-argument-parser is fine but
//  not required — the surface here stays small on purpose.
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
      -c, --config <path>   Path to a YAML config file. Omit to use built-in
                            defaults; values you set override the defaults.
                            (See DefaultConfig.swift for the full schema.)
          --host <addr>     Override listen address (default: from config / 0.0.0.0)
          --port <n>        Override listen port    (default: from config / 3389)
      -v, --verbose         Reserved (use config.log.default=debug for verbose)
      -h, --help            This help
    """
}
