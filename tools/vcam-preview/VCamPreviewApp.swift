//
//  VCamPreviewApp.swift
//  VCamPreview — in-process test harness for the MacRDP virtual camera.
//
//  Runs the *extension's* provider code inside a normal app (hosted mode), so
//  you can validate the whole pipeline — placeholder rendering, frame format,
//  feed → source routing — WITHOUT installing the system extension or touching
//  SIP. Frames the device would publish to a real CMIO consumer are delivered
//  to this app's delegate and drawn on screen.
//
//  How to use:
//    1. New target: macOS App "VCamPreview" (SwiftUI lifecycle).
//    2. Delete its generated @main App file (this file provides one).
//    3. Add to the target's "Compile Sources" (Target Membership):
//         - virtualcamera/virtualcameraProvider.swift
//         - virtualcamera/VirtualCameraManifest.swift
//         - this file
//    4. Run. "Start preview" shows the placeholder; "Feed test pattern" pushes
//       synthetic frames through feedHosted(_:) and you should see them.
//
//  Once this looks right, the same provider runs unchanged as the installed
//  system extension — there the delegate is nil and frames flow over CMIO.
//

import AVFoundation
import CoreImage
import CoreVideo
import SwiftUI

// MARK: - Driver

final class VCamPreviewDriver: ObservableObject, VirtualCameraHostedDelegate {

    @Published var image: CGImage?
    @Published var feeding = false

    private var provider: virtualcameraProviderSource!
    private let ciContext = CIContext()
    private var patternTimer: DispatchSourceTimer?
    private var hue: CGFloat = 0

    init() {
        // hostedDelegate non-nil → hosted (in-process) mode.
        provider = virtualcameraProviderSource(clientQueue: nil, hostedDelegate: self)
    }

    /// Start the device's source so the idle placeholder frame is emitted.
    func startPreview() {
        provider.startHostedPreview()
    }

    /// Toggle a synthetic 1280x720 BGRA feed to prove feed → display works.
    func toggleFeed() {
        feeding.toggle()
        if feeding {
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInteractive))
            timer.schedule(deadline: .now(), repeating: 1.0 / 30.0)
            timer.setEventHandler { [weak self] in
                guard let self, let pb = self.makePatternBuffer() else { return }
                self.provider.feedHosted(pb)
            }
            patternTimer = timer
            timer.resume()
        } else {
            patternTimer?.cancel()
            patternTimer = nil
        }
    }

    // VirtualCameraHostedDelegate — the device hands us each output frame here.
    func virtualCamera(didOutput sampleBuffer: CMSampleBuffer) {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ci = CIImage(cvImageBuffer: imageBuffer)
        guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { return }
        DispatchQueue.main.async { self.image = cg }
    }

    // A moving solid-color frame in the exact format the camera expects
    // (kFrameWidth/kFrameHeight come from the provider source).
    private func makePatternBuffer() -> CVPixelBuffer? {
        let w = Int(kFrameWidth), h = Int(kFrameHeight)
        let attrs: NSDictionary = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as NSDictionary,
        ]
        var pb: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, w, h,
            kCVPixelFormatType_32BGRA, attrs, &pb) == kCVReturnSuccess, let pb else {
            return nil
        }
        hue += 0.01; if hue > 1 { hue -= 1 }
        let color = NSColor(hue: hue, saturation: 0.8, brightness: 0.9, alpha: 1)
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        if let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(pb), width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue)
        {
            ctx.setFillColor(color.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
        return pb
    }
}

// MARK: - UI

struct VCamPreviewContentView: View {
    @StateObject private var driver = VCamPreviewDriver()

    var body: some View {
        VStack(spacing: 12) {
            Group {
                if let image = driver.image {
                    Image(image, scale: 1, label: Text("preview"))
                        .resizable().aspectRatio(contentMode: .fit)
                } else {
                    Text("Press “Start preview”").foregroundStyle(.secondary)
                }
            }
            .frame(width: 640, height: 360)
            .background(.black)

            HStack {
                Button("Start preview") { driver.startPreview() }
                Button(driver.feeding ? "Stop feed" : "Feed test pattern") { driver.toggleFeed() }
            }
        }
        .padding()
    }
}

@main
struct VCamPreviewApp: App {
    var body: some Scene {
        WindowGroup("MacRDP VCam Preview") { VCamPreviewContentView() }
    }
}
