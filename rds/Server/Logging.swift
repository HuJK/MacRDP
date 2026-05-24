//
//  Logging.swift
//  MacRDP
//

import Foundation
import os

nonisolated enum Log {
    static let subsystem = "com.macrdp.server"

    static let server   = Logger(subsystem: subsystem, category: "server")
    static let listener = Logger(subsystem: subsystem, category: "listener")
    static let session  = Logger(subsystem: subsystem, category: "session")
    static let display  = Logger(subsystem: subsystem, category: "display")
    static let encoder  = Logger(subsystem: subsystem, category: "encoder")
    static let audioOut = Logger(subsystem: subsystem, category: "audio.out")
    static let audioIn  = Logger(subsystem: subsystem, category: "audio.in")
    static let clip     = Logger(subsystem: subsystem, category: "clipboard")
    static let input    = Logger(subsystem: subsystem, category: "input")
    static let resize   = Logger(subsystem: subsystem, category: "resize")
    static let config   = Logger(subsystem: subsystem, category: "config")
}
