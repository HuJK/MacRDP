// imgcmp — compare what the RDP client shows with what the Mac shows.
//
//   imgcmp psnr <a> <b> [--skip x0 y0 x1 y1]  # both scaled to the smaller one; prints
//                                             # psnr=… mad=… size=WxH, optionally ignoring a region
//   imgcmp diff <a> <b> <x0> <y0> <x1> <y1>   # mean absolute difference inside a region
//   imgcmp mean <img> <x0> <y0> <x1> <y1>     # mean "r g b" (0-255) of a region
//   imgcmp tiles <ref> <img> <px> [mad]       # tiles (px square, column,row) whose mean
//                                             # absolute difference exceeds mad (default 12)
//   imgcmp converge <samples> <ref> <x> <y> <w> <h> [mad]  # how long after the client shows
//                                             # a held scene's final sprite rect every 64 px tile
//                                             # matches <ref> (MstscSampler data, gunzipped)
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

case "tiles":
    // Per-tile mean absolute difference, both images at the reference's size.
    guard args.count >= 4, let ts = Int(args[3]), ts > 0 else {
        fail("usage: imgcmp tiles <ref> <img> <tile px> [mad threshold]")
    }
    let limit = args.count > 4 ? Double(args[4]) ?? 12 : 12
    let ref = load(args[1]), img = load(args[2])
    let w = ref.width, h = ref.height
    let pr = pixels(ref, w, h), pi = pixels(img, w, h)
    let cols = (w + ts - 1) / ts, rows = (h + ts - 1) / ts
    var stale: [(Int, Int, Double)] = []
    for row in 0..<rows {
        for col in 0..<cols {
            var ad = 0.0, n = 0.0
            for y in row * ts..<min(h, (row + 1) * ts) {
                for x in col * ts..<min(w, (col + 1) * ts) {
                    let i = (y * w + x) * 4
                    for c in 0..<3 { ad += abs(Double(pr[i + c]) - Double(pi[i + c])) }
                    n += 3
                }
            }
            if ad / n > limit { stale.append((col, row, ad / n)) }
        }
    }
    let worst = stale.sorted { $0.2 > $1.2 }.prefix(8).map { String(format: "%d,%d:%.0f", $0.0, $0.1, $0.2) }
    print("stale=\(stale.count)/\(cols * rows)" + (worst.isEmpty ? "" : " worst=" + worst.joined(separator: " ")))

