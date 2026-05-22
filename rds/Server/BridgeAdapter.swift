//
//  BridgeAdapter.swift
//  MacRDP
//
//  Swift-side wrapper around the C bridge (CFreeRDPBridge.h). Activated
//  only when both:
//    1. The bridging header is wired in Xcode (Build Settings →
//       "Objective-C Bridging Header" = MacRDP/Bridge/CFreeRDPBridge.h)
//    2. The Swift active compilation condition MACRDP_BRIDGE_AVAILABLE
//       is set (Build Settings → "Active Compilation Conditions").
//
//  Until both are set this file is a tiny no-op so the project keeps
//  building; once both are flipped, the wrapper takes over and exposes
//  a `BridgePeer` Swift type that owns a `macrdp_session_t`.
//

#if MACRDP_BRIDGE_AVAILABLE

import Foundation
@preconcurrency import CoreMedia
import os

/// Thin Swift wrapper around an `macrdp_session_t`. Owned by an
/// RDPSession. All callbacks come back on the bridge's event-loop
/// thread and are then hopped to MainActor by the caller.
final class BridgePeer: @unchecked Sendable {

    /// Client's RDP audio redirection choice (Local Resources tab).
    enum AudioMode: Int32 {
        case doNotPlay         = 0   // MACRDP_AUDIO_MODE_NONE
        case playOnRemote      = 1   // MACRDP_AUDIO_MODE_REMOTE
        case playOnThisComputer = 2  // MACRDP_AUDIO_MODE_REDIRECTED
    }

    /// Format mstsc chose at RDPSND activation.
    enum AudioFormat: Int32 {
        case pcm = 0   // MACRDP_AUDIO_FORMAT_PCM
        case aac = 1   // MACRDP_AUDIO_FORMAT_AAC
    }

    /// What the bridge calls back into.
    struct Sinks {
        var onActivated: (_ width: Int, _ height: Int,
                          _ bpp: Int, _ connectionType: Int,
                          _ audioMode: AudioMode) -> Void = { _,_,_,_,_ in }
        var onClosed:    (_ reason: Int) -> Void = { _ in }
        var onMouse:     (_ flags: UInt16, _ x: Int, _ y: Int) -> Void = { _,_,_ in }
        var onKeyboard:  (_ flags: UInt16, _ scancode: UInt16) -> Void = { _,_ in }
        var onUnicode:   (_ flags: UInt16, _ code: UInt16) -> Void = { _,_ in }
        var onDispLayout:(_ monitors: [MonitorLayout]) -> Void = { _ in }
        var onFrameAck:  (_ frameID: UInt32) -> Void = { _ in }
        var onClipFormatList: (_ formats: [(id: UInt32, name: String?)]) -> Void = { _ in }
        var onClipDataRequest: (_ formatID: UInt32) -> Void = { _ in }
        var onClipDataResponse: (_ formatID: UInt32, _ data: Data) -> Void = { _,_ in }
        var onClipReady: () -> Void = { }
        var onClipFormatListResponse: (_ success: Bool) -> Void = { _ in }
        var onClipFileContentsRequest: (_ streamID: UInt32, _ listIndex: UInt32,
                                        _ wantSize: Bool, _ offset: UInt64,
                                        _ length: UInt32) -> Void = { _,_,_,_,_ in }
        var onClipFileContentsResponse: (_ streamID: UInt32, _ data: Data) -> Void = { _,_ in }
        var onAudioInFrame: (_ pcm: Data, _ sampleRate: Int, _ channels: Int) -> Void = { _,_,_ in }
        var onAudioFormatSelected: (_ format: AudioFormat) -> Void = { _ in }
        var onSuppressOutput: (_ allow: Bool) -> Void = { _ in }
        var onRdpdrDeviceAdded: (_ deviceID: UInt32, _ deviceType: UInt32,
                                 _ dosName: String) -> Void = { _,_,_ in }
        var onRdpdrDeviceRemoved: (_ deviceID: UInt32) -> Void = { _ in }
    }

    private var session: macrdp_session_t?
    let sinks: Sinks

    /// Serializes every `macrdp_session_send_clip_*` call. FreeRDP's
    /// server-side cliprdr send path (`cliprdr_server_packet_send`)
    /// calls `WTSVirtualChannelWrite` without locking, so concurrent
    /// writes from two Swift threads can interleave bytes on the wire
    /// — observed as receive-side PDU desync when Finder fetches
    /// multiple FileProvider items in parallel.
    private let cliprdrSendLock = NSLock()

