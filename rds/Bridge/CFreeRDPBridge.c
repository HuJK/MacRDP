/*
 *  CFreeRDPBridge.c
 *  MacRDP
 *
 *  FreeRDP server-side bridge. Owns one freerdp_peer per session,
 *  drives its event loop on a dedicated thread, and routes input +
 *  channel callbacks back to Swift.
 *
 *  Phase 1 (now): RDPGFX + AVC420 wired so the bridge can ship
 *  Annex-B H.264 frames (produced by VideoToolbox on the Swift side)
 *  to the client.
 */

#include "CFreeRDPBridge.h"

#include <errno.h>
#include <os/log.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static uint64_t now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000 + (uint64_t)ts.tv_nsec / 1000000;
}

#if __has_include(<freerdp/version.h>)
#  define MACRDP_HAVE_FREERDP 1
#  include <freerdp/version.h>
#  include <freerdp/freerdp.h>
#  include <freerdp/listener.h>
#  include <freerdp/peer.h>
#  include <freerdp/input.h>
#  include <freerdp/update.h>
#  include <freerdp/channels/channels.h>
#  include <freerdp/channels/wtsvc.h>
#  include <freerdp/channels/drdynvc.h>
#  include <freerdp/channels/rdpgfx.h>
#  include <freerdp/codec/color.h>
#  include <freerdp/codec/progressive.h>
#  include <freerdp/codec/region.h>
#  include <freerdp/server/rdpgfx.h>
#  include <freerdp/server/rdpsnd.h>
#  include <freerdp/server/audin.h>
#  include <freerdp/server/disp.h>
#  include <freerdp/server/cliprdr.h>
#  include <freerdp/channels/audin.h>
#  include <freerdp/channels/disp.h>
#  include <freerdp/channels/cliprdr.h>
#  include <freerdp/codec/audio.h>
#  include <freerdp/settings.h>
#  include <freerdp/crypto/certificate.h>
#  include <freerdp/crypto/privatekey.h>
#  include <winpr/synch.h>
#  include <winpr/thread.h>
#  include <winpr/handle.h>
#  include <winpr/wtsapi.h>
#endif

#define BRIDGE_VERSION "0.2.0"

static os_log_t bridge_log(void) {
    static os_log_t log = NULL;
    if (!log) log = os_log_create("com.macrdp.server", "bridge");
    return log;
}

/* -------- session struct ------------------------------------------ */

struct macrdp_session {
    int                    fd;
    void                  *swift_ctx;
    macrdp_callbacks       cbs;
    macrdp_session_config  cfg;
    atomic_int             stop_requested;
#if MACRDP_HAVE_FREERDP
    freerdp_peer          *peer;
    RdpgfxServerContext   *gfx;
    bool                   gfx_open_requested;
    bool                   gfx_caps_confirmed;
    bool                   surface_created;
    uint16_t               surface_id;
    uint32_t               next_frame_id;
    int32_t                desktop_width;
    int32_t                desktop_height;
    /* True once peer->Activate has fired. We delay calling
     * WTSVirtualChannelManagerCheckFileDescriptor with autoOpen=TRUE
     * until then — otherwise we send the DRDYNVC Caps Request before
     * the client is ready and the client never responds, leaving
     * DRDYNVC stuck at INITIALIZED. */
    atomic_bool            activated;
    /* Flow control: bound the number of in-flight frames so we don't
     * pile up encoded H.264 in FreeRDP's outbound queue when the
     * network or client decoder lags. Incremented on send_h264_frame,
     * decremented on RDPGFX_FRAME_ACKNOWLEDGE. */
    atomic_int             outstanding_frames;
    int                    max_outstanding_frames;
    /* Watchdog: if the client stops sending FRAME_ACKNOWLEDGE PDUs (a
     * known mstsc quirk on decoder hiccups), the credit gauge sticks at
     * max and we go black. Track the last-ack monotonic time and
     * force-flush after a timeout in the event loop. */
    _Atomic uint64_t       last_ack_ms;
    /* Diagnostics: per-session state-change tracker for DRDYNVC and
     * an iteration heartbeat counter. */
    int                    drdynvc_last_joined;
    int                    drdynvc_last_state;
    int                    heartbeat_seconds_since_log;
    /* RFX Progressive V2 encoder context (created lazily on first
     * progressive frame). NULL when codec is AVC420. */
    PROGRESSIVE_CONTEXT   *progressive;
    /* RDPSND server channel — system audio out → client speakers. */
    RdpsndServerContext   *rdpsnd;
    bool                   rdpsnd_open;
    atomic_bool            rdpsnd_activated;
    /* Monotonic ms timestamp captured when RDPSND becomes activated.
     * Each WAVE PDU's wTimestamp is (now - audio_start) mod 65536 — the
     * MS-RDPEA spec says clients SHOULD ignore it, but mstsc empirically
     * paces playback against it. Always sending 0 makes mstsc pile up a
     * multi-second jitter buffer. */
    _Atomic uint64_t       audio_start_ms;
    /* Format mstsc picked at RDPSND activation: PCM or AAC. Drives
     * which Swift encoder path runs; also the formatNo we pass to
     * SendSamples2 for the Wave2 PDU. */
    _Atomic int32_t        audio_selected_format;     /* MACRDP_AUDIO_FORMAT_* */
    _Atomic uint32_t       audio_selected_format_no;  /* index in client_formats */
    /* Sample-time monotonic counter for AAC's audioTimeStamp field
     * (UINT32 wraps at ~89000s @ 48kHz). */
    _Atomic uint32_t       audio_total_samples;
    /* MACRDP_AUDIO_MODE_* — resolved at Activate from client info PDU. */
    int32_t                audio_mode;
    /* AUDIN — client mic → server. */
    audin_server_context  *audin;
    bool                   audin_open;
    bool                   audin_negotiated;
    /* DISP — client requests desktop resize (fullscreen toggle, window
     * resize). */
    DispServerContext     *disp;
    bool                   disp_open;
    /* CLIPRDR — bidirectional clipboard sync (CB_FORMAT_LIST etc.). */
    CliprdrServerContext  *cliprdr;
    bool                   cliprdr_open;
    /* Set after the server↔client capability + monitor-ready handshake
     * completes; before that we must not send FormatList PDUs. */
    atomic_bool            cliprdr_ready;
    /* Track the format id of our most recent outbound FormatDataRequest.
     * FreeRDP's ctx->lastRequestedFormatId is only updated for inbound
     * requests (client→server), so we can't rely on it when matching the
     * response to our pending outbound request. */
    _Atomic uint32_t       cliprdr_outbound_request_id;
#endif
};

#if MACRDP_HAVE_FREERDP

typedef struct {
    rdpContext               context;   /* must be first */
    struct macrdp_session   *session;
    HANDLE                   vcm;
} BridgeContext;

static BOOL bridge_context_new(freerdp_peer *peer, rdpContext *ctx) {
    BridgeContext *b = (BridgeContext*)ctx;
    b->vcm = WTSOpenServerA((LPSTR)peer->context);
    if (!b->vcm || b->vcm == INVALID_HANDLE_VALUE) {
        os_log(bridge_log(), "WTSOpenServerA failed");
        return FALSE;
    }
    return TRUE;
}
static void bridge_context_free(freerdp_peer *peer, rdpContext *ctx) {
    (void)peer;
    BridgeContext *b = (BridgeContext*)ctx;
    if (b->vcm && b->vcm != INVALID_HANDLE_VALUE) {
        WTSCloseServer(b->vcm);
        b->vcm = NULL;
    }
}

static struct macrdp_session* session_from_peer(freerdp_peer *peer) {
    return ((BridgeContext*)peer->context)->session;
}

static HANDLE vcm_from_session(struct macrdp_session *s) {
    if (!s || !s->peer) return NULL;
    return ((BridgeContext*)s->peer->context)->vcm;
}

/* -------- GFX callbacks ------------------------------------------- */

static UINT gfx_caps_advertise(RdpgfxServerContext *ctx,
                               const RDPGFX_CAPS_ADVERTISE_PDU *capsAdv) {
    struct macrdp_session *s = (struct macrdp_session*)ctx->custom;
    if (s->gfx_caps_confirmed) {
        return CHANNEL_RC_OK;   /* idempotent — client may advertise twice */
    }

    /* Iterate from newest to oldest, pick the first one the client
     * offered. We send AVC420-only PDUs, but newer versions accept that
     * — they just also support more (which we don't use). Mirrors the
     * shadow server's algorithm. */
    static const uint32_t supported[] = {
        RDPGFX_CAPVERSION_107, RDPGFX_CAPVERSION_106, RDPGFX_CAPVERSION_106_ERR,
        RDPGFX_CAPVERSION_105, RDPGFX_CAPVERSION_104, RDPGFX_CAPVERSION_103,
        RDPGFX_CAPVERSION_102, RDPGFX_CAPVERSION_101, RDPGFX_CAPVERSION_10,
        RDPGFX_CAPVERSION_81,  RDPGFX_CAPVERSION_8,
    };
    const RDPGFX_CAPSET *chosen = NULL;
    for (size_t k = 0; k < sizeof(supported)/sizeof(supported[0]) && !chosen; ++k) {
        for (UINT16 i = 0; i < capsAdv->capsSetCount; ++i) {
            if (capsAdv->capsSets[i].version == supported[k]) {
                chosen = &capsAdv->capsSets[i];
                break;
            }
        }
    }
    if (!chosen) {
        os_log(bridge_log(),
               "GFX caps: client offered no version we recognise, refusing");
        return ERROR_INVALID_DATA;
    }

    RDPGFX_CAPSET reply = *chosen;
    /* Tell the client what subset of its offered flags we'll honour.
     *   - For 8.1, AVC420 is signalled by SETTING AVC420_ENABLED.
     *   - For 10.x+, AVC support is signalled by CLEARING AVC_DISABLED.
     *   - We don't do AVC444, so we leave AVC_DISABLED clear (we DO support AVC, just only 420).
     *   - Drop optional bits we don't implement (thin client, small cache, scaledmap_disable).
     */
    if (reply.version == RDPGFX_CAPVERSION_81) {
        reply.flags |= RDPGFX_CAPS_FLAG_AVC420_ENABLED;
    }
    reply.flags &= ~(UINT32)RDPGFX_CAPS_FLAG_AVC_DISABLED;
    reply.flags &= ~(UINT32)RDPGFX_CAPS_FLAG_AVC_THINCLIENT;
    reply.flags &= ~(UINT32)RDPGFX_CAPS_FLAG_THINCLIENT;
    reply.flags &= ~(UINT32)RDPGFX_CAPS_FLAG_SMALL_CACHE;

    RDPGFX_CAPS_CONFIRM_PDU confirm = { 0 };
    confirm.capsSet = &reply;
    UINT rc = ctx->CapsConfirm(ctx, &confirm);
    if (rc == CHANNEL_RC_OK) {
        s->gfx_caps_confirmed = true;
        os_log(bridge_log(),
               "GFX caps confirmed: version=0x%X flags=0x%X (client offered %u capset(s))",
               reply.version, reply.flags, capsAdv->capsSetCount);
    }
    return rc;
}

