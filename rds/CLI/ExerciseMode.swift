//
//  ExerciseMode.swift
//  MacRDP
//
//  Smoke-test harness for the macOS-native subsystems (independent of
//  FreeRDP). Invoked from the CLI as:
//
//    macrdp exercise display    — start SCK capture + VT encode, log frame stats
//    macrdp exercise audio-out  — start CATap, log PCM frame stats
//    macrdp exercise audio-in   — pump white-noise into the configured output
//    macrdp exercise clipboard  — log NSPasteboard changes + format list
//    macrdp exercise input      — print whether Accessibility permission is granted
//    macrdp exercise displays   — list available displays + auto-mapping
//    macrdp exercise hook       — fire the resize hook with WxHxRefresh from argv
//    macrdp exercise cert       — generate / show TLS cert
//
//  Useful for debugging permissions, codec hardware availability, and
//  the resize-hook contract before any RDP client is involved.
//

import Foundation
import AppKit
import os
@preconcurrency import CoreMedia
@preconcurrency import CoreGraphics

@MainActor
enum ExerciseMode {
    static func run(_ args: [String], config: Config) async {
        guard let sub = args.first else {
            print(usage); return
        }
        switch sub {
        case "display":   await exerciseDisplay(config: config)
        case "audio-out": exerciseAudioOut(config: config)
        case "audio-in":  exerciseAudioIn(config: config)
        case "clipboard": exerciseClipboard(config: config)
        case "input":     exerciseInput()
        case "displays":  await exerciseDisplays(config: config)
        case "hook":      await exerciseHook(args: Array(args.dropFirst()), config: config)
        case "cert":      exerciseCert(config: config)
        case "-h", "--help":  print(usage)
        default:
            print("Unknown exercise '\(sub)'")
            print(usage)
        }
    }

    static let usage = """
    Usage:
      macrdp exercise <subcommand>

    Subcommands:
      display    capture + encode loop (sccaptured -> H264 -> stats)
      audio-out  CoreAudio tap (system audio -> Int16LE @ 48k stats)
      audio-in   play a 1-second test tone into config.audioIn.outputDeviceUID
      clipboard  watch NSPasteboard and print format lists on every change
      input      report Accessibility permission state
      displays   list macOS displays + auto-binding for N RDP slots
      hook <w> <h> <hz>   invoke the configured resize hook
      cert       generate / show TLS certificate
    """

    // MARK: -

    static func exerciseDisplay(config: Config) async {
        let displays: [AvailableDisplay]
        do {
            displays = try await DisplayPipeline.availableDisplays()
        } catch {
            print("display enumeration failed: \(error)")
            return
        }
        guard let primary = displays.first(where: { $0.isPrimary }) else {
            print("no displays found"); return
        }
        var frames = 0
        var idrs = 0
        var bytesTotal = 0
        let started = Date()

        let pipeline = DisplayPipeline(config: config) { data, isIDR, _ in
            frames += 1
            bytesTotal += data.count
            if isIDR { idrs += 1 }
        }
        do {
            try await pipeline.start(displayID: primary.displayID)
        } catch {
            print("start failed: \(error)")
            return
        }

        print("Capturing for 10 seconds…")
        try? await Task.sleep(nanoseconds: 10_000_000_000)
        pipeline.stop()
        try? await Task.sleep(nanoseconds: 200_000_000)  // let teardown finish

        let dt = Date().timeIntervalSince(started)
        print(String(format: "frames=%d idrs=%d bytes=%d  ~%.1f fps  ~%.2f Mbps",
                     frames, idrs, bytesTotal,
                     Double(frames) / dt,
                     Double(bytesTotal) * 8 / dt / 1_000_000))
    }

    static func exerciseAudioOut(config: Config) {
        // After the migration to SCK-driven audio, AudioOutPipeline is
        // mute-only — it doesn't deliver audio data. This exercise just
        // toggles the mute tap so you can verify the Mac goes quiet.
        let pipeline = AudioOutPipeline(config: config)
        do { try pipeline.start() } catch {
            print("audio-out (mute tap) start failed: \(error)"); return
        }
        print("Mute tap active for 10 seconds (Mac should fall silent)…")
        Thread.sleep(forTimeInterval: 10)
        pipeline.stop()
        print("Mute tap released; audio restored.")
    }