    /// `Unmanaged.passUnretained(self).toOpaque()` is stable for the
    /// lifetime of the object, so recomputing is fine and avoids the
    /// "self before init" hazard.
    private var ctx: UnsafeMutableRawPointer {
        Unmanaged.passUnretained(self).toOpaque()
    }

    init(fd: Int32, config: Config, sinks: Sinks) throws {
        self.sinks = sinks

        var cbs = macrdp_callbacks()
        cbs.on_activated                 = Self.cbActivated
        cbs.on_closed                    = Self.cbClosed
        cbs.on_input_mouse               = Self.cbMouse
        cbs.on_input_keyboard            = Self.cbKeyboard
        cbs.on_input_unicode             = Self.cbUnicode
        cbs.on_disp_monitor_layout       = Self.cbDispLayout
        cbs.on_frame_acknowledge         = Self.cbFrameAck
        cbs.on_clip_format_list          = Self.cbClipFormatList
        cbs.on_clip_data_request         = Self.cbClipDataRequest
        cbs.on_clip_data_response        = Self.cbClipDataResponse
        cbs.on_clip_ready                = Self.cbClipReady
        cbs.on_clip_format_list_response = Self.cbClipFormatListResponse
        cbs.on_clip_file_contents_request  = Self.cbClipFileContentsRequest
        cbs.on_clip_file_contents_response = Self.cbClipFileContentsResponse
        cbs.on_audio_in_frame            = Self.cbAudioInFrame
        cbs.on_audio_format_selected     = Self.cbAudioFormatSelected
        cbs.on_suppress_output           = Self.cbSuppressOutput
        cbs.on_rdpdr_device_added        = Self.cbRdpdrDeviceAdded
        cbs.on_rdpdr_device_removed      = Self.cbRdpdrDeviceRemoved

        var cfg = macrdp_session_config()
        cfg.require_nla              = config.auth.requireNLA ? 1 : 0
        cfg.default_bitrate_kbps     = Int32(config.video.bitrateKbps)
        cfg.default_max_fps          = Int32(config.video.maxFps)
        cfg.prefer_avc444            = config.video.preferAVC444 ? 1 : 0
        cfg.max_outstanding_frames   = Int32(config.video.maxOutstandingFrames)
        cfg.avc420_qp                = Int32(config.video.avc420Qp)
        cfg.avc420_quality_val       = Int32(config.video.avc420QualityVal)
        cfg.enable_audio_out         = config.audioOut.enabled ? 1 : 0
        cfg.enable_audio_in          = config.audioIn.enabled  ? 1 : 0
        cfg.enable_clipboard         = (config.clipboard.text || config.clipboard.image
                                        || config.clipboard.files) ? 1 : 0
        cfg.enable_disp              = (config.display.resizeHook != nil) ? 1 : 0
        cfg.enable_rdpdr             = config.rdpdr.enabled ? 1 : 0

        // TLS paths. Pin the bytes for the duration of the C call —
        // freerdp_key_new_from_file_enc reads the file immediately so we
        // don't need to keep them alive after macrdp_session_create
        // returns.
        let certPath = config.auth.certificateFile ?? ""
        let keyPath  = config.auth.privateKeyFile  ?? ""
        let rc: Int32 = certPath.withCString { cPtr -> Int32 in
            keyPath.withCString { kPtr -> Int32 in
                if !certPath.isEmpty { cfg.tls_cert_pem_path = cPtr }
                if !keyPath.isEmpty  { cfg.tls_key_pem_path  = kPtr }
                var session: macrdp_session_t?
                let r = macrdp_session_create(fd, self.ctx, &cbs, &cfg, &session)
                if r == MACRDP_OK, let s = session {
                    self.session = s
                }
                return r
            }
        }
        guard rc == MACRDP_OK, session != nil else {
            throw MacRDPError.bridgeFailed(rc: rc)
        }
    }

    deinit {
        if let s = session { macrdp_session_destroy(s) }
    }

    func runLoop() -> Int32 {
        guard let s = session else { return MACRDP_E_DISCONNECTED }
        return macrdp_session_run(s)
    }

    func requestStop() {
        if let s = session { macrdp_session_request_stop(s) }
    }

    // MARK: - Outbound