static UINT gfx_frame_ack(RdpgfxServerContext *ctx,
                          const RDPGFX_FRAME_ACKNOWLEDGE_PDU *ack) {
    struct macrdp_session *s = (struct macrdp_session*)ctx->custom;
    int prev = atomic_fetch_sub(&s->outstanding_frames, 1);
    if (prev <= 0) {
        atomic_store(&s->outstanding_frames, 0);
    }
    atomic_store(&s->last_ack_ms, now_ms());
    if (s->cbs.on_frame_acknowledge) {
        s->cbs.on_frame_acknowledge(s->swift_ctx, ack->frameId);
    }
    return CHANNEL_RC_OK;
}

/* -------- DISP (client-driven desktop resize / fullscreen) -------- */

static UINT disp_monitor_layout_cb(DispServerContext *ctx,
                                   const DISPLAY_CONTROL_MONITOR_LAYOUT_PDU *pdu) {
    struct macrdp_session *s = (struct macrdp_session*)ctx->custom;
    if (!s || !pdu || pdu->NumMonitors == 0) return CHANNEL_RC_OK;

    /* Build the raw layout we hand to Swift. Phase 1 captures a single
     * monitor; we forward all entries so Swift's DisplayMapping can pick
     * the primary or do its own per-slot routing. */
    macrdp_raw_monitor *raws = (macrdp_raw_monitor *)
        calloc(pdu->NumMonitors, sizeof(macrdp_raw_monitor));
    if (!raws) return CHANNEL_RC_NO_MEMORY;

    for (UINT32 i = 0; i < pdu->NumMonitors; ++i) {
        const DISPLAY_CONTROL_MONITOR_LAYOUT *m = &pdu->Monitors[i];
        raws[i].rdp_slot          = (int32_t)i;
        raws[i].x                 = m->Left;
        raws[i].y                 = m->Top;
        raws[i].width             = (int32_t)m->Width;
        raws[i].height            = (int32_t)m->Height;
        raws[i].refresh_hz        = 0;     /* DISP doesn't carry refresh */
        raws[i].orientation       = (int32_t)m->Orientation;
        raws[i].scale_x100        = (int32_t)m->DesktopScaleFactor;
        raws[i].device_scale_x100 = (int32_t)m->DeviceScaleFactor;
        raws[i].physical_width_mm  = (int32_t)m->PhysicalWidth;
        raws[i].physical_height_mm = (int32_t)m->PhysicalHeight;
        raws[i].is_primary        = (m->Flags & DISPLAY_CONTROL_MONITOR_PRIMARY) ? 1 : 0;
    }

    os_log(bridge_log(),
           "DISP: client requested %u monitor(s), primary %ux%u",
           (unsigned)pdu->NumMonitors,
           (unsigned)pdu->Monitors[0].Width,
           (unsigned)pdu->Monitors[0].Height);

    if (s->cbs.on_disp_monitor_layout) {
        s->cbs.on_disp_monitor_layout(s->swift_ctx, raws,
                                       (int32_t)pdu->NumMonitors);
    }
    free(raws);
    return CHANNEL_RC_OK;
}

static void try_open_disp(struct macrdp_session *s) {
    if (s->disp_open) return;
    if (!atomic_load(&s->activated)) return;
    HANDLE vcm = vcm_from_session(s);
    if (!vcm) return;
    /* DISP rides DRDYNVC. */
    if (!WTSVirtualChannelManagerIsChannelJoined(vcm, DRDYNVC_SVC_CHANNEL_NAME))
        return;
    if (WTSVirtualChannelManagerGetDrdynvcState(vcm) != DRDYNVC_STATE_READY)
        return;

    DispServerContext *ctx = disp_server_context_new(vcm);
    if (!ctx) {
        os_log(bridge_log(), "disp_server_context_new failed");
        return;
    }
    ctx->custom            = s;
    ctx->rdpcontext        = s->peer->context;
    ctx->MaxNumMonitors    = 1;       /* Phase 1: single-monitor */
    ctx->MaxMonitorAreaFactorA = 8192;
    ctx->MaxMonitorAreaFactorB = 8192;
    ctx->DispMonitorLayout = disp_monitor_layout_cb;

    UINT rc = ctx->Open(ctx);
    if (rc != CHANNEL_RC_OK) {
        os_log(bridge_log(), "disp Open failed: %u", rc);
        disp_server_context_free(ctx);
        return;
    }
    s->disp = ctx;
    s->disp_open = true;
    os_log(bridge_log(), "DISP channel opened (resize support)");
}

/* -------- AUDIN (client mic -> server) ---------------------------- */

static UINT audin_receive_data_cb(audin_server_context *ctx,
                                  const SNDIN_DATA *data) {
    struct macrdp_session *s = (struct macrdp_session*)ctx->userdata;
    if (!s || !data || !data->Data) return CHANNEL_RC_OK;
    size_t len = Stream_GetPosition(data->Data);
    if (len == 0) {
        len = Stream_Length(data->Data);
        if (len == 0) return CHANNEL_RC_OK;
    }
    const BYTE *bytes = Stream_Buffer(data->Data);
    const AUDIO_FORMAT *fmt = audin_server_get_negotiated_format(ctx);
    int32_t sr = fmt ? (int32_t)fmt->nSamplesPerSec : 48000;
    int32_t ch = fmt ? (int32_t)fmt->nChannels      : 2;
    if (s->cbs.on_audio_in_frame) {
        s->cbs.on_audio_in_frame(s->swift_ctx, bytes, len, sr, ch);
    }
    return CHANNEL_RC_OK;
}

static void try_open_audin(struct macrdp_session *s) {
    if (s->audin_open || !s->cfg.enable_audio_in) return;
    if (!atomic_load(&s->activated)) return;
    HANDLE vcm = vcm_from_session(s);
    if (!vcm) return;
    /* AUDIN runs over DRDYNVC — wait for it to be READY. */
    if (!WTSVirtualChannelManagerIsChannelJoined(vcm, DRDYNVC_SVC_CHANNEL_NAME))
        return;
    if (WTSVirtualChannelManagerGetDrdynvcState(vcm) != DRDYNVC_STATE_READY)
        return;

    audin_server_context *ctx = audin_server_context_new(vcm);
    if (!ctx) {
        os_log(bridge_log(), "audin_server_context_new failed");
        return;
    }
    ctx->userdata    = s;
    ctx->rdpcontext  = s->peer->context;
    ctx->Data        = audin_receive_data_cb;
    ctx->serverVersion = SNDIN_VERSION_Version_2;

    /* Advertise PCM 48k stereo (universal). Pass count=-1 to also include
     * FreeRDP's default format list — gives older clients a fallback. */
    AUDIO_FORMAT preferred = { 0 };
    preferred.wFormatTag      = WAVE_FORMAT_PCM;
    preferred.nChannels       = 2;
    preferred.nSamplesPerSec  = 48000;
    preferred.wBitsPerSample  = 16;
    preferred.nBlockAlign     = 4;
    preferred.nAvgBytesPerSec = 48000 * 4;
    if (!audin_server_set_formats(ctx, 1, &preferred)) {
        os_log(bridge_log(), "audin_server_set_formats failed");
        audin_server_context_free(ctx);
        return;
    }

    if (!ctx->Open(ctx)) {
        os_log(bridge_log(), "audin Open failed");
        audin_server_context_free(ctx);
        return;
    }
    s->audin = ctx;
    s->audin_open = true;
    os_log(bridge_log(), "AUDIN channel opened (client mic -> server)");
}

/* -------- RDPSND --------------------------------------------------- */

/* Match a client format against any of our server formats. Returns
 * the client_formats index or -1. */
static int rdpsnd_match_format(RdpsndServerContext *ctx, UINT16 wantTag) {
    for (UINT16 i = 0; i < ctx->num_client_formats; ++i) {
        const AUDIO_FORMAT *cf = &ctx->client_formats[i];
        if (cf->wFormatTag != wantTag) continue;
        for (UINT16 j = 0; j < ctx->num_server_formats; ++j) {
            const AUDIO_FORMAT *sf = &ctx->server_formats[j];
            if (cf->wFormatTag == sf->wFormatTag &&
                cf->nChannels == sf->nChannels &&
                cf->nSamplesPerSec == sf->nSamplesPerSec &&
                cf->wBitsPerSample == sf->wBitsPerSample) {
                return (int)i;
            }
        }
    }
    return -1;
}

static void rdpsnd_activated_cb(RdpsndServerContext *ctx) {
    struct macrdp_session *s = (struct macrdp_session*)ctx->data;
    if (!s) return;
    /* The callback fires when we receive the client's format list.
     * We MUST call SelectFormat to pick one and tell the client; only
     * after that does the channel become activated for SendSamples. */

    /* Prefer AAC over PCM — mstsc's AAC jitter buffer is ~50-100ms vs
     * PCM's ~300-500ms (and unbounded growth under clock skew). */
    int pickedIdx = rdpsnd_match_format(ctx, WAVE_FORMAT_AAC_MS);
    int32_t fmtType = MACRDP_AUDIO_FORMAT_AAC;
    if (pickedIdx < 0) {
        pickedIdx = rdpsnd_match_format(ctx, WAVE_FORMAT_PCM);
        fmtType = MACRDP_AUDIO_FORMAT_PCM;
    }
    if (pickedIdx < 0) {
        os_log(bridge_log(),
               "RDPSND: no compatible client/server format match (%u client formats offered)",
               (unsigned)ctx->num_client_formats);
        return;
    }
    UINT rc = ctx->SelectFormat(ctx, (UINT16)pickedIdx);
    if (rc != CHANNEL_RC_OK) {
        os_log(bridge_log(), "RDPSND SelectFormat failed: %u", rc);
        return;
    }
    atomic_store(&s->audio_start_ms, now_ms());
    atomic_store(&s->audio_total_samples, 0);
    atomic_store(&s->audio_selected_format, fmtType);
    atomic_store(&s->audio_selected_format_no, (uint32_t)pickedIdx);
    atomic_store(&s->rdpsnd_activated, true);
    const AUDIO_FORMAT *fmt = &ctx->client_formats[pickedIdx];
    os_log(bridge_log(),
           "RDPSND activated: picked client fmt[%d] tag=0x%X %uHz %uch %ubits (%s)",
           pickedIdx,
           (unsigned)fmt->wFormatTag, (unsigned)fmt->nSamplesPerSec,
           (unsigned)fmt->nChannels, (unsigned)fmt->wBitsPerSample,
           fmtType == MACRDP_AUDIO_FORMAT_AAC ? "AAC" : "PCM");
    /* Tell Swift which encoder to engage. */
    if (s->cbs.on_audio_format_selected) {
        s->cbs.on_audio_format_selected(s->swift_ctx, fmtType);
    }
}