    static func exerciseAudioIn(config: Config) {
        let pipeline = AudioInPipeline(config: config)
        do { try pipeline.start() } catch {
            print("audio-in start failed: \(error)"); return
        }
        // Synthesize a 1-second 440 Hz tone, Int16LE stereo @ 48k.
        let sr = 48_000
        var pcm = Data(capacity: sr * 4)
        for i in 0..<sr {
            let s = Int16(sin(Double(i) / Double(sr) * 2 * .pi * 440) * 10_000)
            // little-endian, both channels
            pcm.append(UInt8(truncatingIfNeeded: s & 0xFF))
            pcm.append(UInt8(truncatingIfNeeded: (s >> 8) & 0xFF))
            pcm.append(UInt8(truncatingIfNeeded: s & 0xFF))
            pcm.append(UInt8(truncatingIfNeeded: (s >> 8) & 0xFF))
        }
        pipeline.feedPCM(pcm)
        Thread.sleep(forTimeInterval: 1.5)
        pipeline.stop()
        print("Played 1s test tone")
    }

    static func exerciseClipboard(config: Config) {
        let bridge = ClipboardBridge(config: config)
        bridge.sendFormatList = { formats in
            let ids = formats.map { $0.id }
            print("FormatList: \(ids)")
        }
        do { try bridge.start() } catch {
            print("clipboard start failed: \(error)"); return
        }
        // Exercise harness pretends the channel handshake just finished.
        bridge.markReady()
        print("Watching pasteboard for 30 seconds — copy things now…")
        Thread.sleep(forTimeInterval: 30)
        bridge.stop()
    }

    static func exerciseInput() {
        let ok = InputInjector.hasAccessibilityPermission()
        print("Accessibility permission: \(ok ? "GRANTED" : "DENIED")")
        if !ok {
            print(MacRDPError.accessibilityPermissionDenied)
        }
    }

    static func exerciseDisplays(config: Config) async {
        let displays: [AvailableDisplay]
        do {
            displays = try await DisplayPipeline.availableDisplays()
        } catch {
            print("display enumeration failed: \(error)")
            return
        }
        print("macOS displays:")
        for d in displays {
            print("  CGDirectDisplayID=\(d.displayID)\(d.isPrimary ? " (primary)" : "")")
        }
        let mapping = DisplayBindingResolver.resolve(
            channelCount: max(1, displays.count),
            displays: displays,
            configBindings: config.display.monitors)
        print("Resolved RDP slot -> displayID:")
        for slot in mapping.boundSlots {
            print("  slot \(slot) -> \(mapping.displayID(forSlot: slot) ?? 0)")
        }
    }

    static func exerciseHook(args: [String], config: Config) async {
        guard args.count >= 3,
              let w = Int(args[0]),
              let h = Int(args[1]),
              let hz = Int(args[2]) else {
            print("usage: macrdp exercise hook <width> <height> <refresh-hz>")
            return
        }
        guard let template = config.display.resizeHook else {
            print("no resize_hook configured"); return
        }
        let primaryID = CGMainDisplayID()
        let request = MonitorLayoutRequest(monitors: [
            MonitorLayout(rdpSlot: 0, displayID: primaryID,
                          x: 0, y: 0,
                          width: w, height: h, refreshHz: hz,
                          orientation: 0, scale: 1.0, deviceScale: 1.0,
                          physicalWidthMm: nil, physicalHeightMm: nil,
                          primary: true)
        ])
        let hook = ResizeHook(template: template,
                              timeoutSeconds: config.display.resizeTimeoutSeconds)
        do {
            try await hook.run(request)
            print("Hook completed OK")
        } catch {
            print("Hook failed: \(error)")
        }
    }

    static func exerciseCert(config: Config) {
        do {
            let (cert, key) = try TLSCertificateGenerator.ensureCertificate(config: config)
            print("cert: \(cert)")
            print("key:  \(key)")
        } catch {
            print("cert generation failed: \(error)")
        }
    }
}
