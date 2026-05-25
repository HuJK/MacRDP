//
//  NV12Converter.swift
//  MacRDP
//
//  BGRA → full-range NV12 conversion for the hybrid H.264 path.
//
//  Why this exists: when VideoToolbox is fed BGRA it converts RGB→YUV using
//  *limited/video* range (white → Y=235, black → Y=16) and flags
//  video_full_range_flag=0. But RDP clients — FreeRDP's AVC decoder uses
//  C(Y)=Y-0, i.e. plain *full* range — read those values as-is, so white lands
//  at ~92% gray: the H.264 tiles look darker than the Progressive tiles.
//
//  Fix: convert to YUV ourselves at FULL range so white → Y=255, matching the
//  client. We also match FreeRDP's matrix (its YUV→RGB coefficients are BT.709,
//  not 601 — see prim_internal.h) so colour is seam-free too. VideoToolbox
//  can't be told to do a full-range RGB→YUV conversion via session properties,
//  so the input must already be full-range YUV.
//

import Foundation
@preconcurrency import CoreVideo
import Accelerate
import os

final class NV12Converter {
    private var info = vImage_ARGBToYpCbCr()
    private var pool: CVPixelBufferPool?
    private var poolW = 0
    private var poolH = 0

    /// Fails only if vImage can't build the conversion (effectively never).
    init?() {
        // Full-range 8-bit: Yp 0…255 (bias 0), CbCr 0…255 (bias 128).
        var range = vImage_YpCbCrPixelRange(
            Yp_bias: 0, CbCr_bias: 128,
            YpRangeMax: 255, CbCrRangeMax: 255,
            YpMax: 255, YpMin: 0, CbCrMax: 255, CbCrMin: 0)
        // BT.709 to match FreeRDP's decoder coefficients.
        let err = vImageConvert_ARGBToYpCbCr_GenerateConversion(
            kvImage_ARGBToYpCbCrMatrix_ITU_R_709_2, &range, &info,
            kvImageARGB8888, kvImage420Yp8_CbCr8, vImage_Flags(kvImageNoFlags))
        guard err == kvImageNoError else {
            Log.encoder.error("NV12Converter: GenerateConversion failed (\(err))")
            return nil
        }
    }

    /// Convert a 32BGRA pixel buffer to a fresh full-range NV12 pixel buffer
    /// (tagged BT.709 / full range so the encoder writes a correct VUI). Returns
    /// nil on allocation/convert failure.
    func convert(_ bgra: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(bgra)
        let height = CVPixelBufferGetHeight(bgra)
        guard width > 0, height > 0, let pool = ensurePool(width, height) else { return nil }

        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &out) == kCVReturnSuccess,
              let nv12 = out else { return nil }

        // Tag colour so VideoToolbox emits a correct VUI (matrix=709, full
        // range). FreeRDP ignores the VUI, but spec-compliant clients honour it.
        CVBufferSetAttachment(nv12, kCVImageBufferYCbCrMatrixKey,
                              kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(nv12, kCVImageBufferColorPrimariesKey,
                              kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(nv12, kCVImageBufferTransferFunctionKey,
                              kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)

        CVPixelBufferLockBaseAddress(bgra, .readOnly)
        CVPixelBufferLockBaseAddress(nv12, [])
        defer {
            CVPixelBufferUnlockBaseAddress(nv12, [])
            CVPixelBufferUnlockBaseAddress(bgra, .readOnly)
        }
        guard let srcBase = CVPixelBufferGetBaseAddress(bgra),
              let yBase = CVPixelBufferGetBaseAddressOfPlane(nv12, 0),
              let cbcrBase = CVPixelBufferGetBaseAddressOfPlane(nv12, 1) else { return nil }

        var src = vImage_Buffer(data: srcBase,
                                height: vImagePixelCount(height),
                                width: vImagePixelCount(width),
                                rowBytes: CVPixelBufferGetBytesPerRow(bgra))
        var yp = vImage_Buffer(data: yBase,
                               height: vImagePixelCount(CVPixelBufferGetHeightOfPlane(nv12, 0)),
                               width: vImagePixelCount(CVPixelBufferGetWidthOfPlane(nv12, 0)),
                               rowBytes: CVPixelBufferGetBytesPerRowOfPlane(nv12, 0))
        var cbcr = vImage_Buffer(data: cbcrBase,
                                 height: vImagePixelCount(CVPixelBufferGetHeightOfPlane(nv12, 1)),
                                 width: vImagePixelCount(CVPixelBufferGetWidthOfPlane(nv12, 1)),
                                 rowBytes: CVPixelBufferGetBytesPerRowOfPlane(nv12, 1))

        // BGRA byte order → the ARGB the matrix expects: A,R,G,B ← src[3,2,1,0].
        let permute: [UInt8] = [3, 2, 1, 0]
        let err = vImageConvert_ARGB8888To420Yp8_CbCr8(
            &src, &yp, &cbcr, &info, permute, vImage_Flags(kvImageNoFlags))
        guard err == kvImageNoError else {
            Log.encoder.error("NV12Converter: convert failed (\(err))")
            return nil
        }
        return nv12
    }

    private func ensurePool(_ width: Int, _ height: Int) -> CVPixelBufferPool? {
        if let pool, poolW == width, poolH == height { return pool }
        let pbAttrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: Int(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) as CFNumber,
            kCVPixelBufferWidthKey: width as CFNumber,
            kCVPixelBufferHeightKey: height as CFNumber,
            // IOSurface-backed so VideoToolbox can take it zero-copy.
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var p: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, pbAttrs as CFDictionary, &p)
                == kCVReturnSuccess, let newPool = p else { return nil }
        pool = newPool; poolW = width; poolH = height
        return newPool
    }
}