    /// Push an encoded H.264 frame to the GFX channel. Returns true if
    /// sent, false if dropped by flow control (caller should mark the
    /// next encoded frame as IDR so the client can resync).
    @discardableResult
    func sendH264(_ annexB: Data, surfaceID: Int32, isIDR: Bool, pts: CMTime) -> Bool {
        guard let s = session else { return false }
        let ptsMicros: Int64
        let secs = CMTimeGetSeconds(pts)
        ptsMicros = secs.isFinite ? Int64((secs * 1_000_000).rounded()) : 0
        return annexB.withUnsafeBytes { raw -> Bool in
            let ptr = raw.baseAddress?.assumingMemoryBound(to: UInt8.self)
            let rc = macrdp_session_send_h264_frame(
                s, surfaceID, ptr, annexB.count,
                isIDR ? 1 : 0,
                ptsMicros)
            return rc == MACRDP_OK
        }
    }

    /// Number of frames in flight (sent but unacked). Use as a
    /// backpressure signal to skip capture/encode work.
    var outstandingFrames: Int32 {
        guard let s = session else { return 0 }
        return macrdp_session_outstanding_frames(s)
    }

    /// Override the desktop size used for RESETGRAPHICS / CreateSurface
    /// / MapSurfaceToOutput. Call before sending the first frame at the
    /// new size, e.g. when the captured display's aspect ratio doesn't
    /// match the client's negotiated request.
    func setDesktopSize(width: Int, height: Int) {
        guard let s = session else { return }
        macrdp_session_set_desktop_size(s, Int32(width), Int32(height))
    }

    /// Push a chunk of Int16LE stereo @ 48 kHz PCM to RDPSND.
    @discardableResult
    func sendAudioPCM(_ pcm: Data) -> Bool {
        guard let s = session else { return false }
        return pcm.withUnsafeBytes { raw -> Bool in
            let ptr = raw.baseAddress?.assumingMemoryBound(to: UInt8.self)
            let rc = macrdp_session_send_audio_pcm(s, ptr, pcm.count)
            return rc == MACRDP_OK
        }
    }

    /// RemoteFX Progressive V2 path: hand a raw BGRA buffer to FreeRDP's
    /// wavelet encoder. Pointer must be valid for the duration of the call.
    @discardableResult
    func sendProgressive(bgra: UnsafePointer<UInt8>,
                         surfaceID: Int32,
                         width: Int, height: Int, stride: Int) -> Bool {
        guard let s = session else { return false }
        let rc = macrdp_session_send_progressive_frame(
            s, surfaceID, bgra,
            Int32(width), Int32(height), Int32(stride))
        return rc == MACRDP_OK
    }

    /// Ship one AAC-LC packet (raw frame bytes) via the Wave2 PDU path.
    /// `pcmSampleCount` is how many PCM samples this packet decodes to
    /// (1024 for AAC-LC). Used for the Wave2 audioTimeStamp field so
    /// mstsc can pace playback precisely.
    func sendAudioAAC(_ aac: Data, pcmSampleCount: UInt32) {
        guard let s = session else { return }
        aac.withUnsafeBytes { raw in
            let ptr = raw.baseAddress?.assumingMemoryBound(to: UInt8.self)
            _ = macrdp_session_send_audio_aac(s, ptr, aac.count, pcmSampleCount)
        }
    }

    func sendClipFormatList(_ formats: [(id: UInt32, name: String?)]) {
        guard let s = session else { return }
        // FreeRDP copies the name bytes synchronously into its wire
        // buffer, so we just need the CString pointers valid for the
        // single C call below. strdup each name (small fixed strings)
        // and free immediately after.
        var cFormats = [macrdp_clip_format](repeating: .init(), count: formats.count)
        var allocated: [UnsafeMutablePointer<CChar>] = []
        defer { for p in allocated { free(p) } }
        for i in 0..<formats.count {
            cFormats[i].id = formats[i].id
            if let n = formats[i].name {
                let dup = strdup(n)
                allocated.append(dup!)
                cFormats[i].name = UnsafePointer(dup)
            } else {
                cFormats[i].name = nil
            }
        }
        cliprdrSendLock.lock()
        defer { cliprdrSendLock.unlock() }
        cFormats.withUnsafeBufferPointer { buf in
            _ = macrdp_session_send_clip_format_list(
                s, buf.baseAddress, Int32(cFormats.count))
        }
    }

    func sendClipDataResponse(formatID: UInt32, data: Data) {
        guard let s = session else { return }
        cliprdrSendLock.lock()
        defer { cliprdrSendLock.unlock() }
        if data.isEmpty {
            _ = macrdp_session_send_clip_data_response(s, formatID, nil, 0)
            return
        }
        data.withUnsafeBytes { raw in
            let ptr = raw.baseAddress?.assumingMemoryBound(to: UInt8.self)
            _ = macrdp_session_send_clip_data_response(s, formatID, ptr, data.count)
        }
    }