static void try_open_rdpsnd(struct macrdp_session *s) {
    if (s->rdpsnd_open || !s->cfg.enable_audio_out) return;
    if (!atomic_load(&s->activated)) return;
    if (s->audio_mode != MACRDP_AUDIO_MODE_REDIRECTED) return;
    HANDLE vcm = vcm_from_session(s);
    if (!vcm) return;

    RdpsndServerContext *ctx = rdpsnd_server_context_new(vcm);
    if (!ctx) {
        os_log(bridge_log(), "rdpsnd_server_context_new failed");
        return;
    }

    /* Advertise AAC-MS first, PCM second. The client picks one in its
     * own preferred order (mstsc on Windows 10+ picks AAC-MS gladly).
     * Heap-allocated: rdpsnd_server_context_free() frees both the
     * array and any per-entry .data pointers. */
    AUDIO_FORMAT *fmts = (AUDIO_FORMAT *)calloc(2, sizeof(AUDIO_FORMAT));
    if (!fmts) {
        rdpsnd_server_context_free(ctx);
        return;
    }
    /* AAC-LC 48k stereo @ 128 kbps. mstsc needs the HEAACWAVEINFO
     * extension data to know how to decode our raw AAC frames — without
     * it, it falls back to treating packets as opaque blobs and buffers
     * them forever. The cbSize=14 payload is:
     *   wPayloadType (UINT16 LE) = 0   (Raw — no ADTS framing)
     *   wAudioProfileLevelIndication (UINT16 LE) = 0x29 (AAC-LC L2)
     *   wStructType                  (UINT16 LE) = 0
     *   wReserved1                   (UINT16 LE) = 0
     *   dwReserved2                  (UINT32 LE) = 0
     *   AudioSpecificConfig (2 bytes) = 0x11 0x90
     *     = AOT=2 (LC), samplingFreqIndex=3 (48k), channelConfig=2 (stereo)
     */
    static const size_t kAacExtraLen = 14;
    BYTE *aacExtra = (BYTE *)calloc(1, kAacExtraLen);
    if (!aacExtra) {
        free(fmts);
        rdpsnd_server_context_free(ctx);
        return;
    }
    /* wPayloadType = 0 (Raw); already zero from calloc */
    aacExtra[2] = 0x29;          /* wAudioProfileLevelIndication low byte */
    /* wStructType / wReserved1 / dwReserved2 already zero */
    aacExtra[12] = 0x11;         /* AudioSpecificConfig byte 0 */
    aacExtra[13] = 0x90;         /* AudioSpecificConfig byte 1 */

    fmts[0].wFormatTag      = WAVE_FORMAT_AAC_MS;
    fmts[0].nChannels       = 2;
    fmts[0].nSamplesPerSec  = 48000;
    fmts[0].wBitsPerSample  = 16;
    fmts[0].nBlockAlign     = 4;
    fmts[0].nAvgBytesPerSec = 16000;     /* 128 kbps */
    fmts[0].cbSize          = (UINT16)kAacExtraLen;
    fmts[0].data            = aacExtra;
    /* PCM 16-bit 48 kHz stereo — fallback for older clients. */
    fmts[1].wFormatTag      = WAVE_FORMAT_PCM;
    fmts[1].nChannels       = 2;
    fmts[1].nSamplesPerSec  = 48000;
    fmts[1].wBitsPerSample  = 16;
    fmts[1].nBlockAlign     = 4;
    fmts[1].nAvgBytesPerSec = 48000 * 4;
    fmts[1].cbSize          = 0;
    fmts[1].data            = NULL;

    ctx->server_formats     = fmts;
    ctx->num_server_formats = 2;
    /* src_format describes the format we'll DELIVER samples in (always
     * PCM at the SendSamples API; AAC is sent via SendSamples2). Keeping
     * src_format pointing at PCM is correct. */
    ctx->src_format         = &fmts[1];
    /* Latency hint to FreeRDP's WAVE PDU pacer. Smaller = less server
     * buffering. Most of the user-observed audio lag is in mstsc's
     * PCM jitter buffer (~300-500ms) which is out of our control; an
     * AAC / Opus codec path would cut that to ~50-100ms. */
    ctx->latency            = 20;
    ctx->data               = s;
    ctx->Activated          = rdpsnd_activated_cb;
    /* Use the *static* virtual channel (always available post-activation).
     * DVC would be lower-overhead but requires DRDYNVC == READY, which is
     * not guaranteed by the time we want to start audio. */
    ctx->use_dynamic_virtual_channel = FALSE;

    UINT rc = ctx->Initialize(ctx, TRUE /* ownThread */);
    if (rc != CHANNEL_RC_OK) {
        os_log(bridge_log(), "rdpsnd Initialize failed: %u", rc);
        rdpsnd_server_context_free(ctx);
        return;
    }
    s->rdpsnd = ctx;
    s->rdpsnd_open = true;
    os_log(bridge_log(), "RDPSND channel opened (static VC)");
}

/* -------- CLIPRDR (bidirectional clipboard) ----------------------- */

/* The minimum capability set the server publishes. We mirror what the
 * client advertises in flags except CB_HUGE_FILE_SUPPORT_ENABLED, which
 * we'll flip once Phase 7 ships file transfer. */
static UINT cliprdr_send_server_caps(CliprdrServerContext *ctx) {
    CLIPRDR_GENERAL_CAPABILITY_SET general = { 0 };
    general.capabilitySetType  = CB_CAPSTYPE_GENERAL;
    general.capabilitySetLength = CB_CAPSTYPE_GENERAL_LEN;
    general.version            = CB_CAPS_VERSION_2;
    general.generalFlags       = CB_USE_LONG_FORMAT_NAMES;
    if (ctx->streamFileClipEnabled) general.generalFlags |= CB_STREAM_FILECLIP_ENABLED;
    if (ctx->fileClipNoFilePaths)   general.generalFlags |= CB_FILECLIP_NO_FILE_PATHS;
    if (ctx->canLockClipData)       general.generalFlags |= CB_CAN_LOCK_CLIPDATA;
    if (ctx->hasHugeFileSupport)    general.generalFlags |= CB_HUGE_FILE_SUPPORT_ENABLED;

    CLIPRDR_CAPABILITIES caps = { 0 };
    caps.cCapabilitiesSets = 1;
    caps.capabilitySets    = (CLIPRDR_CAPABILITY_SET *)&general;
    return ctx->ServerCapabilities(ctx, &caps);
}

static UINT cliprdr_client_caps_cb(CliprdrServerContext *ctx,
                                   const CLIPRDR_CAPABILITIES *caps) {
    (void)ctx; (void)caps;
    /* The channel layer updates ctx->useLongFormatNames /
     * streamFileClipEnabled / etc. from the client's capset before
     * calling us. Nothing to do here beyond accepting. */
    return CHANNEL_RC_OK;
}

static UINT cliprdr_temp_directory_cb(CliprdrServerContext *ctx,
                                      const CLIPRDR_TEMP_DIRECTORY *td) {
    (void)ctx; (void)td;
    return CHANNEL_RC_OK;
}

/* Phase 6: client→server format list (the client copied something). We
 * surface the format ids to Swift, which then decides whether to claim
 * the Mac NSPasteboard and lazy-fetch bytes on demand. */
static UINT cliprdr_client_format_list_cb(CliprdrServerContext *ctx,
                                          const CLIPRDR_FORMAT_LIST *list) {
    struct macrdp_session *s = (struct macrdp_session *)ctx->custom;
    /* Always respond OK first so the client doesn't time out. */
    CLIPRDR_FORMAT_LIST_RESPONSE resp = { 0 };
    resp.common.msgType  = CB_FORMAT_LIST_RESPONSE;
    resp.common.msgFlags = CB_RESPONSE_OK;
    (void)ctx->ServerFormatListResponse(ctx, &resp);

    if (!s || !s->cbs.on_clip_format_list) return CHANNEL_RC_OK;

    UINT32 n = list->numFormats;
    if (n == 0) {
        s->cbs.on_clip_format_list(s->swift_ctx, NULL, 0);
        return CHANNEL_RC_OK;
    }
    macrdp_clip_format *out = (macrdp_clip_format *)
        calloc(n, sizeof(macrdp_clip_format));
    if (!out) return CHANNEL_RC_NO_MEMORY;
    for (UINT32 i = 0; i < n; ++i) {
        out[i].id   = list->formats[i].formatId;
        out[i].name = list->formats[i].formatName;   /* may be NULL */
    }
    s->cbs.on_clip_format_list(s->swift_ctx, out, (int32_t)n);
    free(out);
    return CHANNEL_RC_OK;
}

/* Client→server: request a chunk of a file's bytes (or its size). We
 * forward to Swift, which opens the file and replies via
 * macrdp_session_send_clip_file_contents_response. */
static UINT cliprdr_client_file_contents_request_cb(
    CliprdrServerContext *ctx,
    const CLIPRDR_FILE_CONTENTS_REQUEST *req) {
    struct macrdp_session *s = (struct macrdp_session *)ctx->custom;
    if (!s || !s->cbs.on_clip_file_contents_request) {
        CLIPRDR_FILE_CONTENTS_RESPONSE resp = { 0 };
        resp.common.msgType  = CB_FILECONTENTS_RESPONSE;
        resp.common.msgFlags = CB_RESPONSE_FAIL;
        resp.streamId        = req->streamId;
        (void)ctx->ServerFileContentsResponse(ctx, &resp);
        return CHANNEL_RC_OK;
    }
    int32_t want_size = (req->dwFlags & FILECONTENTS_SIZE) ? 1 : 0;
    uint64_t offset = ((uint64_t)req->nPositionHigh << 32) | req->nPositionLow;
    s->cbs.on_clip_file_contents_request(s->swift_ctx,
                                          req->streamId,
                                          req->listIndex,
                                          want_size,
                                          offset,
                                          req->cbRequested);
    return CHANNEL_RC_OK;
}

