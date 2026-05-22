//
//  FrameCounter.swift
//  MacRDP
//
//  Lightweight stats helper: counts encoded frames and emits a log line
//  every second so we can confirm the pipeline is producing output even
//  when the network side is silent.
//

import Foundation
import os

final class FrameCounter: @unchecked Sendable {
    private var frames: Int = 0
    private var idrs: Int = 0
    private var bytes: Int = 0
    private var lastTick: Date = Date()
    private let lock = NSLock()

    func tick(bytes: Int, isIDR: Bool) {
        lock.lock()
        self.frames += 1
        if isIDR { self.idrs += 1 }
        self.bytes += bytes
        let now = Date()
        if now.timeIntervalSince(lastTick) >= 1.0 {
            let f = self.frames
            let i = self.idrs
            let b = self.bytes
            self.frames = 0
            self.idrs = 0
            self.bytes = 0
            self.lastTick = now
            lock.unlock()
            Log.encoder.info("encoded \(f, privacy: .public) frames/s, \(i, privacy: .public) IDR, \(b / 1024, privacy: .public) KiB/s")
            return
        }
        lock.unlock()
    }
}
