// imgcmp — compare what the RDP client shows with what the Mac shows.
//
//   imgcmp psnr <a> <b> [--skip x0 y0 x1 y1]  # both scaled to the smaller one; prints
//                                             # psnr=… mad=… size=WxH, optionally ignoring a region
//   imgcmp diff <a> <b> <x0> <y0> <x1> <y1>   # mean absolute difference inside a region
//   imgcmp mean <img> <x0> <y0> <x1> <y1>     # mean "r g b" (0-255) of a region
// Regions are fractions of the image, top-left origin.
//
// Runs on the host (scripts/check-basics.sh); no numpy there, so this uses
// CoreGraphics. Scaling uses high-quality interpolation, which is close to
// MacRDP's own downscale when the session is smaller than the Mac display.

import CoreGraphics
import Foundation
import ImageIO

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(2)
}

func load(_ path: String) -> CGImage {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fail("cannot read \(path)") }
    return img
}

/// RGBA8 pixels of `img` drawn at w x h.
func pixels(_ img: CGImage, _ w: Int, _ h: Int) -> [UInt8] {
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    buf.withUnsafeMutableBytes { raw in
        let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    return buf
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "psnr", "diff":
    let isDiff = args.first == "diff"
    guard args.count == (isDiff ? 7 : 3) || (!isDiff && args.count == 8 && args[3] == "--skip") else {
        fail("usage: imgcmp psnr <a> <b> [--skip x0 y0 x1 y1] | imgcmp diff <a> <b> <x0> <y0> <x1> <y1>")
    }
    let a = load(args[1]), b = load(args[2])
    let (w, h) = a.width * a.height <= b.width * b.height ? (a.width, a.height) : (b.width, b.height)
    let pa = pixels(a, w, h), pb = pixels(b, w, h)
    let r = args.count > 3 ? args.suffix(4).map { Double($0) ?? 0 } : [0, 0, 0, 0]
    let inRegion = { (x: Int, y: Int) -> Bool in
        Double(x) >= r[0] * Double(w) && Double(x) < r[2] * Double(w) &&
        Double(y) >= r[1] * Double(h) && Double(y) < r[3] * Double(h)
    }
    var se = 0.0, ad = 0.0, n = 0.0
    for y in 0..<h {
        for x in 0..<w where inRegion(x, y) == isDiff {
            let i = (y * w + x) * 4
            for c in 0..<3 {
                let d = Double(pa[i + c]) - Double(pb[i + c])
                se += d * d; ad += abs(d)
            }
            n += 3
        }
    }
    if isDiff { print(String(format: "%.2f", ad / n)); exit(0) }
    let mse = se / n
    let psnr = mse == 0 ? 99.0 : 10 * log10(255 * 255 / mse)
    print(String(format: "psnr=%.2f mad=%.2f size=%dx%d", psnr, ad / n, w, h))

case "mean":
    guard args.count == 6, let x0 = Double(args[2]), let y0 = Double(args[3]),
          let x1 = Double(args[4]), let y1 = Double(args[5]) else { fail("usage: imgcmp mean <img> <x0> <y0> <x1> <y1>") }
    let img = load(args[1])
    let w = img.width, h = img.height
    let px = pixels(img, w, h)
    var sum = [0.0, 0.0, 0.0], n = 0.0
    // The bitmap's first row is the image's top row, like the fractions.
    for y in Int(y0 * Double(h))..<Int(y1 * Double(h)) {
        for x in Int(x0 * Double(w))..<Int(x1 * Double(w)) {
            let i = (y * w + x) * 4
            for c in 0..<3 { sum[c] += Double(px[i + c]) }
            n += 1
        }
    }
    print(String(format: "%.0f %.0f %.0f", sum[0] / n, sum[1] / n, sum[2] / n))

default:
    fail("usage: imgcmp psnr|diff|mean … (see the header)")
}
