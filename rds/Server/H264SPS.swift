//
//  H264SPS.swift
//  MacRDP
//
//  Makes an H.264 sequence parameter set say the stream never reorders
//  frames. Without VUI bitstream_restriction a decoder must assume pictures
//  may come out up to a full DPB late (4 frames at 1080p level 4.2) and may
//  hold the first ones back. mstsc does: it waits for each GFX frame's
//  picture before reading the next PDU, so the first H.264 frame never
//  completes and the session's picture freezes for good. The encoder of a
//  Virtualization.framework guest writes no bitstream_restriction (and no
//  VUI at all unless the input carries colour attachments).
//

import Foundation

enum H264SPS {
    /// `nal` (header byte included, no start code) with VUI
    /// bitstream_restriction declaring max_num_reorder_frames = 0, or `nal`
    /// unchanged when it already has one or isn't an SPS this parser handles.
    static func addingNoReorderVUI(_ nal: Data) -> Data {
        let bytes = [UInt8](nal)
        guard bytes.count > 4, bytes[0] & 0x1F == 7 else { return nal }
        let rbsp = unescape(bytes[1...])
        var r = BitReader(rbsp)
        guard let (vuiFlagBit, maxRefFrames) = parseUpToVUIFlag(&r) else { return nal }

        var w = BitWriter()
        if r.bit() == 0 {
            w.copy(rbsp, bits: vuiFlagBit)
            w.bit(1)                     // vui_parameters_present_flag
            for _ in 0..<8 { w.bit(0) }  // aspect ratio .. pic_struct: none present
        } else {
            guard let restrictionBit = parseVUIUpToRestrictionFlag(&r),
                  r.bit() == 0 else { return nal }
            w.copy(rbsp, bits: restrictionBit)
        }
        w.bit(1)                     // bitstream_restriction_flag
        w.bit(1)                     // motion_vectors_over_pic_boundaries_flag
        w.ue(2)                      // max_bytes_per_pic_denom (default)
        w.ue(1)                      // max_bits_per_mb_denom (default)
        w.ue(16)                     // log2_max_mv_length_horizontal (default)
        w.ue(16)                     // log2_max_mv_length_vertical (default)
        w.ue(0)                      // max_num_reorder_frames
        w.ue(max(1, maxRefFrames))   // max_dec_frame_buffering
        w.bit(1)                     // rbsp_stop_one_bit
        while w.count % 8 != 0 { w.bit(0) }
        return Data([bytes[0]] + escape(w.bytes))
    }

    /// Walks the SPS up to vui_parameters_present_flag; returns its bit
    /// offset and max_num_ref_frames, nil for SPS this doesn't handle
    /// (scaling matrices) or a truncated one.
    private static func parseUpToVUIFlag(_ r: inout BitReader) -> (Int, Int)? {
        let profile = r.bits(8)
        _ = r.bits(16)                                   // constraint flags, level_idc
        _ = r.ue()                                       // seq_parameter_set_id
        if [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135].contains(profile) {
            if r.ue() == 3 { _ = r.bit() }               // chroma_format_idc, separate_colour_plane
            _ = r.ue(); _ = r.ue()                       // bit depths
            _ = r.bit()                                  // qpprime_y_zero_transform_bypass
            if r.bit() == 1 { return nil }               // seq_scaling_matrix_present
        }
        _ = r.ue()                                       // log2_max_frame_num_minus4
        switch r.ue() {                                  // pic_order_cnt_type
        case 0: _ = r.ue()
        case 1:
            _ = r.bit(); _ = r.ue(); _ = r.ue()          // se(v) reads like ue(v) here
            for _ in 0..<min(r.ue(), 256) { _ = r.ue() }
        default: break
        }
        let maxRefFrames = r.ue()
        _ = r.bit()                                      // gaps_in_frame_num_value_allowed
        _ = r.ue(); _ = r.ue()                           // picture size in macroblocks
        if r.bit() == 0 { _ = r.bit() }                  // frame_mbs_only, mb_adaptive_frame_field
        _ = r.bit()                                      // direct_8x8_inference
        if r.bit() == 1 { for _ in 0..<4 { _ = r.ue() } } // frame cropping
        return r.overrun ? nil : (r.position, maxRefFrames)
    }