/* Client→server: the bytes we previously asked the client for via
 * ServerFileContentsRequest. */
static UINT cliprdr_client_file_contents_response_cb(
    CliprdrServerContext *ctx,
    const CLIPRDR_FILE_CONTENTS_RESPONSE *resp) {
    struct macrdp_session *s = (struct macrdp_session *)ctx->custom;
    if (!s || !s->cbs.on_clip_file_contents_response) return CHANNEL_RC_OK;
    const BYTE *bytes = NULL;
    size_t len = 0;
    if (resp->common.msgFlags & CB_RESPONSE_OK) {
        bytes = resp->requestedData;
        len   = resp->cbRequested;
    }
    s->cbs.on_clip_file_contents_response(s->swift_ctx, resp->streamId, bytes, len);
    return CHANNEL_RC_OK;
}

/* Client's response to the server's prior FormatList. mstsc sends
 * CB_RESPONSE_FAIL when its OpenClipboard() loses to Office or similar
 * background pollers; we hand the result up so Swift can schedule a
 * retry. */
static UINT cliprdr_client_format_list_response_cb(
    CliprdrServerContext *ctx,
    const CLIPRDR_FORMAT_LIST_RESPONSE *resp) {
    struct macrdp_session *s = (struct macrdp_session *)ctx->custom;
    int32_t ok = (resp->common.msgFlags & CB_RESPONSE_OK) ? 1 : 0;
    if (s && s->cbs.on_clip_format_list_response) {
        s->cbs.on_clip_format_list_response(s->swift_ctx, ok);
    }
    if (!ok) {
        os_log(bridge_log(),
               "CLIPRDR FormatList rejected by client (msgFlags=0x%X)",
               (unsigned)resp->common.msgFlags);
    }
    return CHANNEL_RC_OK;
}

/* The client (mstsc) is asking the server for the bytes of one format
 * we previously advertised — forward to Swift, which reads NSPasteboard
 * and calls send_clip_data_response back. */
static UINT cliprdr_client_format_data_request_cb(
    CliprdrServerContext *ctx,
    const CLIPRDR_FORMAT_DATA_REQUEST *req) {
    struct macrdp_session *s = (struct macrdp_session *)ctx->custom;
    if (!s || !s->cbs.on_clip_data_request) {
        /* Send an explicit failure so the client doesn't hang. */
        CLIPRDR_FORMAT_DATA_RESPONSE empty = { 0 };
        empty.common.msgType  = CB_FORMAT_DATA_RESPONSE;
        empty.common.msgFlags = CB_RESPONSE_FAIL;
        (void)ctx->ServerFormatDataResponse(ctx, &empty);
        return CHANNEL_RC_OK;
    }
    s->cbs.on_clip_data_request(s->swift_ctx, req->requestedFormatId);
    return CHANNEL_RC_OK;
}

/* The client (mstsc) is delivering bytes for a format we previously
 * requested (because a Mac app pasted while the RDP clipboard owned
 * the Mac side). */
static UINT cliprdr_client_format_data_response_cb(
    CliprdrServerContext *ctx,
    const CLIPRDR_FORMAT_DATA_RESPONSE *resp) {
    struct macrdp_session *s = (struct macrdp_session *)ctx->custom;
    if (!s || !s->cbs.on_clip_data_response) return CHANNEL_RC_OK;

    /* Use our own tracked outbound id — FreeRDP's lastRequestedFormatId
     * is only updated for inbound requests, not outbound ones. */
    UINT32 fid = atomic_load(&s->cliprdr_outbound_request_id);
    const BYTE *bytes = NULL;
    size_t len = 0;
    if (resp->common.msgFlags & CB_RESPONSE_OK) {
        bytes = resp->requestedFormatData;
        len   = resp->common.dataLen;
    }
    s->cbs.on_clip_data_response(s->swift_ctx, fid, bytes, len);
    return CHANNEL_RC_OK;
}

static void try_open_cliprdr(struct macrdp_session *s) {
    if (s->cliprdr_open || !s->cfg.enable_clipboard) return;
    if (!atomic_load(&s->activated)) return;
    HANDLE vcm = vcm_from_session(s);
    if (!vcm) return;
    /* CLIPRDR is a static virtual channel — available once the client
     * joins it during the GCC conf phase. The client always joins it
     * if we advertise support (RedirectClipboard=TRUE). */
    if (!WTSVirtualChannelManagerIsChannelJoined(vcm, CLIPRDR_SVC_CHANNEL_NAME))
        return;

    CliprdrServerContext *ctx = cliprdr_server_context_new(vcm);
    if (!ctx) {
        os_log(bridge_log(), "cliprdr_server_context_new failed");
        return;
    }
    ctx->rdpcontext             = s->peer->context;
    ctx->custom                 = s;
    ctx->useLongFormatNames     = TRUE;
    ctx->streamFileClipEnabled  = TRUE;     /* Phase 7: enable file payloads */
    ctx->fileClipNoFilePaths    = TRUE;     /* paths aren't shared, only contents */
    ctx->canLockClipData        = FALSE;
    ctx->hasHugeFileSupport     = TRUE;     /* 64-bit FILECONTENTS_REQUEST offsets */
    ctx->autoInitializationSequence = TRUE;  /* sends caps + monitor-ready
                                                 automatically on Start */

    ctx->ClientCapabilities          = cliprdr_client_caps_cb;
    ctx->TempDirectory               = cliprdr_temp_directory_cb;
    ctx->ClientFormatList            = cliprdr_client_format_list_cb;
    ctx->ClientFormatListResponse    = cliprdr_client_format_list_response_cb;
    ctx->ClientFormatDataRequest     = cliprdr_client_format_data_request_cb;
    ctx->ClientFormatDataResponse    = cliprdr_client_format_data_response_cb;
    ctx->ClientFileContentsRequest   = cliprdr_client_file_contents_request_cb;
    ctx->ClientFileContentsResponse  = cliprdr_client_file_contents_response_cb;

    UINT rc = ctx->Open(ctx);
    if (rc != CHANNEL_RC_OK) {
        os_log(bridge_log(), "cliprdr Open failed: %u", rc);
        cliprdr_server_context_free(ctx);
        return;
    }
    /* Start() spins up the channel thread and (with autoInitializationSequence
     * = TRUE) walks Caps → MonitorReady. */
    rc = ctx->Start(ctx);
    if (rc != CHANNEL_RC_OK) {
        os_log(bridge_log(), "cliprdr Start failed: %u", rc);
        (void)ctx->Close(ctx);
        cliprdr_server_context_free(ctx);
        return;
    }
    /* Send our capability set explicitly. autoInitializationSequence
     * already does this, but we want to control the flag bits. */
    (void)cliprdr_send_server_caps(ctx);

    s->cliprdr = ctx;
    s->cliprdr_open = true;
    atomic_store(&s->cliprdr_ready, true);
    if (s->cbs.on_clip_ready) {
        s->cbs.on_clip_ready(s->swift_ctx);
    }
    os_log(bridge_log(), "CLIPRDR channel opened (static VC)");
}

/* Attempt to open the GFX channel once DRDYNVC reports READY. */
static void try_open_gfx(struct macrdp_session *s) {
    if (!s->peer || s->gfx_open_requested) return;
    HANDLE vcm = vcm_from_session(s);
    if (!vcm) return;
    int joined = (int)WTSVirtualChannelManagerIsChannelJoined(vcm, DRDYNVC_SVC_CHANNEL_NAME);
    int state  = (int)WTSVirtualChannelManagerGetDrdynvcState(vcm);

    /* Log per-session transitions (not per-process). */
    if (joined != s->drdynvc_last_joined || state != s->drdynvc_last_state) {
        os_log(bridge_log(), "DRDYNVC: joined=%d state=%d", joined, state);
        s->drdynvc_last_joined = joined;
        s->drdynvc_last_state = state;
    }

    if (!joined) return;
    if (state != DRDYNVC_STATE_READY) return;

    s->gfx = rdpgfx_server_context_new(vcm);
    if (!s->gfx) {
        os_log(bridge_log(), "rdpgfx_server_context_new failed");
        return;
    }
    s->gfx->rdpcontext = s->peer->context;
    s->gfx->custom = s;
    s->gfx->CapsAdvertise = gfx_caps_advertise;
    s->gfx->FrameAcknowledge = gfx_frame_ack;
    /* Don't spawn a separate GFX server thread — saves a thread-hop per
     * frame. FreeRDP will send synchronously from whatever thread calls
     * SurfaceFrameCommand (our SCK / VT pipeline thread).
     *
     * externalThread=TRUE → we own polling. We must call
     * rdpgfx_server_handle_messages periodically; in practice, we read
     * the GFX event handle in the peer event loop alongside the VCM. */
    (void)s->gfx->Initialize(s->gfx, TRUE);
    if (!s->gfx->Open(s->gfx)) {
        os_log(bridge_log(), "GFX Open failed");
        rdpgfx_server_context_free(s->gfx);
        s->gfx = NULL;
        return;
    }
    s->gfx_open_requested = true;
    os_log(bridge_log(), "GFX channel opened");
}

/* -------- peer lifecycle callbacks -------------------------------- */

static BOOL bridge_peer_capabilities(freerdp_peer *peer) {
    (void)peer;
    return TRUE;
}

static BOOL bridge_peer_post_connect(freerdp_peer *peer) {
    rdpSettings *s = peer->context->settings;
    os_log(bridge_log(),
           "peer post_connect: %s @ %ux%u/%ubpp gfx=%d",
           freerdp_settings_get_string(s, FreeRDP_ClientHostname),
           freerdp_settings_get_uint32(s, FreeRDP_DesktopWidth),
           freerdp_settings_get_uint32(s, FreeRDP_DesktopHeight),
           freerdp_settings_get_uint32(s, FreeRDP_ColorDepth),
           (int)freerdp_settings_get_bool(s, FreeRDP_SupportGraphicsPipeline));
    return TRUE;
}