    func sendClipDataRequest(formatID: UInt32) {
        guard let s = session else { return }
        cliprdrSendLock.lock()
        defer { cliprdrSendLock.unlock() }
        _ = macrdp_session_send_clip_data_request(s, formatID)
    }

    /// Mac→Client: respond to a CB_FILECONTENTS_REQUEST with bytes (or
    /// an explicit FAIL if `success == false`).
    func sendClipFileContentsResponse(streamID: UInt32, success: Bool, data: Data) {
        guard let s = session else { return }
        cliprdrSendLock.lock()
        defer { cliprdrSendLock.unlock() }
        if data.isEmpty {
            _ = macrdp_session_send_clip_file_contents_response(
                s, streamID, success ? 1 : 0, nil, 0)
            return
        }
        data.withUnsafeBytes { raw in
            let ptr = raw.baseAddress?.assumingMemoryBound(to: UInt8.self)
            _ = macrdp_session_send_clip_file_contents_response(
                s, streamID, success ? 1 : 0, ptr, data.count)
        }
    }

    /// Win→Mac: ask the client for a chunk of a file. `clipDataID`
    /// is the lock-pinned snapshot id (0 / nil = no clipDataID — uses
    /// the client's current FGDW, which is unsafe when concurrent
    /// paste sessions are in flight).
    func sendClipFileContentsRequest(streamID: UInt32, listIndex: UInt32,
                                     wantSize: Bool, offset: UInt64, length: UInt32,
                                     clipDataID: UInt32? = nil) {
        guard let s = session else { return }
        cliprdrSendLock.lock()
        defer { cliprdrSendLock.unlock() }
        if let cid = clipDataID {
            _ = macrdp_session_send_clip_file_contents_request_with_clipdata(
                s, streamID, listIndex, wantSize ? 1 : 0, offset, length, 1, cid)
        } else {
            _ = macrdp_session_send_clip_file_contents_request(
                s, streamID, listIndex, wantSize ? 1 : 0, offset, length)
        }
    }

    /// Tell the client to preserve its current clipboard snapshot
    /// under `clipDataID` so future paste fetches for it succeed even
    /// after a new clipboard event replaces the active FGDW.
    func sendClipLock(clipDataID: UInt32) {
        guard let s = session else { return }
        cliprdrSendLock.lock()
        defer { cliprdrSendLock.unlock() }
        _ = macrdp_session_send_clip_lock(s, clipDataID)
    }

    /// Release the snapshot — client can free its preserved FGDW.
    func sendClipUnlock(clipDataID: UInt32) {
        guard let s = session else { return }
        cliprdrSendLock.lock()
        defer { cliprdrSendLock.unlock() }
        _ = macrdp_session_send_clip_unlock(s, clipDataID)
    }

    // MARK: - C trampolines

    private static func unmanagedSelf(_ ctx: UnsafeMutableRawPointer?) -> BridgePeer? {
        guard let ctx else { return nil }
        return Unmanaged<BridgePeer>.fromOpaque(ctx).takeUnretainedValue()
    }