case "converge":
    // Samples from MstscSampler (gunzipped) against the Mac's picture once a
    // scene held still. The hold shows on the client when the tiles under
    // the sprite's final rect first match; it lasts while they keep
    // matching. Within it: when did every tile match for good, and how long
    // after the final sprite tiles?
    guard args.count >= 7, let rx = Int(args[3]), let ry = Int(args[4]),
          let rw = Int(args[5]), let rh = Int(args[6]) else {
        fail("usage: imgcmp converge <samples> <ref.png> <x> <y> <w> <h> [mad]")
    }
    let limit = args.count > 7 ? Double(args[7]) ?? 10 : 10
    guard let raw = FileManager.default.contents(atPath: args[1]), raw.count > 12,
          raw.prefix(4) == Data("MRDS".utf8) else { fail("not a sampler file: \(args[1])") }
    func i32(_ o: Int) -> Int { Int(raw.subdata(in: o..<o + 4).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }) }
    func i64(_ o: Int) -> Int64 { raw.subdata(in: o..<o + 8).withUnsafeBytes { $0.loadUnaligned(as: Int64.self) } }
    let bw = i32(4), bh = i32(8), block = 8, tb = 64 / block
    let frameBytes = 8 + bw * bh * 3
    let count = (raw.count - 12) / frameBytes
    guard count > 0 else { fail("no frames") }

    // The reference in the same 8x8 block means.
    let ref = load(args[2])
    let rp = pixels(ref, bw * block, bh * block)
    var refBlocks = [Double](repeating: 0, count: bw * bh * 3)
    for by in 0..<bh {
        for bx in 0..<bw {
            for c in 0..<3 {
                var s = 0.0
                for y in 0..<block { for x in 0..<block { s += Double(rp[((by * block + y) * bw * block + bx * block + x) * 4 + c]) } }
                refBlocks[(by * bw + bx) * 3 + c] = s / Double(block * block)
            }
        }
    }
    let cols = (bw + tb - 1) / tb, rows = (bh + tb - 1) / tb
    /// Stale tiles (index → mad) of frame f.
    func stale(_ f: Int) -> [Int: Double] {
        let base = 12 + f * frameBytes + 8
        var out: [Int: Double] = [:]
        raw.withUnsafeBytes { (b: UnsafeRawBufferPointer) in
            for row in 0..<rows {
                for col in 0..<cols {
                    var ad = 0.0, n = 0.0
                    for by in row * tb..<min(bh, (row + 1) * tb) {
                        for bx in col * tb..<min(bw, (col + 1) * tb) {
                            let i = (by * bw + bx) * 3
                            for c in 0..<3 { ad += abs(Double(b[base + i + c]) - refBlocks[i + c]) }
                            n += 3
                        }
                    }
                    if ad / n > limit { out[row * cols + col] = ad / n }
                }
            }
        }
        return out
    }
    let finalTiles = Set((max(0, ry / 64)...min(rows - 1, (ry + rh - 1) / 64)).flatMap { r in
        (max(0, rx / 64)...min(cols - 1, (rx + rw - 1) / 64)).map { r * cols + $0 } })
    let staleAll = (0..<count).map(stale)
    let finalOK = staleAll.map { s in finalTiles.allSatisfy { s[$0] == nil } }
    guard let first = finalOK.firstIndex(of: true) else {
        // The client never showed the held picture. Its closest frame tells
        // how far off it stayed (a few tiles = stuck on an earlier frame).
        let best = staleAll.indices.min { staleAll[$0].count < staleAll[$1].count }!
        let worst = staleAll[best].sorted { $0.value > $1.value }.prefix(6)
            .map { String(format: "%d,%d:%.0f", $0.key % cols, $0.key / cols, $0.value) }
        print("lag=never-final closest=\(staleAll[best].count)/\(cols * rows) worst=" + worst.joined(separator: " "))
        exit(0)
    }
    var last = first
    while last + 1 < count && finalOK[last + 1] { last += 1 }
    let t = { (f: Int) in i64(12 + f * frameBytes) }
    var conv: Int? = staleAll[last].isEmpty ? last : nil
    if conv != nil { while let c = conv, c > first, staleAll[c - 1].isEmpty { conv = c - 1 } }
    let peak = staleAll[first...last].map(\.count).max() ?? 0
    let endStale = staleAll[last]
    let worst = endStale.sorted { $0.value > $1.value }.prefix(6)
        .map { String(format: "%d,%d:%.0f", $0.key % cols, $0.key / cols, $0.value) }
    let hold = t(last) - t(first)
    if let c = conv {
        print("lag=\(t(c) - t(first)) peak=\(peak) hold=\(hold) frames=\(last - first + 1)")
    } else {
        print("lag=never peak=\(peak) hold=\(hold) stale_at_end=\(endStale.count) worst=" + worst.joined(separator: " "))
    }

case "frame":
    // One MstscSampler frame as a PNG (each 8x8 block mean as one pixel),
    // and its unix ms on stdout: for looking at what a check saw.
    guard args.count == 4, let f = Int(args[2]),
          let raw = FileManager.default.contents(atPath: args[1]), raw.prefix(4) == Data("MRDS".utf8) else {
        fail("usage: imgcmp frame <samples> <index> <out.png>")
    }
    let bw = Int(raw.subdata(in: 4..<8).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
    let bh = Int(raw.subdata(in: 8..<12).withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
    let frameBytes = 8 + bw * bh * 3, base = 12 + f * frameBytes
    guard f >= 0, base + frameBytes <= raw.count else { fail("no frame \(f)") }
    var rgba = [UInt8](repeating: 255, count: bw * bh * 4)
    for i in 0..<(bw * bh) { for c in 0..<3 { rgba[i * 4 + c] = raw[base + 8 + i * 3 + c] } }
    let ctx = rgba.withUnsafeMutableBytes { b in
        CGContext(data: b.baseAddress, width: bw, height: bh, bitsPerComponent: 8, bytesPerRow: bw * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!.makeImage()!
    }
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[3]) as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx, nil)
    CGImageDestinationFinalize(dest)
    print(raw.subdata(in: base..<base + 8).withUnsafeBytes { $0.loadUnaligned(as: Int64.self) })

default:
    fail("usage: imgcmp psnr|diff|mean|tiles|converge|frame … (see the header)")
}