static BOOL bridge_peer_activate(freerdp_peer *peer) {
    struct macrdp_session *s = session_from_peer(peer);
    rdpSettings *settings = peer->context->settings;
    s->desktop_width  = (int32_t)freerdp_settings_get_uint32(settings, FreeRDP_DesktopWidth);
    s->desktop_height = (int32_t)freerdp_settings_get_uint32(settings, FreeRDP_DesktopHeight);

    /* Resolve the three-way audio redirection mode the client requested.
     * MS-RDPBCGR Client Info PDU INFO_REMOTECONSOLEAUDIO bit → "Play on
     * remote computer". AudioPlayback=false → "Do not play". Otherwise
     * "Play on this computer". */
    BOOL audioPlayback        = freerdp_settings_get_bool(settings, FreeRDP_AudioPlayback);
    BOOL remoteConsoleAudio   = freerdp_settings_get_bool(settings, FreeRDP_RemoteConsoleAudio);
    int32_t audio_mode;
    if (!audioPlayback) {
        audio_mode = MACRDP_AUDIO_MODE_NONE;
    } else if (remoteConsoleAudio) {
        audio_mode = MACRDP_AUDIO_MODE_REMOTE;
    } else {
        audio_mode = MACRDP_AUDIO_MODE_REDIRECTED;
    }
    s->audio_mode = audio_mode;
    os_log(bridge_log(),
           "Audio mode: %s (playback=%d remoteConsole=%d)",
           audio_mode == MACRDP_AUDIO_MODE_NONE       ? "do-not-play" :
           audio_mode == MACRDP_AUDIO_MODE_REMOTE     ? "play-on-remote" :
           "play-on-this-computer",
           (int)audioPlayback, (int)remoteConsoleAudio);

    atomic_store(&s->activated, true);
    if (s->cbs.on_activated) {
        s->cbs.on_activated(
            s->swift_ctx,
            s->desktop_width,
            s->desktop_height,
            (int32_t)freerdp_settings_get_uint32(settings, FreeRDP_ColorDepth),
            (int32_t)freerdp_settings_get_uint32(settings, FreeRDP_ConnectionType),
            audio_mode);
    }
    return TRUE;
}

/* -------- input trampolines --------------------------------------- */

static BOOL bridge_in_sync(rdpInput *input, UINT32 flags) { (void)input; (void)flags; return TRUE; }
static BOOL bridge_in_keyboard(rdpInput *input, UINT16 flags, UINT8 code) {
    struct macrdp_session *s = ((BridgeContext*)input->context)->session;
    if (s->cbs.on_input_keyboard)
        s->cbs.on_input_keyboard(s->swift_ctx, flags, (UINT16)code);
    return TRUE;
}
static BOOL bridge_in_unicode(rdpInput *input, UINT16 flags, UINT16 code) {
    struct macrdp_session *s = ((BridgeContext*)input->context)->session;
    if (s->cbs.on_input_unicode)
        s->cbs.on_input_unicode(s->swift_ctx, flags, code);
    return TRUE;
}
static BOOL bridge_in_mouse(rdpInput *input, UINT16 flags, UINT16 x, UINT16 y) {
    struct macrdp_session *s = ((BridgeContext*)input->context)->session;
    if (s->cbs.on_input_mouse)
        s->cbs.on_input_mouse(s->swift_ctx, flags, (int32_t)x, (int32_t)y);
    return TRUE;
}
static BOOL bridge_in_xmouse(rdpInput *input, UINT16 flags, UINT16 x, UINT16 y) {
    struct macrdp_session *s = ((BridgeContext*)input->context)->session;
    if (s->cbs.on_input_mouse)
        s->cbs.on_input_mouse(s->swift_ctx, flags, (int32_t)x, (int32_t)y);
    return TRUE;
}

/* Client minimized / restored. allow=0 → pause graphics; allow=1 → resume. */
static BOOL bridge_suppress_output(rdpContext *ctx, BYTE allow,
                                   const RECTANGLE_16 *area) {
    (void)area;
    struct macrdp_session *s = ((BridgeContext*)ctx)->session;
    if (!s) return TRUE;
    /* Clear any in-flight frame credit — when the client suppresses
     * output, frames already on the wire effectively get dropped on
     * its side and no FrameAck will ever come back. Without this, the
     * outstanding counter would stick at max forever after the user
     * minimizes/maximizes the client window. */
    int flushed = atomic_exchange(&s->outstanding_frames, 0);
    atomic_store(&s->last_ack_ms, now_ms());
    if (flushed > 0) {
        os_log(bridge_log(),
               "SuppressOutput(allow=%d): flushed %d unacked frames",
               (int)allow, flushed);
    }
    if (s->cbs.on_suppress_output) {
        s->cbs.on_suppress_output(s->swift_ctx, (int32_t)allow);
    }
    return TRUE;
}

/* -------- settings setup ------------------------------------------ */

static BOOL configure_settings(rdpSettings *s,
                               const macrdp_session_config *cfg) {
    if (cfg->tls_cert_pem_path && cfg->tls_key_pem_path) {
        rdpPrivateKey *key = freerdp_key_new_from_file_enc(cfg->tls_key_pem_path, NULL);
        if (!key) return FALSE;
        if (!freerdp_settings_set_pointer_len(s, FreeRDP_RdpServerRsaKey, key, 1))
            return FALSE;
        rdpCertificate *cert = freerdp_certificate_new_from_file(cfg->tls_cert_pem_path);
        if (!cert) return FALSE;
        if (!freerdp_settings_set_pointer_len(s, FreeRDP_RdpServerCertificate, cert, 1))
            return FALSE;
    }
    if (!freerdp_settings_set_bool(s, FreeRDP_RdpSecurity, TRUE))   return FALSE;
    if (!freerdp_settings_set_bool(s, FreeRDP_TlsSecurity, TRUE))   return FALSE;
    if (!freerdp_settings_set_bool(s, FreeRDP_NlaSecurity, FALSE))  return FALSE;
    if (!freerdp_settings_set_uint32(s, FreeRDP_EncryptionLevel,
                                     ENCRYPTION_LEVEL_CLIENT_COMPATIBLE)) return FALSE;
    if (!freerdp_settings_set_uint32(s, FreeRDP_ColorDepth, 32))     return FALSE;
    if (!freerdp_settings_set_bool(s, FreeRDP_SuppressOutput, TRUE)) return FALSE;
    if (!freerdp_settings_set_bool(s, FreeRDP_RefreshRect, TRUE))   return FALSE;
    if (!freerdp_settings_set_uint32(s, FreeRDP_MultifragMaxRequestSize, 0xFFFFFFu)) return FALSE;
    /* GFX codecs — we always advertise both AVC420 and Progressive so
     * the runtime codec choice (per-frame, by Swift) just works. */
    if (!freerdp_settings_set_bool(s, FreeRDP_SupportGraphicsPipeline, TRUE)) return FALSE;
    if (!freerdp_settings_set_bool(s, FreeRDP_GfxH264, TRUE)) return FALSE;
    if (!freerdp_settings_set_bool(s, FreeRDP_GfxAVC444, FALSE)) return FALSE;
    if (!freerdp_settings_set_bool(s, FreeRDP_GfxAVC444v2, FALSE)) return FALSE;
    if (!freerdp_settings_set_bool(s, FreeRDP_GfxProgressive, TRUE)) return FALSE;
    if (!freerdp_settings_set_bool(s, FreeRDP_GfxProgressiveV2, TRUE)) return FALSE;
    if (!freerdp_settings_set_bool(s, FreeRDP_GfxSmallCache, FALSE)) return FALSE;
    if (!freerdp_settings_set_bool(s, FreeRDP_GfxThinClient, FALSE)) return FALSE;
    if (!freerdp_settings_set_bool(s, FreeRDP_HasExtendedMouseEvent, TRUE)) return FALSE;
    /* Audio capabilities — advertise both playback and capture so the
     * client's "Remote audio" UI exposes both options. The runtime mode
     * is still controlled per-session by the client's INFO_REMOTECONSOLEAUDIO
     * bit + AudioCapture toggle. */
    if (!freerdp_settings_set_bool(s, FreeRDP_AudioPlayback, TRUE)) return FALSE;
    if (!freerdp_settings_set_bool(s, FreeRDP_AudioCapture, TRUE)) return FALSE;
    /* Display control extension — let the client request desktop resize
     * (window resize / fullscreen toggle on its side). */
    if (!freerdp_settings_set_bool(s, FreeRDP_SupportDisplayControl, TRUE)) return FALSE;
    /* CLIPRDR — bidirectional clipboard sync. Static VC; the client
     * joins automatically when RedirectClipboard is set. */
    if (!freerdp_settings_set_bool(s, FreeRDP_RedirectClipboard, TRUE)) return FALSE;
    return TRUE;
}

#endif /* MACRDP_HAVE_FREERDP */

/* -------- lifecycle ----------------------------------------------- */

