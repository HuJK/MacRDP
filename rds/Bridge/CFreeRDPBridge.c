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
#include <os/lock.h>
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
#  include <freerdp/server/rdpdr.h>
#  include <freerdp/channels/rdpdr.h>
#  include <freerdp/utils/rdpdr_utils.h>
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

/* 1-second buckets of the minimum observed audio lag, for the windowed-floor
 * drift detector. 64 buckets = up to 64 s of reference history. */
#define MACRDP_AUDIO_LAG_BUCKETS 64

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
    /* Playback-progress tracking (RDPSND block confirms). All wTimestamps are
     * ms-since-activation mod 2^16. Lag = last_sent_ts - confirmed_ts. Used to
     * drop-to-recover so a stall can't accumulate unbounded latency. */
    _Atomic uint16_t       audio_last_sent_ts;
    _Atomic uint16_t       audio_confirmed_ts;
    _Atomic uint8_t        audio_confirmed_block;
    _Atomic int32_t        audio_have_confirm;     /* 0 until first confirm */
    _Atomic uint64_t       audio_lag_log_ms;       /* last periodic log time */
    /* Windowed-floor drift state. Written only by the confirm callback (single
     * channel thread → no lock); the send path reads the published floors. */
    uint16_t               audio_lag_bucket[MACRDP_AUDIO_LAG_BUCKETS]; /* per-1s min, 0xFFFF=empty */
    uint64_t               audio_lag_bucket_t0;    /* start ms of current bucket */
    int32_t                audio_lag_head;         /* current bucket index */
    int32_t                audio_lag_count;        /* valid buckets so far */
    _Atomic int32_t        audio_short_floor_ms;   /* min lag over short window */
    _Atomic int32_t        audio_drift_ms;         /* shortFloor − refFloor */
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
    /* RDPDR — device redirection (drives, printers, smartcards).
     * Phase 1 just logs device announces; later phases mount drives
     * as FileProvider domains. */
    RdpdrServerContext    *rdpdr;
    bool                   rdpdr_open;
    /* Set after the server↔client capability + monitor-ready handshake
     * completes; before that we must not send FormatList PDUs. */
    atomic_bool            cliprdr_ready;
    /* Track the format id of our most recent outbound FormatDataRequest.
     * FreeRDP's ctx->lastRequestedFormatId is only updated for inbound
     * requests (client→server), so we can't rely on it when matching the
     * response to our pending outbound request. */
    _Atomic uint32_t       cliprdr_outbound_request_id;
    /* Serializes pointer-update sends (fired from the cursor poll thread). */
    os_unfair_lock         pointer_lock;
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

    /* Prefer the configured codec, fall back to PCM (always advertised). */
    UINT16 wantTag;
    int32_t fmtType;
    switch (s->cfg.audio_codec) {
    case 1:  wantTag = WAVE_FORMAT_PCM;    fmtType = MACRDP_AUDIO_FORMAT_PCM;  break;
    case 3:  wantTag = WAVE_FORMAT_OPUS;   fmtType = MACRDP_AUDIO_FORMAT_OPUS; break;
    default: wantTag = WAVE_FORMAT_AAC_MS; fmtType = MACRDP_AUDIO_FORMAT_AAC;  break;
    }
    int pickedIdx = rdpsnd_match_format(ctx, wantTag);
    if (pickedIdx < 0 && wantTag != WAVE_FORMAT_PCM) {
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
           fmtType == MACRDP_AUDIO_FORMAT_AAC ? "AAC"
             : (fmtType == MACRDP_AUDIO_FORMAT_OPUS ? "Opus" : "PCM"));
    /* Tell Swift which encoder to engage. */
    if (s->cbs.on_audio_format_selected) {
        s->cbs.on_audio_format_selected(s->swift_ctx, fmtType);
    }
}

/* Client → server playback confirmation. Updates the windowed-floor drift
 * estimate (sustained latency vs jitter) and periodically logs progress.
 * Single-threaded (FreeRDP channel thread), so the bucket ring needs no lock;
 * results are published to the send path via atomics. */
