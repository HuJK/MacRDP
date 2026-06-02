//
//  MicSpectrumWindow.swift
//  MacRDP
//
//  A small live spectrum analyzer window for a client's redirected microphone.
//  Fed decoded AUDIN PCM straight off the RDP path (see AudioInPipeline.pcmTap)
//  — it does NOT route through any system audio device; it exists purely to
//  confirm "is sound actually coming through?" from the menu bar.
//
//  Int16LE interleaved PCM → mono → windowed 1024-pt real FFT (Accelerate) →
//  log-frequency magnitude bars. Throttled to ~30 fps.
//

import AppKit
import Accelerate

@MainActor
final class MicSpectrumWindowController: NSWindowController, NSWindowDelegate {

    /// Invoked when the user closes the window so the owner can drop its tap.
    var onClose: (() -> Void)?

    private let spectrumView = SpectrumView()
    private let analyzer = FFTAnalyzer(size: 1024)
    private var samples: [Float] = []
    private var lastDraw = CFAbsoluteTimeGetCurrent()

    private static let fftSize = 1024
    private static let barCount = 48

    init(title: String) {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 220),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        win.title = title
        win.isReleasedWhenClosed = false
        win.center()
        super.init(window: win)
        win.delegate = self
        win.contentView = spectrumView
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    /// Feed one decoded PCM chunk (Int16LE interleaved stereo @ 48 kHz). Runs
    /// on the same MainActor path as AudioInPipeline.feedPCM.
    func feed(_ pcm: Data) {
        pcm.withUnsafeBytes { raw in
            let s = raw.bindMemory(to: Int16.self)
            guard s.count >= 2 else { return }
            var i = 0
            while i + 1 < s.count {   // average L+R → mono, normalize to ±1
                samples.append((Float(s[i]) + Float(s[i + 1])) * 0.5 / 32768.0)
                i += 2
            }
        }
        let n = Self.fftSize
        if samples.count > 8 * n { samples.removeFirst(samples.count - 8 * n) }
        guard samples.count >= n else { return }

        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastDraw >= 1.0 / 30.0 else { return }
        lastDraw = now

        let bars = analyzer.magnitudes(Array(samples.suffix(n)), bars: Self.barCount)
        spectrumView.update(bars)
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}

// MARK: - FFT

/// Fixed-size real FFT producing log-frequency magnitude bars in 0...1.
private final class FFTAnalyzer {
    private let n: Int
    private let half: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private var window: [Float]

    init(size: Int) {
        n = size
        half = size / 2
        log2n = vDSP_Length(log2(Float(size)))
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = [Float](repeating: 0, count: size)
        vDSP_hann_window(&window, vDSP_Length(size), Int32(vDSP_HANN_NORM))
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    func magnitudes(_ input: [Float], bars: Int) -> [Float] {
        // Silence gate: below ~-72 dBFS RMS show an empty (flat) spectrum so a
        // muted/idle mic reads clearly as "no signal" rather than noise.
        var meanSq: Float = 0
        vDSP_measqv(input, 1, &meanSq, vDSP_Length(n))
        if sqrtf(meanSq) < 2.5e-4 { return [Float](repeating: 0, count: bars) }

        var windowed = [Float](repeating: 0, count: n)
        vDSP_vmul(input, 1, window, 1, &windowed, 1, vDSP_Length(n))

        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var amps = [Float](repeating: 0, count: half)   // linear magnitude per bin

        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { cp in
                        vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                vDSP_zvabs(&split, 1, &amps, 1, vDSP_Length(half))   // |X[k]|
                // vDSP_fft_zrip leaves a factor-of-2 scale; normalize by N.
                var scale = 1.0 / Float(n)
                vDSP_vsmul(amps, 1, &scale, &amps, 1, vDSP_Length(half))
            }
        }

        // Group bins into log-spaced bars, amplitude → dBFS, map -60..0 → 0..1.
        var out = [Float](repeating: 0, count: bars)
        for b in 0..<bars {
            let lo = Int(powf(Float(half), Float(b) / Float(bars)))
            let hi = max(lo + 1, Int(powf(Float(half), Float(b + 1) / Float(bars))))
            var peak: Float = 0
            var k = lo
            while k < min(hi, half) { peak = max(peak, amps[k]); k += 1 }
            let db = 20 * log10f(peak + 1e-7)
            out[b] = max(0, min(1, (db + 60) / 60))
        }
        return out
    }
}

// MARK: - View

private final class SpectrumView: NSView {
    private var bars: [Float] = []

    func update(_ values: [Float]) {
        bars = values
        needsDisplay = true
    }

    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        // Dark grey (not pure black) so the window never looks "dead".
        NSColor(calibratedWhite: 0.10, alpha: 1).setFill()
        bounds.fill()

        let hasSignal = bars.contains { $0 > 0.001 }

        // Caption: distinguishes "no audio yet" / "silent" from a live signal.
        let caption: String
        if bars.isEmpty { caption = "Waiting for mic audio…" }
        else if !hasSignal { caption = "Mic connected — silent (speak on the client)" }
        else { caption = "" }
        if !caption.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor(calibratedWhite: 0.75, alpha: 1),
                .font: NSFont.systemFont(ofSize: 13),
            ]
            let text = caption as NSString
            let size = text.size(withAttributes: attrs)
            text.draw(at: NSPoint(x: (bounds.width - size.width) / 2,
                                  y: bounds.height - size.height - 10),
                      withAttributes: attrs)
        }

        guard !bars.isEmpty else { return }

        let slot = bounds.width / CGFloat(bars.count)
        for (i, v) in bars.enumerated() {
            let h = max(2, CGFloat(v) * (bounds.height - 8))   // ≥2px baseline
            let rect = NSRect(x: CGFloat(i) * slot + 1, y: 0, width: slot - 2, height: h)
            // red (quiet) → green (loud) for an easy "is it live" read.
            NSColor(calibratedHue: 0.33 * CGFloat(v), saturation: 0.85,
                    brightness: v > 0.001 ? 0.95 : 0.4, alpha: 1).setFill()
            NSBezierPath(rect: rect).fill()
        }
    }
}