int32_t macrdp_session_create(int fd,
                              void *swift_ctx,
                              const macrdp_callbacks *cbs,
                              const macrdp_session_config *cfg,
                              macrdp_session_t *out_session)
{
    if (!cbs || !cfg || !out_session || fd < 0) return MACRDP_E_INVALID_ARG;
    struct macrdp_session *s = (struct macrdp_session *)calloc(1, sizeof(*s));
    if (!s) return MACRDP_E_INTERNAL;
    s->fd        = fd;
    s->swift_ctx = swift_ctx;
    s->cbs       = *cbs;
    s->cfg       = *cfg;
    atomic_init(&s->stop_requested, 0);

#if MACRDP_HAVE_FREERDP
    /* Register FreeRDP's WTS implementation. WinPR's WTSOpenServerA only
     * tries FreeRDS by default; on macOS we have to explicitly register
     * the FreeRDP-side function table before WTSOpenServerA can work. */
    static atomic_int wts_registered = 0;
    if (!atomic_load(&wts_registered)) {
        WTSRegisterWtsApiFunctionTable(FreeRDP_InitWtsApi());
        atomic_store(&wts_registered, 1);
    }

    s->surface_id     = 0;
    s->next_frame_id  = 1;
    atomic_init(&s->activated, false);
    atomic_init(&s->rdpsnd_activated, false);
    atomic_init(&s->audio_start_ms, 0);
    atomic_init(&s->audio_selected_format, MACRDP_AUDIO_FORMAT_PCM);
    atomic_init(&s->audio_selected_format_no, 0);
    atomic_init(&s->audio_total_samples, 0);
    atomic_init(&s->cliprdr_ready, false);
    atomic_init(&s->cliprdr_outbound_request_id, 0);
    atomic_init(&s->outstanding_frames, 0);
    atomic_init(&s->last_ack_ms, now_ms());
    /* Fall back to a safe value if the caller passes 0/negative. */
    s->max_outstanding_frames =
        (cfg->max_outstanding_frames > 0) ? cfg->max_outstanding_frames : 2;

    freerdp_peer *peer = freerdp_peer_new(fd);
    if (!peer) { free(s); return MACRDP_E_PEER_INIT; }

    peer->ContextSize    = sizeof(BridgeContext);
    peer->ContextNew     = bridge_context_new;
    peer->ContextFree    = bridge_context_free;
    if (!freerdp_peer_context_new(peer)) {
        freerdp_peer_free(peer);
        free(s);
        return MACRDP_E_PEER_INIT;
    }
    ((BridgeContext*)peer->context)->session = s;
    s->peer = peer;

    if (!configure_settings(peer->context->settings, cfg)) {
        freerdp_peer_context_free(peer);
        freerdp_peer_free(peer);
        free(s);
        return MACRDP_E_TLS_FAILED;
    }

    peer->Capabilities = bridge_peer_capabilities;
    peer->PostConnect  = bridge_peer_post_connect;
    peer->Activate     = bridge_peer_activate;

    rdpInput *input = peer->context->input;
    input->SynchronizeEvent     = bridge_in_sync;
    input->KeyboardEvent        = bridge_in_keyboard;
    input->UnicodeKeyboardEvent = bridge_in_unicode;
    input->MouseEvent           = bridge_in_mouse;
    input->ExtendedMouseEvent   = bridge_in_xmouse;

    /* Display visibility — required so we don't keep blasting frames at
     * a minimized client (which it considers a protocol violation). */
    peer->context->update->SuppressOutput = bridge_suppress_output;

    if (!peer->Initialize(peer)) {
        freerdp_peer_context_free(peer);
        freerdp_peer_free(peer);
        free(s);
        return MACRDP_E_PEER_INIT;
    }

    os_log(bridge_log(), "macrdp_session_create OK fd=%d peer=%p", fd, peer);
#endif

    *out_session = s;
    return MACRDP_OK;
}

int32_t macrdp_session_run(macrdp_session_t s)
{
    if (!s) return MACRDP_E_INVALID_ARG;
#if MACRDP_HAVE_FREERDP
    if (!s->peer) return MACRDP_E_PEER_INIT;

    freerdp_peer *peer = s->peer;
    int32_t result = MACRDP_OK;
    HANDLE handles[64];
    s->drdynvc_last_joined = -1;
    s->drdynvc_last_state  = -1;

    while (!atomic_load(&s->stop_requested)) {
        DWORD count = peer->GetEventHandles(peer, handles, 32);
        if (count == 0) { result = MACRDP_E_INTERNAL; break; }
        HANDLE vcm = vcm_from_session(s);
        if (vcm) {
            HANDLE vcmHandle = WTSVirtualChannelManagerGetEventHandle(vcm);
            handles[count++] = vcmHandle;
        }
        /* When we run GFX in externalThread mode (low-latency path), we
         * also wait on its event handle so we can drain incoming PDUs
         * (CapsAdvertise, FrameAcknowledge, QoeFrameAcknowledge) without
         * a thread hop. */
        HANDLE gfxHandle = NULL;
        if (s->gfx && s->gfx_open_requested) {
            gfxHandle = rdpgfx_server_get_event_handle(s->gfx);
            if (gfxHandle) handles[count++] = gfxHandle;
        }

        DWORD waitStatus = WaitForMultipleObjects(count, handles, FALSE, 1000);
        if (waitStatus == WAIT_FAILED) { result = MACRDP_E_INTERNAL; break; }

        if (!peer->CheckFileDescriptor(peer)) { result = MACRDP_E_DISCONNECTED; break; }
        if (vcm) {
            BOOL ok = atomic_load(&s->activated)
                ? WTSVirtualChannelManagerCheckFileDescriptor(vcm)
                : WTSVirtualChannelManagerCheckFileDescriptorEx(vcm, FALSE);
            if (!ok) { result = MACRDP_E_DISCONNECTED; break; }
        }
        if (gfxHandle) {
            UINT rc = rdpgfx_server_handle_messages(s->gfx);
            if (rc != CHANNEL_RC_OK && rc != ERROR_NO_DATA) {
                /* GFX channel died but session may still be alive on TCP.
                 * Log + continue rather than tearing down. */
                os_log(bridge_log(), "rdpgfx_server_handle_messages: %u", rc);
            }
        }
        try_open_gfx(s);
        try_open_rdpsnd(s);
        try_open_audin(s);
        try_open_disp(s);
        try_open_cliprdr(s);

        /* FrameAck watchdog: if a client stops acking but the connection
         * is otherwise healthy, force-clear credit so we don't go black. */
        if (atomic_load(&s->outstanding_frames) > 0) {
            uint64_t since = now_ms() - atomic_load(&s->last_ack_ms);
            if (since > 500) {
                int prev = atomic_exchange(&s->outstanding_frames, 0);
                if (prev > 0) {
                    os_log(bridge_log(),
                           "frame-ack watchdog: %llums silent, flushing %d frames",
                           (unsigned long long)since, prev);
                    atomic_store(&s->last_ack_ms, now_ms());
                }
            }
        }

        /* Heartbeat every ~5s while we haven't opened GFX so we know
         * the event loop is alive and can see the current DRDYNVC state. */
        if (!s->gfx_open_requested) {
            if (++s->heartbeat_seconds_since_log >= 5 && vcm) {
                int j = (int)WTSVirtualChannelManagerIsChannelJoined(vcm, DRDYNVC_SVC_CHANNEL_NAME);
                int st = (int)WTSVirtualChannelManagerGetDrdynvcState(vcm);
                os_log(bridge_log(),
                       "heartbeat: drdynvc joined=%d state=%d gfx_open=%d caps_confirmed=%d",
                       j, st, (int)s->gfx_open_requested, (int)s->gfx_caps_confirmed);
                s->heartbeat_seconds_since_log = 0;
            }
        }
    }

    if (s->gfx) {
        s->gfx->Close(s->gfx);
        rdpgfx_server_context_free(s->gfx);
        s->gfx = NULL;
    }
    if (peer->Disconnect) peer->Disconnect(peer);

    if (s->cbs.on_closed) s->cbs.on_closed(s->swift_ctx, result);
    return result;
#else
    if (s->cbs.on_closed) s->cbs.on_closed(s->swift_ctx, MACRDP_E_FREERDP_UNAVAILABLE);
    return MACRDP_E_FREERDP_UNAVAILABLE;
#endif
}

void macrdp_session_request_stop(macrdp_session_t s)
{
    if (!s) return;
    atomic_store(&s->stop_requested, 1);
}

void macrdp_session_destroy(macrdp_session_t s)
{
    if (!s) return;
#if MACRDP_HAVE_FREERDP
    if (s->cliprdr) {
        (void)s->cliprdr->Stop(s->cliprdr);
        (void)s->cliprdr->Close(s->cliprdr);
        cliprdr_server_context_free(s->cliprdr);
        s->cliprdr = NULL;
    }
    if (s->disp) {
        if (s->disp->Close) (void)s->disp->Close(s->disp);
        disp_server_context_free(s->disp);
        s->disp = NULL;
    }
    if (s->audin) {
        if (s->audin->Close) (void)s->audin->Close(s->audin);
        audin_server_context_free(s->audin);
        s->audin = NULL;
    }
    if (s->rdpsnd) {
        if (s->rdpsnd->Close) s->rdpsnd->Close(s->rdpsnd);
        rdpsnd_server_context_free(s->rdpsnd);
        s->rdpsnd = NULL;
    }
    if (s->progressive) {
        progressive_context_free(s->progressive);
        s->progressive = NULL;
    }
    if (s->gfx) {
        rdpgfx_server_context_free(s->gfx);
        s->gfx = NULL;
    }
    if (s->peer) {
        freerdp_peer_context_free(s->peer);
        freerdp_peer_free(s->peer);
        s->peer = NULL;
    }
#endif
    free(s);
}

/* -------- output: GFX surface + AVC420 frame ---------------------- */

int32_t macrdp_session_reset_graphics(macrdp_session_t s,
                                      int32_t w, int32_t h, int32_t mc)
{
#if MACRDP_HAVE_FREERDP
    if (!s || !s->gfx || !s->gfx_caps_confirmed) return MACRDP_E_NOT_IMPLEMENTED;
    s->desktop_width = w;
    s->desktop_height = h;

    MONITOR_DEF monitor = { 0 };
    monitor.left = 0; monitor.top = 0;
    monitor.right = w - 1; monitor.bottom = h - 1;
    monitor.flags = MONITOR_PRIMARY;

    RDPGFX_RESET_GRAPHICS_PDU reset = { 0 };
    reset.width = (UINT32)w;
    reset.height = (UINT32)h;
    reset.monitorCount = mc > 0 ? (UINT32)mc : 1u;
    reset.monitorDefArray = &monitor;
    UINT rc = s->gfx->ResetGraphics(s->gfx, &reset);
    return rc == CHANNEL_RC_OK ? MACRDP_OK : MACRDP_E_INTERNAL;
#else
    (void)s; (void)w; (void)h; (void)mc;
    return MACRDP_E_NOT_IMPLEMENTED;
#endif
}

int32_t macrdp_session_create_surface(macrdp_session_t s,
                                      int32_t id, int32_t w, int32_t h)
{
#if MACRDP_HAVE_FREERDP
    if (!s || !s->gfx || !s->gfx_caps_confirmed) return MACRDP_E_NOT_IMPLEMENTED;
    RDPGFX_CREATE_SURFACE_PDU create = { 0 };
    create.surfaceId = (UINT16)id;
    create.width = (UINT16)w;
    create.height = (UINT16)h;
    create.pixelFormat = GFX_PIXEL_FORMAT_XRGB_8888;
    UINT rc = s->gfx->CreateSurface(s->gfx, &create);
    if (rc == CHANNEL_RC_OK) {
        s->surface_created = true;
        s->surface_id = (UINT16)id;
    }
    return rc == CHANNEL_RC_OK ? MACRDP_OK : MACRDP_E_INTERNAL;
#else
    (void)s; (void)id; (void)w; (void)h;
    return MACRDP_E_NOT_IMPLEMENTED;
#endif
}