static UINT rdpsnd_confirm_block_cb(RdpsndServerContext *ctx,
                                    BYTE confirmBlockNum, UINT16 wtimestamp) {
    struct macrdp_session *s = (struct macrdp_session*)ctx->data;
    if (!s) return CHANNEL_RC_OK;
    atomic_store(&s->audio_confirmed_block, confirmBlockNum);
    atomic_store(&s->audio_confirmed_ts, wtimestamp);
    atomic_store(&s->audio_have_confirm, 1);

    uint64_t now = now_ms();
    /* Lag = gap between our latest sent packet and the just-played block. */
    UINT16 sentTs = atomic_load(&s->audio_last_sent_ts);
    int lag = (int)(UINT16)(sentTs - wtimestamp);   /* mod-2^16 ms */
    if (lag < 0) lag = 0;
    if (lag > 30000) lag = 30000;                   /* guard wrap / client-ahead */

    /* Update the 1-second bucket ring of lag minima. */
    if (s->audio_lag_count == 0) {
        s->audio_lag_bucket_t0 = now;
        s->audio_lag_head = 0;
        s->audio_lag_bucket[0] = (uint16_t)lag;
        s->audio_lag_count = 1;
    } else {
        int64_t elapsed = (int64_t)(now - s->audio_lag_bucket_t0);
        int advance = (elapsed > 0) ? (int)(elapsed / 1000) : 0;
        if (advance > 0) {
            if (advance > MACRDP_AUDIO_LAG_BUCKETS) advance = MACRDP_AUDIO_LAG_BUCKETS;
            for (int i = 0; i < advance; i++) {
                s->audio_lag_head = (s->audio_lag_head + 1) % MACRDP_AUDIO_LAG_BUCKETS;
                s->audio_lag_bucket[s->audio_lag_head] = 0xFFFF;
            }
            s->audio_lag_bucket_t0 += (uint64_t)advance * 1000;
            s->audio_lag_bucket[s->audio_lag_head] = (uint16_t)lag;
            s->audio_lag_count += advance;
            if (s->audio_lag_count > MACRDP_AUDIO_LAG_BUCKETS)
                s->audio_lag_count = MACRDP_AUDIO_LAG_BUCKETS;
        } else if ((uint16_t)lag < s->audio_lag_bucket[s->audio_lag_head]) {
            s->audio_lag_bucket[s->audio_lag_head] = (uint16_t)lag;
        }
    }

    /* Floors over the short and reference windows (in 1s buckets). */
    int refBuckets = s->cfg.audio_lag_ref_window_ms / 1000;
    if (refBuckets < 1) refBuckets = 1;
    if (refBuckets > MACRDP_AUDIO_LAG_BUCKETS) refBuckets = MACRDP_AUDIO_LAG_BUCKETS;
    int shortBuckets = s->cfg.audio_lag_short_window_ms / 1000;
    if (shortBuckets < 1) shortBuckets = 1;
    if (shortBuckets > refBuckets) shortBuckets = refBuckets;

    int valid = s->audio_lag_count;
    int refScan   = (refBuckets   < valid) ? refBuckets   : valid;
    int shortScan = (shortBuckets < valid) ? shortBuckets : valid;
    int refFloor = INT32_MAX, shortFloor = INT32_MAX;
    for (int i = 0; i < refScan; i++) {
        int idx = (s->audio_lag_head - i + MACRDP_AUDIO_LAG_BUCKETS) % MACRDP_AUDIO_LAG_BUCKETS;
        uint16_t v = s->audio_lag_bucket[idx];
        if (v == 0xFFFF) continue;
        if ((int)v < refFloor) refFloor = v;
        if (i < shortScan && (int)v < shortFloor) shortFloor = v;
    }
    if (refFloor == INT32_MAX) refFloor = lag;
    if (shortFloor == INT32_MAX) shortFloor = lag;

    atomic_store(&s->audio_short_floor_ms, shortFloor);
    atomic_store(&s->audio_drift_ms, shortFloor - refFloor);

    uint64_t last = atomic_load(&s->audio_lag_log_ms);
    if (now - last >= 2000) {
        atomic_store(&s->audio_lag_log_ms, now);
        os_log(bridge_log(),
               "RDPSND progress: sent_block=%u played_block=%u lag=%dms shortFloor=%dms drift=%dms",
               (unsigned)ctx->block_no, (unsigned)confirmBlockNum,
               lag, shortFloor, shortFloor - refFloor);
    }
    return CHANNEL_RC_OK;
}

/* True if we should DROP this audio packet to bound buffered latency. Records
 * the would-be send timestamp (for lag), then decides from the published
 * floors: drop on sustained DRIFT (floor rising above the reference) — never
 * on jitter — plus an absolute backstop for very slow skew. Codec-independent. */