    /// Walks a VUI up to bitstream_restriction_flag; returns its bit offset.
    private static func parseVUIUpToRestrictionFlag(_ r: inout BitReader) -> Int? {
        if r.bit() == 1 { if r.bits(8) == 255 { _ = r.bits(32) } }  // aspect ratio, SAR
        if r.bit() == 1 { _ = r.bit() }                              // overscan
        if r.bit() == 1 {                                            // video signal type
            _ = r.bits(4)
            if r.bit() == 1 { _ = r.bits(24) }                       // colour description
        }
        if r.bit() == 1 { _ = r.ue(); _ = r.ue() }                   // chroma sample location
        if r.bit() == 1 { _ = r.bits(32); _ = r.bits(32); _ = r.bit() } // timing
        var hrd = false
        for _ in 0..<2 where r.bit() == 1 {                          // NAL, VCL HRD
            hrd = true
            let cpbCount = min(r.ue(), 31) + 1
            _ = r.bits(8)                                            // bit rate, CPB size scale
            for _ in 0..<cpbCount { _ = r.ue(); _ = r.ue(); _ = r.bit() }
            _ = r.bits(20)                                           // delay and offset lengths
        }
        if hrd { _ = r.bit() }                                       // low_delay_hrd
        _ = r.bit()                                                  // pic_struct_present
        return r.overrun ? nil : r.position
    }

    private static func unescape(_ b: ArraySlice<UInt8>) -> [UInt8] {
        var out: [UInt8] = []; out.reserveCapacity(b.count)
        var zeros = 0
        for x in b {
            if zeros >= 2 && x == 3 { zeros = 0; continue }
            zeros = x == 0 ? zeros + 1 : 0
            out.append(x)
        }
        return out
    }

    private static func escape(_ b: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []; out.reserveCapacity(b.count + 4)
        var zeros = 0
        for x in b {
            if zeros >= 2 && x <= 3 { out.append(3); zeros = 0 }
            zeros = x == 0 ? zeros + 1 : 0
            out.append(x)
        }
        return out
    }

    private struct BitReader {
        let data: [UInt8]
        var position = 0
        var overrun = false
        init(_ data: [UInt8]) { self.data = data }

        mutating func bit() -> Int {
            guard position < data.count * 8 else { overrun = true; return 0 }
            defer { position += 1 }
            return Int(data[position >> 3] >> (7 - UInt8(position & 7)) & 1)
        }
        mutating func bits(_ n: Int) -> Int {
            var v = 0
            for _ in 0..<n { v = v << 1 | bit() }
            return v
        }
        mutating func ue() -> Int {
            var zeros = 0
            while bit() == 0 && !overrun && zeros < 32 { zeros += 1 }
            return (1 << zeros) - 1 + bits(zeros)
        }
    }

    private struct BitWriter {
        var bytes: [UInt8] = []
        var count = 0
        mutating func bit(_ b: UInt8) {
            if count % 8 == 0 { bytes.append(0) }
            bytes[bytes.count - 1] |= (b & 1) << (7 - UInt8(count % 8))
            count += 1
        }
        mutating func copy(_ data: [UInt8], bits: Int) {
            for i in 0..<bits { bit(data[i >> 3] >> (7 - UInt8(i & 7)) & 1) }
        }
        mutating func ue(_ v: Int) {
            let x = v + 1
            let n = Int.bitWidth - x.leadingZeroBitCount
            for _ in 0..<(n - 1) { bit(0) }
            for i in stride(from: n - 1, through: 0, by: -1) { bit(UInt8(x >> i & 1)) }
        }
    }
}