int32_t macrdp_session_map_surface_to_output(macrdp_session_t s,
                                             int32_t id, int32_t ox, int32_t oy)
{
#if MACRDP_HAVE_FREERDP
    if (!s || !s->gfx || !s->gfx_caps_confirmed) return MACRDP_E_NOT_IMPLEMENTED;
    RDPGFX_MAP_SURFACE_TO_OUTPUT_PDU map = { 0 };
    map.surfaceId = (UINT16)id;
    map.outputOriginX = (UINT32)ox;
    map.outputOriginY = (UINT32)oy;
    UINT rc = s->gfx->MapSurfaceToOutput(s->gfx, &map);
    return rc == CHANNEL_RC_OK ? MACRDP_OK : MACRDP_E_INTERNAL;
#else
    (void)s; (void)id; (void)ox; (void)oy;
    return MACRDP_E_NOT_IMPLEMENTED;
#endif
}

int32_t macrdp_session_send_h264_frame(macrdp_session_t s,
                                       int32_t surface_id,
                                       const uint8_t *annexb,
                                       size_t bytes,
                                       int32_t is_idr,
                                       int64_t pts_us)
{
#if MACRDP_HAVE_FREERDP
    (void)is_idr;
    if (!s || !s->gfx || !s->gfx_caps_confirmed || !annexb || bytes == 0)
        return MACRDP_E_NOT_IMPLEMENTED;

    /* Flow control: if we have too many in-flight frames (encoded and
     * sent but not yet acknowledged by the client), drop this one and
     * tell the caller to mark the next one as an IDR so the client can
     * resync. */
    if (atomic_load(&s->outstanding_frames) >= s->max_outstanding_frames) {
        return MACRDP_E_FRAME_DROPPED;
    }

    /* Lazy surface creation on first frame. */
    if (!s->surface_created) {
        int32_t rc1 = macrdp_session_reset_graphics(s, s->desktop_width, s->desktop_height, 1);
        if (rc1 != MACRDP_OK) return rc1;
        int32_t rc2 = macrdp_session_create_surface(s, surface_id,
                                                    s->desktop_width, s->desktop_height);
        if (rc2 != MACRDP_OK) return rc2;
        int32_t rc3 = macrdp_session_map_surface_to_output(s, surface_id, 0, 0);
        if (rc3 != MACRDP_OK) return rc3;
    }

    /* Build the AVC420 wrapper (one region covering the whole surface). */
    RECTANGLE_16 rect = { 0 };
    rect.left = 0; rect.top = 0;
    rect.right = (UINT16)s->desktop_width;
    rect.bottom = (UINT16)s->desktop_height;

    RDPGFX_H264_QUANT_QUALITY quant = { 0 };
    quant.qp = (BYTE)((s->cfg.avc420_qp > 0) ? s->cfg.avc420_qp : 22);
    quant.r  = 0;
    quant.p  = 0;
    quant.qualityVal = (BYTE)((s->cfg.avc420_quality_val > 0) ? s->cfg.avc420_quality_val : 100);

    RDPGFX_AVC420_BITMAP_STREAM avc420 = { 0 };
    avc420.meta.numRegionRects = 1;
    avc420.meta.regionRects = &rect;
    avc420.meta.quantQualityVals = &quant;
    avc420.length = (UINT32)bytes;
    avc420.data = (BYTE*)annexb;  /* read-only; FreeRDP copies into its
                                     wire buffer */

    RDPGFX_SURFACE_COMMAND cmd = { 0 };
    cmd.surfaceId = (UINT32)surface_id;
    cmd.codecId   = RDPGFX_CODECID_AVC420;
    cmd.format    = PIXEL_FORMAT_BGRX32;
    cmd.left = 0; cmd.top = 0;
    cmd.right  = (UINT32)s->desktop_width;
    cmd.bottom = (UINT32)s->desktop_height;
    cmd.width  = (UINT32)s->desktop_width;
    cmd.height = (UINT32)s->desktop_height;
    cmd.length = (UINT32)bytes;
    cmd.data   = (BYTE*)annexb;
    cmd.extra  = &avc420;

    UINT32 frameId = s->next_frame_id++;
    RDPGFX_START_FRAME_PDU start = { 0 };
    start.frameId = frameId;
    start.timestamp = (UINT32)(pts_us / 1000);

    RDPGFX_END_FRAME_PDU end = { 0 };
    end.frameId = frameId;

    UINT rc = s->gfx->SurfaceFrameCommand(s->gfx, &cmd, &start, &end);
    if (rc == CHANNEL_RC_OK) {
        atomic_fetch_add(&s->outstanding_frames, 1);
        return MACRDP_OK;
    }
    return MACRDP_E_INTERNAL;
#else
    (void)s; (void)surface_id; (void)annexb; (void)bytes;
    (void)is_idr; (void)pts_us;
    return MACRDP_E_NOT_IMPLEMENTED;
#endif
}

/* RemoteFX Progressive V2 path. Takes a raw BGRA frame, runs it through
 * FreeRDP's wavelet encoder (which does its own tile-level damage
 * detection — returns 0 bytes if nothing changed), and sends as a
 * CAPROGRESSIVE_V2 SurfaceFrameCommand. */
int32_t macrdp_session_send_progressive_frame(macrdp_session_t s,
                                              int32_t surface_id,
                                              const uint8_t *bgra,
                                              int32_t width,
                                              int32_t height,
                                              int32_t stride)
{
#if MACRDP_HAVE_FREERDP
    if (!s || !s->gfx || !s->gfx_caps_confirmed || !bgra || width <= 0 || height <= 0)
        return MACRDP_E_NOT_IMPLEMENTED;
    if (atomic_load(&s->outstanding_frames) >= s->max_outstanding_frames) {
        return MACRDP_E_FRAME_DROPPED;
    }

    /* Lazy surface + encoder context creation on first frame. */
    if (!s->surface_created) {
        int32_t rc1 = macrdp_session_reset_graphics(s, s->desktop_width, s->desktop_height, 1);
        if (rc1 != MACRDP_OK) return rc1;
        int32_t rc2 = macrdp_session_create_surface(s, surface_id,
                                                    s->desktop_width, s->desktop_height);
        if (rc2 != MACRDP_OK) return rc2;
        int32_t rc3 = macrdp_session_map_surface_to_output(s, surface_id, 0, 0);
        if (rc3 != MACRDP_OK) return rc3;
    }
    if (!s->progressive) {
        s->progressive = progressive_context_new(TRUE /* compressor */);
        if (!s->progressive) return MACRDP_E_INTERNAL;
        if (!progressive_context_reset(s->progressive)) {
            progressive_context_free(s->progressive);
            s->progressive = NULL;
            return MACRDP_E_INTERNAL;
        }
    }

    /* Compress the full frame; let the encoder detect what changed. */
    REGION16 region;
    region16_init(&region);
    RECTANGLE_16 fullRect = { 0, 0, (UINT16)width, (UINT16)height };
    if (!region16_union_rect(&region, &region, &fullRect)) {
        region16_uninit(&region);
        return MACRDP_E_INTERNAL;
    }

    BYTE  *outData = NULL;
    UINT32 outLen  = 0;
    int rc = progressive_compress(
        s->progressive,
        bgra,
        (UINT32)(stride * height),
        PIXEL_FORMAT_BGRX32,
        (UINT32)width, (UINT32)height,
        (UINT32)stride,
        &region,
        &outData, &outLen);
    region16_uninit(&region);
    if (rc < 0) {
        os_log(bridge_log(), "progressive_compress failed rc=%d", rc);
        return MACRDP_E_INTERNAL;
    }
    if (rc == 0 || outLen == 0) {
        /* Encoder says "no change" — nothing to send. */
        return MACRDP_OK;
    }
    /* Log the first few frames so we can confirm wire bytes are sane. */
    static atomic_int progressive_frame_log_count = 0;
    int n = atomic_fetch_add(&progressive_frame_log_count, 1);
    if (n < 3) {
        os_log(bridge_log(),
               "progressive frame #%d: %ux%u stride=%u outLen=%u",
               n, (unsigned)width, (unsigned)height,
               (unsigned)stride, (unsigned)outLen);
    }

    RDPGFX_SURFACE_COMMAND cmd = { 0 };
    cmd.surfaceId = (UINT32)surface_id;
    /* FreeRDP's progressive_compress emits the V1 bitstream format.
     * The _V2 capset bit signals a slightly different *framing protocol*
     * negotiation, not a different encoder output. Sending V2 codec ID
     * with V1-encoded bytes makes the client decode garbage = blank. */
    cmd.codecId   = RDPGFX_CODECID_CAPROGRESSIVE;
    cmd.format    = PIXEL_FORMAT_BGRX32;
    cmd.left = 0; cmd.top = 0;
    cmd.right  = (UINT32)width;
    cmd.bottom = (UINT32)height;
    cmd.width  = (UINT32)width;
    cmd.height = (UINT32)height;
    cmd.length = outLen;
    cmd.data   = outData;
    cmd.extra  = NULL;

    UINT32 frameId = s->next_frame_id++;
    RDPGFX_START_FRAME_PDU start = { 0 };
    start.frameId   = frameId;
    start.timestamp = frameId;
    RDPGFX_END_FRAME_PDU end = { 0 };
    end.frameId = frameId;

    UINT res = s->gfx->SurfaceFrameCommand(s->gfx, &cmd, &start, &end);
    if (res == CHANNEL_RC_OK) {
        atomic_fetch_add(&s->outstanding_frames, 1);
        return MACRDP_OK;
    }
    return MACRDP_E_INTERNAL;
#else
    (void)s; (void)surface_id; (void)bgra; (void)width; (void)height; (void)stride;
    return MACRDP_E_NOT_IMPLEMENTED;
#endif
}

void macrdp_session_set_desktop_size(macrdp_session_t s,
                                     int32_t width, int32_t height) {
#if MACRDP_HAVE_FREERDP
    if (!s || width <= 0 || height <= 0) return;
    s->desktop_width  = width;
    s->desktop_height = height;
    /* If a surface was already created at the old size, force re-creation
     * on the next frame so RESETGRAPHICS + CreateSurface fire with the
     * new dimensions. */
    s->surface_created = false;
    os_log(bridge_log(), "Desktop size override → %dx%d", width, height);
#else
    (void)s; (void)width; (void)height;
#endif
}

/* Lightweight flow-control probe — Swift checks this before encoding
 * a captured frame; if the wire is saturated we skip the VT pass entirely
 * to save CPU and bound bufferbloat at the source. */
int32_t macrdp_session_outstanding_frames(macrdp_session_t s) {
#if MACRDP_HAVE_FREERDP
    if (!s) return 0;
    return atomic_load(&s->outstanding_frames);
#else
    (void)s;
    return 0;
#endif
}