static bool rdpsnd_should_drop(struct macrdp_session *s, UINT16 wTimestamp) {
    atomic_store(&s->audio_last_sent_ts, wTimestamp);
    if (!atomic_load(&s->audio_have_confirm)) return false;   /* let it prime */
    int drift = atomic_load(&s->audio_drift_ms);
    int shortFloor = atomic_load(&s->audio_short_floor_ms);
    if (s->cfg.audio_lag_drift_allowance_ms > 0 &&
        drift > s->cfg.audio_lag_drift_allowance_ms) {
        return true;
    }
    if (s->cfg.audio_max_lag_ms > 0 && shortFloor > s->cfg.audio_max_lag_ms) {
        return true;
    }
    return false;
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
    /* Advertise the configured compressed codec (if any) first, then PCM as
     * a universal fallback. audio_codec: 1=pcm, 2=aac, 3=opus. */
    const BOOL wantCompressed = (s->cfg.audio_codec == 2 || s->cfg.audio_codec == 3);
    const int nfmt = wantCompressed ? 2 : 1;
    AUDIO_FORMAT *fmts = (AUDIO_FORMAT *)calloc((size_t)nfmt, sizeof(AUDIO_FORMAT));
    if (!fmts) {
        rdpsnd_server_context_free(ctx);
        return;
    }

    if (s->cfg.audio_codec == 2) {
        /* AAC-LC 48k stereo @ 128 kbps. mstsc needs the HEAACWAVEINFO
         * extension data to decode our raw AAC frames. cbSize=14 payload:
         *   wPayloadType (UINT16 LE) = 0   (Raw — no ADTS framing)
         *   wAudioProfileLevelIndication (UINT16 LE) = 0x29 (AAC-LC L2)
         *   wStructType / wReserved1 / dwReserved2 = 0
         *   AudioSpecificConfig (2 bytes) = 0x11 0x90
         *     = AOT=2 (LC), samplingFreqIndex=3 (48k), channelConfig=2 (stereo) */
        static const size_t kAacExtraLen = 14;
        BYTE *aacExtra = (BYTE *)calloc(1, kAacExtraLen);
        if (!aacExtra) {
            free(fmts);
            rdpsnd_server_context_free(ctx);
            return;
        }
        aacExtra[2] = 0x29;          /* wAudioProfileLevelIndication low byte */
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
    } else if (s->cfg.audio_codec == 3) {
        /* Opus 48k stereo. FreeRDP's WAVE_FORMAT_OPUS (0x704F); the client
         * builds an Opus decoder from channels + sample rate, no extra data.
         * Only FreeRDP clients with Opus support advertise/accept it. */
        fmts[0].wFormatTag      = WAVE_FORMAT_OPUS;
        fmts[0].nChannels       = 2;
        fmts[0].nSamplesPerSec  = 48000;
        fmts[0].wBitsPerSample  = 16;
        fmts[0].nBlockAlign     = 4;
        fmts[0].nAvgBytesPerSec = 12000;     /* ~96 kbps */
        fmts[0].cbSize          = 0;
        fmts[0].data            = NULL;
    }

    /* PCM 16-bit 48 kHz stereo — always present (primary for "pcm", else
     * the fallback for older / non-Opus clients). */
    const int pcmIdx = wantCompressed ? 1 : 0;
    fmts[pcmIdx].wFormatTag      = WAVE_FORMAT_PCM;
    fmts[pcmIdx].nChannels       = 2;
    fmts[pcmIdx].nSamplesPerSec  = 48000;
    fmts[pcmIdx].wBitsPerSample  = 16;
    fmts[pcmIdx].nBlockAlign     = 4;
    fmts[pcmIdx].nAvgBytesPerSec = 48000 * 4;
    fmts[pcmIdx].cbSize          = 0;
    fmts[pcmIdx].data            = NULL;

    ctx->server_formats     = fmts;
    ctx->num_server_formats = (UINT16)nfmt;
    /* src_format = the format we DELIVER samples in at the SendSamples API
     * (always PCM; compressed frames go via SendSamples2). */
    ctx->src_format         = &fmts[pcmIdx];
    /* Latency hint to FreeRDP's WAVE PDU pacer. Smaller = less server
     * buffering. Most of the user-observed audio lag is in mstsc's
     * PCM jitter buffer (~300-500ms) which is out of our control; an
     * AAC / Opus codec path would cut that to ~50-100ms. */
    ctx->latency            = 20;
    ctx->data               = s;
    ctx->Activated          = rdpsnd_activated_cb;
    ctx->ConfirmBlock       = rdpsnd_confirm_block_cb;
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
    /* Testing again on FreeRDP master HEAD with LOCK_CLIPDATA on. */
    ctx->canLockClipData        = TRUE;
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

/* -------- RDPDR (device / drive redirection) ---------------------- */

static UINT rdpdr_on_drive_create_cb(RdpdrServerContext *ctx,
                                     const RdpdrDevice *device) {
    struct macrdp_session *s = (struct macrdp_session*)ctx->data;
    if (!s || !device) return CHANNEL_RC_OK;
    /* PreferredDosName is fixed 8 bytes, not necessarily NUL-terminated. */
    char dos[9];
    memcpy(dos, device->PreferredDosName, 8);
    dos[8] = '\0';
    os_log(bridge_log(),
           "RDPDR drive announce: id=%u type=0x%X dos='%s'",
           device->DeviceId, device->DeviceType, dos);
    if (s->cbs.on_rdpdr_device_added) {
        s->cbs.on_rdpdr_device_added(s->swift_ctx,
                                     device->DeviceId,
                                     device->DeviceType,
                                     dos);
    }
    return CHANNEL_RC_OK;
}

static UINT rdpdr_on_drive_delete_cb(RdpdrServerContext *ctx,
                                     UINT32 deviceId) {
    struct macrdp_session *s = (struct macrdp_session*)ctx->data;
    if (!s) return CHANNEL_RC_OK;
    os_log(bridge_log(), "RDPDR drive removed: id=%u", deviceId);
    if (s->cbs.on_rdpdr_device_removed) {
        s->cbs.on_rdpdr_device_removed(s->swift_ctx, deviceId);
    }
    return CHANNEL_RC_OK;
}

/* FILETIME (100-ns ticks since 1601-01-01) → Unix epoch milliseconds. */
static int64_t rdpdr_filetime_to_unix_ms(int64_t ft) {
    if (ft <= 0) return 0;
    return ft / 10000LL - 11644473600000LL;
}

/* --- Drive I/O completion callbacks (fire on the channel thread). The
 *     IRP's CallbackData carries the Swift-chosen token verbatim. --- */

static void rdpdr_query_dir_complete_cb(RdpdrServerContext *ctx, void *cbData,
                                        UINT32 ioStatus,
                                        FILE_DIRECTORY_INFORMATION *fdi) {
    struct macrdp_session *s = (struct macrdp_session*)ctx->data;
    if (!s || !s->cbs.on_rdpdr_dir_entry) return;
    uint64_t token = (uint64_t)(uintptr_t)cbData;
    if (fdi) {
        s->cbs.on_rdpdr_dir_entry(
            s->swift_ctx, token, 1, ioStatus,
            fdi->FileName, fdi->FileAttributes,
            (uint64_t)fdi->EndOfFile.QuadPart,
            rdpdr_filetime_to_unix_ms(fdi->LastWriteTime.QuadPart));
    } else {
        s->cbs.on_rdpdr_dir_entry(s->swift_ctx, token, 0, ioStatus, NULL, 0, 0, 0);
    }
}

static void rdpdr_open_complete_cb(RdpdrServerContext *ctx, void *cbData,
                                   UINT32 ioStatus, UINT32 deviceId, UINT32 fileId) {
    struct macrdp_session *s = (struct macrdp_session*)ctx->data;
    if (s && s->cbs.on_rdpdr_open_complete)
        s->cbs.on_rdpdr_open_complete(s->swift_ctx, (uint64_t)(uintptr_t)cbData,
                                      ioStatus, deviceId, fileId);
}

static void rdpdr_read_complete_cb(RdpdrServerContext *ctx, void *cbData,
                                   UINT32 ioStatus, const char *buffer, UINT32 length) {
    struct macrdp_session *s = (struct macrdp_session*)ctx->data;
    if (s && s->cbs.on_rdpdr_read_complete)
        s->cbs.on_rdpdr_read_complete(s->swift_ctx, (uint64_t)(uintptr_t)cbData,
                                      ioStatus, (const uint8_t*)buffer, length);
}

static void rdpdr_write_complete_cb(RdpdrServerContext *ctx, void *cbData,
                                    UINT32 ioStatus, UINT32 bytesWritten) {
    struct macrdp_session *s = (struct macrdp_session*)ctx->data;
    if (s && s->cbs.on_rdpdr_write_complete)
        s->cbs.on_rdpdr_write_complete(s->swift_ctx, (uint64_t)(uintptr_t)cbData,
                                       ioStatus, bytesWritten);
}

static void rdpdr_close_complete_cb(RdpdrServerContext *ctx, void *cbData, UINT32 ioStatus) {
    struct macrdp_session *s = (struct macrdp_session*)ctx->data;
    if (s && s->cbs.on_rdpdr_close_complete)
        s->cbs.on_rdpdr_close_complete(s->swift_ctx, (uint64_t)(uintptr_t)cbData, ioStatus);
}

/* create-dir / delete-dir / delete-file / rename all just report status. */
static void rdpdr_simple_complete_cb(RdpdrServerContext *ctx, void *cbData, UINT32 ioStatus) {
    struct macrdp_session *s = (struct macrdp_session*)ctx->data;
    if (s && s->cbs.on_rdpdr_simple_complete)
        s->cbs.on_rdpdr_simple_complete(s->swift_ctx, (uint64_t)(uintptr_t)cbData, ioStatus);
}

static void try_open_rdpdr(struct macrdp_session *s) {
    if (s->rdpdr_open || !s->cfg.enable_rdpdr) return;
    if (!atomic_load(&s->activated)) return;
    HANDLE vcm = vcm_from_session(s);
    if (!vcm) return;
    /* RDPDR is a static virtual channel; client joins it when we
     * advertise via FreeRDP_RedirectDrives etc. */
    if (!WTSVirtualChannelManagerIsChannelJoined(vcm, RDPDR_SVC_CHANNEL_NAME))
        return;

    RdpdrServerContext *ctx = rdpdr_server_context_new(vcm);
    if (!ctx) {
        os_log(bridge_log(), "rdpdr_server_context_new failed");
        return;
    }
    ctx->rdpcontext = s->peer->context;
    ctx->data       = s;     /* RdpdrServerContext uses `data` (not `custom`) */
    /* Phase 1: drives only. Phase 4+: also advertise printers / smart cards. */
    ctx->supported  = RDPDR_DTYP_FILESYSTEM;
    ctx->OnDriveCreate = rdpdr_on_drive_create_cb;
    ctx->OnDriveDelete = rdpdr_on_drive_delete_cb;
    /* Drive I/O completions → Swift (DriveStore). */
    ctx->OnDriveQueryDirectoryComplete  = rdpdr_query_dir_complete_cb;
    ctx->OnDriveOpenFileComplete        = rdpdr_open_complete_cb;
    ctx->OnDriveReadFileComplete        = rdpdr_read_complete_cb;
    ctx->OnDriveWriteFileComplete       = rdpdr_write_complete_cb;
    ctx->OnDriveCloseFileComplete       = rdpdr_close_complete_cb;
    ctx->OnDriveCreateDirectoryComplete = rdpdr_simple_complete_cb;
    ctx->OnDriveDeleteDirectoryComplete = rdpdr_simple_complete_cb;
    ctx->OnDriveDeleteFileComplete      = rdpdr_simple_complete_cb;
    ctx->OnDriveRenameFileComplete      = rdpdr_simple_complete_cb;

    UINT rc = ctx->Start(ctx);
    if (rc != CHANNEL_RC_OK) {
        os_log(bridge_log(), "rdpdr Start failed: %u", rc);
        rdpdr_server_context_free(ctx);
        return;
    }
    s->rdpdr = ctx;
    s->rdpdr_open = true;
    os_log(bridge_log(), "RDPDR channel opened (static VC)");
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

    /* Login gate (NLA off): validate the client-submitted credentials. */
    struct macrdp_session *sess = session_from_peer(peer);
    if (sess && sess->cfg.auth_gate && sess->cbs.on_verify_password) {
        const char *user = freerdp_settings_get_string(s, FreeRDP_Username);
        const char *domain = freerdp_settings_get_string(s, FreeRDP_Domain);
        const char *pass = freerdp_settings_get_string(s, FreeRDP_Password);
        if (!user || !pass) {
            os_log(bridge_log(), "login gate: client sent no username/password; rejecting");
            return FALSE;
        }
        int32_t ok = sess->cbs.on_verify_password(sess->swift_ctx, user,
                                                  domain ? domain : "", pass);
        if (!ok) {
            os_log(bridge_log(), "login gate: password verification failed for user '%s'", user);
            return FALSE;
        }
        os_log(bridge_log(), "login gate: verified user '%s'", user);
    }
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
    /* NLA: validate the client's NTLM proof against the NT-hash in our SAM
     * file. Off → no authentication (open). */
    if (cfg->enable_nla && cfg->ntlm_sam_file_path) {
        if (!freerdp_settings_set_bool(s, FreeRDP_NlaSecurity, TRUE)) return FALSE;
        if (!freerdp_settings_set_string(s, FreeRDP_NtlmSamFile, cfg->ntlm_sam_file_path))
            return FALSE;
    } else {
        if (!freerdp_settings_set_bool(s, FreeRDP_NlaSecurity, FALSE)) return FALSE;
    }
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
    /* RDPDR — device redirection (drives). Static VC; client joins
     * when any RedirectDrives/RedirectPrinters/etc. is set. */
    if (!freerdp_settings_set_bool(s, FreeRDP_RedirectDrives, TRUE)) return FALSE;
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
    atomic_init(&s->audio_last_sent_ts, 0);
    atomic_init(&s->audio_confirmed_ts, 0);
    atomic_init(&s->audio_confirmed_block, 0);
    atomic_init(&s->audio_have_confirm, 0);
    atomic_init(&s->audio_lag_log_ms, 0);
    atomic_init(&s->audio_short_floor_ms, 0);
    atomic_init(&s->audio_drift_ms, 0);
    s->audio_lag_head = 0;
    s->audio_lag_count = 0;
    s->audio_lag_bucket_t0 = 0;
    atomic_init(&s->cliprdr_ready, false);
    atomic_init(&s->cliprdr_outbound_request_id, 0);
    atomic_init(&s->outstanding_frames, 0);
    atomic_init(&s->last_ack_ms, now_ms());
    s->pointer_lock = OS_UNFAIR_LOCK_INIT;
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
        try_open_rdpdr(s);

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
    if (s->rdpdr) {
        (void)s->rdpdr->Stop(s->rdpdr);
        rdpdr_server_context_free(s->rdpdr);
        s->rdpdr = NULL;
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

/* Hybrid per-tile path: AVC420 over the video rects + Progressive over the
 * static rects, composed onto one surface under a single GFX frame. See the
 * header for the contract. */
int32_t macrdp_session_send_hybrid_frame(
    macrdp_session_t      s,
    int32_t               surface_id,
    const uint8_t        *annexb,
    size_t                annexb_bytes,
    int32_t               is_idr,
    int64_t               pts_us,
    const macrdp_rect16  *video_rects,
    int32_t               num_video_rects,
    const uint8_t        *bgra,
    int32_t               width,
    int32_t               height,
    int32_t               stride,
    const macrdp_rect16  *static_rects,
    int32_t               num_static_rects)
{
#if MACRDP_HAVE_FREERDP
    (void)is_idr;
    if (!s || !s->gfx || !s->gfx_caps_confirmed) return MACRDP_E_NOT_IMPLEMENTED;

    const BOOL haveAvc  = (annexb != NULL && annexb_bytes > 0 && num_video_rects > 0);
    const BOOL wantProg = (bgra != NULL && width > 0 && height > 0 && num_static_rects > 0);
    if (!haveAvc && !wantProg) return MACRDP_OK;   /* nothing to do */

    if (atomic_load(&s->outstanding_frames) >= s->max_outstanding_frames) {
        return MACRDP_E_FRAME_DROPPED;
    }

    /* Lazy surface (+ progressive context) creation on first frame. */
    if (!s->surface_created) {
        int32_t rc1 = macrdp_session_reset_graphics(s, s->desktop_width, s->desktop_height, 1);
        if (rc1 != MACRDP_OK) return rc1;
        int32_t rc2 = macrdp_session_create_surface(s, surface_id,
                                                    s->desktop_width, s->desktop_height);
        if (rc2 != MACRDP_OK) return rc2;
        int32_t rc3 = macrdp_session_map_surface_to_output(s, surface_id, 0, 0);
        if (rc3 != MACRDP_OK) return rc3;
    }

    /* ---- Build the AVC420 command (full-frame stream, region-limited blit). */
    RECTANGLE_16 *avcRects = NULL;
    RDPGFX_H264_QUANT_QUALITY *quants = NULL;
    RDPGFX_AVC420_BITMAP_STREAM avc420 = { 0 };
    RDPGFX_SURFACE_COMMAND avcCmd = { 0 };
    if (haveAvc) {
        avcRects = (RECTANGLE_16*)calloc((size_t)num_video_rects, sizeof(RECTANGLE_16));
        quants   = (RDPGFX_H264_QUANT_QUALITY*)calloc((size_t)num_video_rects,
                                                      sizeof(RDPGFX_H264_QUANT_QUALITY));
        if (!avcRects || !quants) { free(avcRects); free(quants); return MACRDP_E_INTERNAL; }
        BYTE qp  = (BYTE)((s->cfg.avc420_qp > 0) ? s->cfg.avc420_qp : 22);
        BYTE qv  = (BYTE)((s->cfg.avc420_quality_val > 0) ? s->cfg.avc420_quality_val : 100);
        for (int i = 0; i < num_video_rects; i++) {
            avcRects[i].left   = video_rects[i].left;
            avcRects[i].top    = video_rects[i].top;
            avcRects[i].right  = video_rects[i].right;
            avcRects[i].bottom = video_rects[i].bottom;
            quants[i].qp = qp; quants[i].r = 0; quants[i].p = 0; quants[i].qualityVal = qv;
        }
        avc420.meta.numRegionRects   = (UINT32)num_video_rects;
        avc420.meta.regionRects      = avcRects;
        avc420.meta.quantQualityVals = quants;
        avc420.length = (UINT32)annexb_bytes;
        avc420.data   = (BYTE*)annexb;

        avcCmd.surfaceId = (UINT32)surface_id;
        avcCmd.codecId   = RDPGFX_CODECID_AVC420;
        avcCmd.format    = PIXEL_FORMAT_BGRX32;
        avcCmd.left = 0; avcCmd.top = 0;
        avcCmd.right  = (UINT32)s->desktop_width;
        avcCmd.bottom = (UINT32)s->desktop_height;
        avcCmd.width  = (UINT32)s->desktop_width;
        avcCmd.height = (UINT32)s->desktop_height;
        avcCmd.length = (UINT32)annexb_bytes;
        avcCmd.data   = (BYTE*)annexb;
        avcCmd.extra  = &avc420;
    }

    /* ---- Build the Progressive command over the static region. */
    BYTE  *progData = NULL;
    UINT32 progLen  = 0;
    RDPGFX_SURFACE_COMMAND progCmd = { 0 };
    if (wantProg) {
        if (!s->progressive) {
            s->progressive = progressive_context_new(TRUE /* compressor */);
            if (s->progressive && !progressive_context_reset(s->progressive)) {
                progressive_context_free(s->progressive);
                s->progressive = NULL;
            }
        }
        if (s->progressive) {
            REGION16 region;
            region16_init(&region);
            BOOL regionOK = TRUE;
            for (int i = 0; i < num_static_rects; i++) {
                RECTANGLE_16 r = { static_rects[i].left, static_rects[i].top,
                                   static_rects[i].right, static_rects[i].bottom };
                if (!region16_union_rect(&region, &region, &r)) { regionOK = FALSE; break; }
            }
            if (regionOK) {
                int rc = progressive_compress(
                    s->progressive, bgra, (UINT32)(stride * height),
                    PIXEL_FORMAT_BGRX32, (UINT32)width, (UINT32)height,
                    (UINT32)stride, &region, &progData, &progLen);
                if (rc < 0) { progData = NULL; progLen = 0; }
            }
            region16_uninit(&region);
        }
        if (progData && progLen > 0) {
            progCmd.surfaceId = (UINT32)surface_id;
            progCmd.codecId   = RDPGFX_CODECID_CAPROGRESSIVE;
            progCmd.format    = PIXEL_FORMAT_BGRX32;
            progCmd.left = 0; progCmd.top = 0;
            progCmd.right  = (UINT32)width;
            progCmd.bottom = (UINT32)height;
            progCmd.width  = (UINT32)width;
            progCmd.height = (UINT32)height;
            progCmd.length = progLen;
            progCmd.data   = progData;
            progCmd.extra  = NULL;
        }
    }

    const BOOL emitAvc  = haveAvc;
    const BOOL emitProg = (progData && progLen > 0);
    if (!emitAvc && !emitProg) {
        free(avcRects); free(quants);
        return MACRDP_OK;   /* progressive found no change and no video tiles */
    }

    /* ---- One frame, up to two surface commands. */
    UINT32 frameId = s->next_frame_id++;
    RDPGFX_START_FRAME_PDU start = { 0 };
    start.frameId   = frameId;
    start.timestamp = (UINT32)(pts_us / 1000);
    RDPGFX_END_FRAME_PDU end = { 0 };
    end.frameId = frameId;

    UINT rc = s->gfx->StartFrame(s->gfx, &start);
    if (rc == CHANNEL_RC_OK && emitAvc)  rc = s->gfx->SurfaceCommand(s->gfx, &avcCmd);
    if (rc == CHANNEL_RC_OK && emitProg) rc = s->gfx->SurfaceCommand(s->gfx, &progCmd);
    if (rc == CHANNEL_RC_OK)             rc = s->gfx->EndFrame(s->gfx, &end);

    free(avcRects);
    free(quants);

    if (rc == CHANNEL_RC_OK) {
        atomic_fetch_add(&s->outstanding_frames, 1);
        return MACRDP_OK;
    }
    return MACRDP_E_INTERNAL;
#else
    (void)s; (void)surface_id; (void)annexb; (void)annexb_bytes; (void)is_idr;
    (void)pts_us; (void)video_rects; (void)num_video_rects; (void)bgra;
    (void)width; (void)height; (void)stride; (void)static_rects; (void)num_static_rects;
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

/* -------- hardware cursor (RDP pointer channel) ------------------- */

#if MACRDP_HAVE_FREERDP
static rdpPointerUpdate *bridge_pointer(macrdp_session_t s) {
    if (!s || !s->peer || !s->peer->context || !s->peer->context->update) return NULL;
    return s->peer->context->update->pointer;
}

/* Fill RDP bottom-up xor (32bpp BGRA) + 1-bpp and masks from a top-down BGRA
 * source. AND bit = 1 (transparent) where alpha == 0. `and_out` must be
 * pre-zeroed. */
static void bridge_fill_pointer_masks(int w, int h, const uint8_t *bgra_topdown,
                                      uint8_t *xor_out, int xor_stride,
                                      uint8_t *and_out, int and_stride) {
    for (int dstRow = 0; dstRow < h; dstRow++) {
        const uint8_t *src = bgra_topdown + (size_t)(h - 1 - dstRow) * (size_t)w * 4;
        uint8_t *xrow = xor_out + (size_t)dstRow * xor_stride;
        uint8_t *arow = and_out + (size_t)dstRow * and_stride;
        for (int x = 0; x < w; x++) {
            uint8_t b = src[x * 4 + 0], g = src[x * 4 + 1];
            uint8_t r = src[x * 4 + 2], a = src[x * 4 + 3];
            xrow[x * 4 + 0] = b; xrow[x * 4 + 1] = g;
            xrow[x * 4 + 2] = r; xrow[x * 4 + 3] = a;
            if (a == 0) arow[x >> 3] |= (uint8_t)(0x80 >> (x & 7));
        }
    }
}
#endif

int32_t macrdp_session_send_pointer_position(macrdp_session_t s, int32_t x, int32_t y) {
#if MACRDP_HAVE_FREERDP
    rdpPointerUpdate *p = bridge_pointer(s);
    if (!p || !p->PointerPosition) return MACRDP_E_NOT_IMPLEMENTED;
    POINTER_POSITION_UPDATE pos = { 0 };
    pos.xPos = (UINT32)(x < 0 ? 0 : x);
    pos.yPos = (UINT32)(y < 0 ? 0 : y);
    os_unfair_lock_lock(&s->pointer_lock);
    BOOL ok = p->PointerPosition(s->peer->context, &pos);
    os_unfair_lock_unlock(&s->pointer_lock);
    return ok ? MACRDP_OK : MACRDP_E_INTERNAL;
#else
    (void)s; (void)x; (void)y;
    return MACRDP_E_NOT_IMPLEMENTED;
#endif
}

int32_t macrdp_session_send_pointer_hidden(macrdp_session_t s) {
#if MACRDP_HAVE_FREERDP
    rdpPointerUpdate *p = bridge_pointer(s);
    if (!p || !p->PointerSystem) return MACRDP_E_NOT_IMPLEMENTED;
    POINTER_SYSTEM_UPDATE sys = { 0 };
    sys.type = SYSPTR_NULL;
    os_unfair_lock_lock(&s->pointer_lock);
    BOOL ok = p->PointerSystem(s->peer->context, &sys);
    os_unfair_lock_unlock(&s->pointer_lock);
    return ok ? MACRDP_OK : MACRDP_E_INTERNAL;
#else
    (void)s;
    return MACRDP_E_NOT_IMPLEMENTED;
#endif
}

int32_t macrdp_session_send_pointer_shape(macrdp_session_t s,
                                          int32_t width, int32_t height,
                                          int32_t hot_x, int32_t hot_y,
                                          const uint8_t *bgra,
                                          int32_t allow_large)
{
#if MACRDP_HAVE_FREERDP
    rdpPointerUpdate *p = bridge_pointer(s);
    if (!p || !bgra || width <= 0 || height <= 0) return MACRDP_E_NOT_IMPLEMENTED;

    int W = width, H = height, HX = hot_x, HY = hot_y;
    const uint8_t *src = bgra;
    uint8_t *scaled = NULL;

    int useLarge = (W > 96 || H > 96);
    /* Too big and large pointers not allowed → nearest-neighbour downsample. */
    if (useLarge && !allow_large) {
        int maxdim = (W > H) ? W : H;
        int factor = (maxdim + 95) / 96;
        if (factor < 1) factor = 1;
        int nW = W / factor, nH = H / factor;
        if (nW < 1) nW = 1;
        if (nH < 1) nH = 1;
        scaled = (uint8_t*)malloc((size_t)nW * nH * 4);
        if (!scaled) return MACRDP_E_INTERNAL;
        for (int yy = 0; yy < nH; yy++) {
            for (int xx = 0; xx < nW; xx++) {
                const uint8_t *sp = bgra + ((size_t)(yy * factor) * W + (xx * factor)) * 4;
                uint8_t *dp = scaled + ((size_t)yy * nW + xx) * 4;
                dp[0] = sp[0]; dp[1] = sp[1]; dp[2] = sp[2]; dp[3] = sp[3];
            }
        }
        src = scaled; W = nW; H = nH; HX = hot_x / factor; HY = hot_y / factor;
        useLarge = 0;
    }

    int xor_stride = W * 4;
    int and_bytes  = (W + 7) / 8;
    int and_stride = (and_bytes + 1) & ~1;          /* 2-byte aligned */
    size_t xorLen = (size_t)xor_stride * H;
    size_t andLen = (size_t)and_stride * H;
    uint8_t *xorM = (uint8_t*)malloc(xorLen);
    uint8_t *andM = (uint8_t*)calloc(1, andLen);
    if (!xorM || !andM) { free(xorM); free(andM); free(scaled); return MACRDP_E_INTERNAL; }
    bridge_fill_pointer_masks(W, H, src, xorM, xor_stride, andM, and_stride);

    BOOL ok = FALSE;
    os_unfair_lock_lock(&s->pointer_lock);
    if (useLarge && p->PointerLarge) {
        POINTER_LARGE_UPDATE pl = { 0 };
        pl.xorBpp = 32; pl.cacheIndex = 0;
        pl.hotSpotX = (UINT16)HX; pl.hotSpotY = (UINT16)HY;
        pl.width = (UINT16)W; pl.height = (UINT16)H;
        pl.lengthAndMask = (UINT32)andLen; pl.lengthXorMask = (UINT32)xorLen;
        pl.xorMaskData = xorM; pl.andMaskData = andM;
        ok = p->PointerLarge(s->peer->context, &pl);
    } else if (p->PointerNew) {
        POINTER_NEW_UPDATE pn = { 0 };
        pn.xorBpp = 32;
        pn.colorPtrAttr.cacheIndex = 0;
        pn.colorPtrAttr.hotSpotX = (UINT16)HX; pn.colorPtrAttr.hotSpotY = (UINT16)HY;
        pn.colorPtrAttr.width = (UINT16)W; pn.colorPtrAttr.height = (UINT16)H;
        pn.colorPtrAttr.lengthAndMask = (UINT16)andLen;
        pn.colorPtrAttr.lengthXorMask = (UINT16)xorLen;
        pn.colorPtrAttr.xorMaskData = xorM; pn.colorPtrAttr.andMaskData = andM;
        ok = p->PointerNew(s->peer->context, &pn);
    }
    os_unfair_lock_unlock(&s->pointer_lock);

    free(xorM); free(andM); free(scaled);
    return ok ? MACRDP_OK : MACRDP_E_INTERNAL;
#else
    (void)s; (void)width; (void)height; (void)hot_x; (void)hot_y; (void)bgra; (void)allow_large;
    return MACRDP_E_NOT_IMPLEMENTED;
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
    /* Bound buffered latency: skip if the client has fallen too far behind. */
    if (rdpsnd_should_drop(s, wTimestamp)) return MACRDP_E_FRAME_DROPPED;
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
    /* Bound buffered latency: skip if the client has fallen too far behind. */
    if (rdpsnd_should_drop(s, wTimestamp)) return MACRDP_E_FRAME_DROPPED;
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
    /* Back-compat shim: no clipDataID. */
    return macrdp_session_send_clip_file_contents_request_with_clipdata(
        s, sid, list_index, want_size, offset, length, 0, 0);
}

int32_t macrdp_session_send_clip_file_contents_request_with_clipdata(
    macrdp_session_t s,
    uint32_t sid,
    uint32_t list_index,
    int32_t  want_size,
    uint64_t offset,
    uint32_t length,
    int32_t  have_clipdata_id,
    uint32_t clipdata_id)
{
#if MACRDP_HAVE_FREERDP
    if (!s || !s->cliprdr || !atomic_load(&s->cliprdr_ready)) {
        return MACRDP_E_NOT_IMPLEMENTED;
    }
    CLIPRDR_FILE_CONTENTS_REQUEST req = { 0 };
    req.common.msgType  = CB_FILECONTENTS_REQUEST;
    /* PDU body is 28 bytes (streamId + listIndex + dwFlags +
     * nPositionLow + nPositionHigh + cbRequested + clipDataId). */
    req.common.dataLen   = 28;
    req.streamId         = sid;
    req.listIndex        = list_index;
    req.dwFlags          = want_size ? FILECONTENTS_SIZE : FILECONTENTS_RANGE;
    req.nPositionLow     = (UINT32)(offset & 0xFFFFFFFFu);
    req.nPositionHigh    = (UINT32)((offset >> 32) & 0xFFFFFFFFu);
    req.cbRequested      = length;
    req.haveClipDataId   = have_clipdata_id ? TRUE : FALSE;
    req.clipDataId       = clipdata_id;
    UINT rc = s->cliprdr->ServerFileContentsRequest(s->cliprdr, &req);
    return rc == CHANNEL_RC_OK ? MACRDP_OK : MACRDP_E_INTERNAL;
#else
    (void)s; (void)sid; (void)list_index; (void)want_size;
    (void)offset; (void)length; (void)have_clipdata_id; (void)clipdata_id;
    return MACRDP_E_NOT_IMPLEMENTED;
#endif
}

int32_t macrdp_session_send_clip_lock(macrdp_session_t s, uint32_t clipdata_id)
{
#if MACRDP_HAVE_FREERDP
    if (!s || !s->cliprdr || !atomic_load(&s->cliprdr_ready)) {
        return MACRDP_E_NOT_IMPLEMENTED;
    }
    CLIPRDR_LOCK_CLIPBOARD_DATA pdu = { 0 };
    pdu.common.msgType  = CB_LOCK_CLIPDATA;
    pdu.common.dataLen  = 4;
    pdu.clipDataId      = clipdata_id;
    UINT rc = s->cliprdr->ServerLockClipboardData(s->cliprdr, &pdu);
    return rc == CHANNEL_RC_OK ? MACRDP_OK : MACRDP_E_INTERNAL;
#else
    (void)s; (void)clipdata_id;
    return MACRDP_E_NOT_IMPLEMENTED;
#endif
}

int32_t macrdp_session_send_clip_unlock(macrdp_session_t s, uint32_t clipdata_id)
{
#if MACRDP_HAVE_FREERDP
    if (!s || !s->cliprdr || !atomic_load(&s->cliprdr_ready)) {
        return MACRDP_E_NOT_IMPLEMENTED;
    }
    CLIPRDR_UNLOCK_CLIPBOARD_DATA pdu = { 0 };
    pdu.common.msgType  = CB_UNLOCK_CLIPDATA;
    pdu.common.dataLen  = 4;
    pdu.clipDataId      = clipdata_id;
    UINT rc = s->cliprdr->ServerUnlockClipboardData(s->cliprdr, &pdu);
    return rc == CHANNEL_RC_OK ? MACRDP_OK : MACRDP_E_INTERNAL;
#else
    (void)s; (void)clipdata_id;
    return MACRDP_E_NOT_IMPLEMENTED;
#endif
}

/* -------- RDPDR drive I/O (server → client IRPs) ------------------ */

#if MACRDP_HAVE_FREERDP
#  define RDPDR_TOKEN(t) ((void*)(uintptr_t)(t))
#  define RDPDR_GUARD(s)  if (!(s) || !(s)->rdpdr) return MACRDP_E_NOT_IMPLEMENTED
#  define RDPDR_RET(rc)   return ((rc) == CHANNEL_RC_OK ? MACRDP_OK : MACRDP_E_INTERNAL)
#endif

int32_t macrdp_session_rdpdr_query_dir(macrdp_session_t s, uint64_t token,
                                       uint32_t device_id, const char *path) {
#if MACRDP_HAVE_FREERDP
    RDPDR_GUARD(s);
    RDPDR_RET(s->rdpdr->DriveQueryDirectory(s->rdpdr, RDPDR_TOKEN(token), device_id, path));
#else
    (void)s;(void)token;(void)device_id;(void)path; return MACRDP_E_NOT_IMPLEMENTED;
#endif
}

int32_t macrdp_session_rdpdr_open_file(macrdp_session_t s, uint64_t token,
                                       uint32_t device_id, const char *path,
                                       uint32_t desired_access,
                                       uint32_t create_disposition) {
#if MACRDP_HAVE_FREERDP
    RDPDR_GUARD(s);
    RDPDR_RET(s->rdpdr->DriveOpenFile(s->rdpdr, RDPDR_TOKEN(token), device_id, path,
                                      desired_access, create_disposition));
#else
    (void)s;(void)token;(void)device_id;(void)path;
    (void)desired_access;(void)create_disposition; return MACRDP_E_NOT_IMPLEMENTED;
#endif
}

int32_t macrdp_session_rdpdr_read_file(macrdp_session_t s, uint64_t token,
                                       uint32_t device_id, uint32_t file_id,
                                       uint32_t length, uint32_t offset) {
#if MACRDP_HAVE_FREERDP
    RDPDR_GUARD(s);
    RDPDR_RET(s->rdpdr->DriveReadFile(s->rdpdr, RDPDR_TOKEN(token), device_id,
                                      file_id, length, offset));
#else
    (void)s;(void)token;(void)device_id;(void)file_id;
    (void)length;(void)offset; return MACRDP_E_NOT_IMPLEMENTED;
#endif
}

int32_t macrdp_session_rdpdr_write_file(macrdp_session_t s, uint64_t token,
                                        uint32_t device_id, uint32_t file_id,
                                        const uint8_t *buffer, uint32_t length,
                                        uint32_t offset) {
#if MACRDP_HAVE_FREERDP
    RDPDR_GUARD(s);
    RDPDR_RET(s->rdpdr->DriveWriteFile(s->rdpdr, RDPDR_TOKEN(token), device_id, file_id,
                                       (const char*)buffer, length, offset));
#else
    (void)s;(void)token;(void)device_id;(void)file_id;
    (void)buffer;(void)length;(void)offset; return MACRDP_E_NOT_IMPLEMENTED;
#endif
}

int32_t macrdp_session_rdpdr_close_file(macrdp_session_t s, uint64_t token,
                                        uint32_t device_id, uint32_t file_id) {
#if MACRDP_HAVE_FREERDP
    RDPDR_GUARD(s);
    RDPDR_RET(s->rdpdr->DriveCloseFile(s->rdpdr, RDPDR_TOKEN(token), device_id, file_id));
#else
    (void)s;(void)token;(void)device_id;(void)file_id; return MACRDP_E_NOT_IMPLEMENTED;
#endif
}

int32_t macrdp_session_rdpdr_create_dir(macrdp_session_t s, uint64_t token,
                                        uint32_t device_id, const char *path) {
#if MACRDP_HAVE_FREERDP
    RDPDR_GUARD(s);
    RDPDR_RET(s->rdpdr->DriveCreateDirectory(s->rdpdr, RDPDR_TOKEN(token), device_id, path));
#else
    (void)s;(void)token;(void)device_id;(void)path; return MACRDP_E_NOT_IMPLEMENTED;
#endif
}

int32_t macrdp_session_rdpdr_delete_file(macrdp_session_t s, uint64_t token,
                                         uint32_t device_id, const char *path) {
#if MACRDP_HAVE_FREERDP
    RDPDR_GUARD(s);
    RDPDR_RET(s->rdpdr->DriveDeleteFile(s->rdpdr, RDPDR_TOKEN(token), device_id, path));
#else
    (void)s;(void)token;(void)device_id;(void)path; return MACRDP_E_NOT_IMPLEMENTED;
#endif
}

int32_t macrdp_session_rdpdr_delete_dir(macrdp_session_t s, uint64_t token,
                                        uint32_t device_id, const char *path) {
#if MACRDP_HAVE_FREERDP
    RDPDR_GUARD(s);
    RDPDR_RET(s->rdpdr->DriveDeleteDirectory(s->rdpdr, RDPDR_TOKEN(token), device_id, path));
#else
    (void)s;(void)token;(void)device_id;(void)path; return MACRDP_E_NOT_IMPLEMENTED;
#endif
}

int32_t macrdp_session_rdpdr_rename_file(macrdp_session_t s, uint64_t token,
                                         uint32_t device_id, const char *old_path,
                                         const char *new_path) {
#if MACRDP_HAVE_FREERDP
    RDPDR_GUARD(s);
    RDPDR_RET(s->rdpdr->DriveRenameFile(s->rdpdr, RDPDR_TOKEN(token), device_id,
                                        old_path, new_path));
#else
    (void)s;(void)token;(void)device_id;(void)old_path;(void)new_path;
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