    private static let cbActivated: macrdp_on_activated_fn = { ctx, w, h, bpp, ct, am in
        let mode = AudioMode(rawValue: am) ?? .doNotPlay
        unmanagedSelf(ctx)?.sinks.onActivated(Int(w), Int(h), Int(bpp), Int(ct), mode)
    }
    private static let cbClosed: macrdp_on_closed_fn = { ctx, reason in
        unmanagedSelf(ctx)?.sinks.onClosed(Int(reason))
    }
    private static let cbMouse: macrdp_on_input_mouse_fn = { ctx, flags, x, y in
        unmanagedSelf(ctx)?.sinks.onMouse(flags, Int(x), Int(y))
    }
    private static let cbKeyboard: macrdp_on_input_keyboard_fn = { ctx, flags, code in
        unmanagedSelf(ctx)?.sinks.onKeyboard(flags, code)
    }
    private static let cbUnicode: macrdp_on_input_unicode_fn = { ctx, flags, code in
        unmanagedSelf(ctx)?.sinks.onUnicode(flags, code)
    }
    private static let cbDispLayout: macrdp_on_disp_monitor_layout_fn = { ctx, mons, count in
        guard let mons else { return }
        var out: [MonitorLayout] = []
        out.reserveCapacity(Int(count))
        for i in 0..<Int(count) {
            let m = mons[i]
            out.append(MonitorLayout(
                rdpSlot: Int(m.rdp_slot),
                displayID: 0,
                x: Int(m.x), y: Int(m.y),
                width: Int(m.width), height: Int(m.height),
                refreshHz: Int(m.refresh_hz),
                orientation: Int(m.orientation),
                scale: Double(m.scale_x100) / 100.0,
                deviceScale: Double(m.device_scale_x100) / 100.0,
                physicalWidthMm: m.physical_width_mm == 0 ? nil : Int(m.physical_width_mm),
                physicalHeightMm: m.physical_height_mm == 0 ? nil : Int(m.physical_height_mm),
                primary: m.is_primary != 0))
        }
        unmanagedSelf(ctx)?.sinks.onDispLayout(out)
    }
    private static let cbFrameAck: macrdp_on_frame_acknowledge_fn = { ctx, fid in
        unmanagedSelf(ctx)?.sinks.onFrameAck(fid)
    }
    private static let cbClipFormatList: macrdp_on_clip_format_list_fn = { ctx, formats, count in
        var out: [(id: UInt32, name: String?)] = []
        out.reserveCapacity(Int(count))
        if let formats {
            for i in 0..<Int(count) {
                let entry = formats[i]
                let name: String? = entry.name.map { String(cString: $0) }
                out.append((id: entry.id, name: name))
            }
        }
        unmanagedSelf(ctx)?.sinks.onClipFormatList(out)
    }
    private static let cbClipDataRequest: macrdp_on_clip_data_request_fn = { ctx, fid in
        unmanagedSelf(ctx)?.sinks.onClipDataRequest(fid)
    }
    private static let cbClipDataResponse: macrdp_on_clip_data_response_fn = { ctx, fid, data, len in
        // len==0 with data==nil signals "client refused / no data" — pass
        // an empty Data so the waiter can unblock.
        let d: Data
        if let data, len > 0 {
            d = Data(bytes: data, count: len)
        } else {
            d = Data()
        }
        unmanagedSelf(ctx)?.sinks.onClipDataResponse(fid, d)
    }
    private static let cbClipReady: macrdp_on_clip_ready_fn = { ctx in
        unmanagedSelf(ctx)?.sinks.onClipReady()
    }
    private static let cbClipFormatListResponse: macrdp_on_clip_format_list_response_fn = { ctx, ok in
        unmanagedSelf(ctx)?.sinks.onClipFormatListResponse(ok != 0)
    }
    private static let cbClipFileContentsRequest: macrdp_on_clip_file_contents_request_fn = { ctx, sid, idx, wantSize, off, len in
        unmanagedSelf(ctx)?.sinks.onClipFileContentsRequest(sid, idx, wantSize != 0, off, len)
    }
    private static let cbClipFileContentsResponse: macrdp_on_clip_file_contents_response_fn = { ctx, sid, data, len in
        let d: Data
        if let data, len > 0 {
            d = Data(bytes: data, count: len)
        } else {
            d = Data()
        }
        unmanagedSelf(ctx)?.sinks.onClipFileContentsResponse(sid, d)
    }
    private static let cbAudioInFrame: macrdp_on_audio_in_frame_fn = { ctx, pcm, len, sr, ch in
        guard let pcm, len > 0 else { return }
        let d = Data(bytes: pcm, count: len)
        unmanagedSelf(ctx)?.sinks.onAudioInFrame(d, Int(sr), Int(ch))
    }
    private static let cbAudioFormatSelected: macrdp_on_audio_format_selected_fn = { ctx, fmt in
        let f = AudioFormat(rawValue: fmt) ?? .pcm
        unmanagedSelf(ctx)?.sinks.onAudioFormatSelected(f)
    }
    private static let cbSuppressOutput: macrdp_on_suppress_output_fn = { ctx, allow in
        unmanagedSelf(ctx)?.sinks.onSuppressOutput(allow != 0)
    }
    private static let cbRdpdrDeviceAdded: macrdp_on_rdpdr_device_added_fn = { ctx, id, type, dos in
        let name = dos.map { String(cString: $0) } ?? ""
        unmanagedSelf(ctx)?.sinks.onRdpdrDeviceAdded(id, type, name)
    }
    private static let cbRdpdrDeviceRemoved: macrdp_on_rdpdr_device_removed_fn = { ctx, id in
        unmanagedSelf(ctx)?.sinks.onRdpdrDeviceRemoved(id)
    }
}

#endif  // MACRDP_BRIDGE_AVAILABLE