int32_t macrdp_session_send_audio_pcm(macrdp_session_t s,
                                      const uint8_t *pcm, size_t bytes)
{
#if MACRDP_HAVE_FREERDP
    if (!s || !s->rdpsnd || !atomic_load(&s->rdpsnd_activated)
        || !pcm || bytes == 0) {
        return MACRDP_E_NOT_IMPLEMENTED;
    }
    /* Int16LE stereo = 4 bytes per frame */
    size_t nframes = bytes / 4;
    if (nframes == 0) return MACRDP_OK;
    /* Wave timestamp = ms since RDPSND activated, mod 2^16. mstsc paces
     * playback against this; sending 0 every time confuses it into a
     * multi-second jitter buffer. */
    uint64_t elapsed = now_ms() - atomic_load(&s->audio_start_ms);
    UINT16 wTimestamp = (UINT16)(elapsed & 0xFFFFu);
    UINT rc = s->rdpsnd->SendSamples(s->rdpsnd, pcm, nframes, wTimestamp);
    if (rc == CHANNEL_RC_OK) {
        atomic_fetch_add(&s->audio_total_samples, (uint32_t)nframes);
    }
    return rc == CHANNEL_RC_OK ? MACRDP_OK : MACRDP_E_INTERNAL;
#else
    (void)s; (void)pcm; (void)bytes;
    return MACRDP_E_NOT_IMPLEMENTED;
#endif
}

int32_t macrdp_session_send_audio_aac(macrdp_session_t s,
                                      const uint8_t *aac, size_t bytes,
                                      uint32_t pcm_sample_count)
{
#if MACRDP_HAVE_FREERDP
    if (!s || !s->rdpsnd || !atomic_load(&s->rdpsnd_activated)
        || !aac || bytes == 0) {
        return MACRDP_E_NOT_IMPLEMENTED;
    }
    /* Wave2 PDU carries:
     *   - wTimestamp (UINT16): ms since session start mod 65536
     *   - wFormatNo  (UINT16): index into the client_formats array
     *   - cBlockNo   (UINT8):  block counter (FreeRDP manages)
     *   - audioTimeStamp (UINT32): per MS-RDPEA § 2.2.3.10, this is
     *     "the time stamp of the audio frame as obtained by
     *     GetTickCount()" — i.e., wall-clock ms, NOT sample count.
     *     Passing cumulative samples here makes mstsc think every new
     *     packet is further in the future, growing its jitter buffer
     *     unboundedly. */
    uint64_t elapsed = now_ms() - atomic_load(&s->audio_start_ms);
    UINT16 wTimestamp = (UINT16)(elapsed & 0xFFFFu);
    UINT16 formatNo   = (UINT16)atomic_load(&s->audio_selected_format_no);
    UINT32 audioTS    = (UINT32)(elapsed & 0xFFFFFFFFu);
    (void)pcm_sample_count;  /* still incremented for diagnostic purposes */
    atomic_fetch_add(&s->audio_total_samples, pcm_sample_count);
    UINT rc = s->rdpsnd->SendSamples2(s->rdpsnd, formatNo,
                                       aac, bytes, wTimestamp, audioTS);
    return rc == CHANNEL_RC_OK ? MACRDP_OK : MACRDP_E_INTERNAL;
#else
    (void)s; (void)aac; (void)bytes; (void)pcm_sample_count;
    return MACRDP_E_NOT_IMPLEMENTED;
#endif
}

int32_t macrdp_session_send_clip_format_list(macrdp_session_t s,
                                             const macrdp_clip_format *formats,
                                             int32_t count)
{
#if MACRDP_HAVE_FREERDP
    if (!s || !s->cliprdr || !atomic_load(&s->cliprdr_ready)) {
        return MACRDP_E_NOT_IMPLEMENTED;
    }
    if (count < 0) count = 0;

    CLIPRDR_FORMAT *list = NULL;
    if (count > 0) {
        list = (CLIPRDR_FORMAT *)calloc((size_t)count, sizeof(CLIPRDR_FORMAT));
        if (!list) return MACRDP_E_INTERNAL;
        for (int32_t i = 0; i < count; ++i) {
            list[i].formatId   = formats[i].id;
            /* CLIPRDR_FORMAT.formatName is `char*` (non-const). FreeRDP
             * copies the string into its wire buffer, so casting away
             * const here is safe. */
            list[i].formatName = (char *)formats[i].name;
        }
    }

    CLIPRDR_FORMAT_LIST pdu = { 0 };
    pdu.common.msgType = CB_FORMAT_LIST;
    pdu.numFormats     = (UINT32)count;
    pdu.formats        = list;

    UINT rc = s->cliprdr->ServerFormatList(s->cliprdr, &pdu);
    free(list);
    return rc == CHANNEL_RC_OK ? MACRDP_OK : MACRDP_E_INTERNAL;
#else
    (void)s; (void)formats; (void)count;
    return MACRDP_E_NOT_IMPLEMENTED;
#endif
}

int32_t macrdp_session_send_clip_data_response(macrdp_session_t s,
                                               uint32_t fid,
                                               const uint8_t *data, size_t len)
{
#if MACRDP_HAVE_FREERDP
    if (!s || !s->cliprdr) return MACRDP_E_NOT_IMPLEMENTED;
    (void)fid;     /* CLIPRDR doesn't echo the format id in the response;
                      the client matches against its last request. */

    CLIPRDR_FORMAT_DATA_RESPONSE pdu = { 0 };
    pdu.common.msgType  = CB_FORMAT_DATA_RESPONSE;
    pdu.common.msgFlags = (data && len > 0) ? CB_RESPONSE_OK : CB_RESPONSE_FAIL;
    pdu.common.dataLen  = (UINT32)len;
    pdu.requestedFormatData = data;

    UINT rc = s->cliprdr->ServerFormatDataResponse(s->cliprdr, &pdu);
    return rc == CHANNEL_RC_OK ? MACRDP_OK : MACRDP_E_INTERNAL;
#else
    (void)s; (void)fid; (void)data; (void)len;
    return MACRDP_E_NOT_IMPLEMENTED;
#endif
}

int32_t macrdp_session_send_clip_data_request(macrdp_session_t s, uint32_t fid)
{
#if MACRDP_HAVE_FREERDP
    if (!s || !s->cliprdr || !atomic_load(&s->cliprdr_ready)) {
        return MACRDP_E_NOT_IMPLEMENTED;
    }
    CLIPRDR_FORMAT_DATA_REQUEST req = { 0 };
    req.common.msgType     = CB_FORMAT_DATA_REQUEST;
    /* FreeRDP allocates the wire stream from `common.dataLen` and then
     * writes a single UINT32 (the format id) — must reserve 4 bytes or
     * Stream_Write_UINT32 asserts. */
    req.common.dataLen     = 4;
    req.requestedFormatId  = fid;
    /* Stash the id before sending so the response handler can match it. */
    atomic_store(&s->cliprdr_outbound_request_id, fid);
    UINT rc = s->cliprdr->ServerFormatDataRequest(s->cliprdr, &req);
    return rc == CHANNEL_RC_OK ? MACRDP_OK : MACRDP_E_INTERNAL;
#else
    (void)s; (void)fid;
    return MACRDP_E_NOT_IMPLEMENTED;
#endif
}

int32_t macrdp_session_send_clip_file_contents_response(macrdp_session_t s,
                                                        uint32_t sid,
                                                        int32_t success,
                                                        const uint8_t *data,
                                                        size_t len)
{
#if MACRDP_HAVE_FREERDP
    if (!s || !s->cliprdr) return MACRDP_E_NOT_IMPLEMENTED;

    CLIPRDR_FILE_CONTENTS_RESPONSE pdu = { 0 };
    pdu.common.msgType  = CB_FILECONTENTS_RESPONSE;
    pdu.common.msgFlags = success ? CB_RESPONSE_OK : CB_RESPONSE_FAIL;
    pdu.common.dataLen  = (UINT32)(4 + len);  /* streamId + payload */
    pdu.streamId        = sid;
    pdu.cbRequested     = (UINT32)len;
    pdu.requestedData   = data;

    UINT rc = s->cliprdr->ServerFileContentsResponse(s->cliprdr, &pdu);
    return rc == CHANNEL_RC_OK ? MACRDP_OK : MACRDP_E_INTERNAL;
#else
    (void)s; (void)sid; (void)success; (void)data; (void)len;
    return MACRDP_E_NOT_IMPLEMENTED;
#endif
}

int32_t macrdp_session_send_clip_file_contents_request(macrdp_session_t s,
                                                       uint32_t sid,
                                                       uint32_t list_index,
                                                       int32_t want_size,
                                                       uint64_t offset,
                                                       uint32_t length)
{
#if MACRDP_HAVE_FREERDP
    if (!s || !s->cliprdr || !atomic_load(&s->cliprdr_ready)) {
        return MACRDP_E_NOT_IMPLEMENTED;
    }
    CLIPRDR_FILE_CONTENTS_REQUEST req = { 0 };
    req.common.msgType  = CB_FILECONTENTS_REQUEST;
    /* FreeRDP allocates the wire stream sized to dataLen. The PDU body
     * is 28 bytes (streamId + listIndex + dwFlags + nPositionLow +
     * nPositionHigh + cbRequested + clipDataId). */
    req.common.dataLen   = 28;
    req.streamId         = sid;
    req.listIndex        = list_index;
    req.dwFlags          = want_size ? FILECONTENTS_SIZE : FILECONTENTS_RANGE;
    req.nPositionLow     = (UINT32)(offset & 0xFFFFFFFFu);
    req.nPositionHigh    = (UINT32)((offset >> 32) & 0xFFFFFFFFu);
    req.cbRequested      = length;
    req.haveClipDataId   = FALSE;
    UINT rc = s->cliprdr->ServerFileContentsRequest(s->cliprdr, &req);
    return rc == CHANNEL_RC_OK ? MACRDP_OK : MACRDP_E_INTERNAL;
#else
    (void)s; (void)sid; (void)list_index; (void)want_size; (void)offset; (void)length;
    return MACRDP_E_NOT_IMPLEMENTED;
#endif
}

/* -------- versioning ---------------------------------------------- */

const char *macrdp_bridge_version(void) { return BRIDGE_VERSION; }
const char *macrdp_bridge_freerdp_version(void) {
#if MACRDP_HAVE_FREERDP
    return freerdp_get_version_string();
#else
    return "unavailable";
#endif
}
