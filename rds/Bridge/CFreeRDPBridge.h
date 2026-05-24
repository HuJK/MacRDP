/*
 *  CFreeRDPBridge.h
 *  MacRDP
 *
 *  C-callable surface that wraps libfreerdp-server. The bridge owns a
 *  freerdp_peer, drives its event loop on a dedicated thread, and
 *  invokes Swift-supplied callbacks for every interesting event.
 *
 *  In Phase 0b every function below is a stub that returns
 *  -MACRDP_E_NOT_IMPLEMENTED. Phase 0c+ replaces the stubs with real
 *  FreeRDP calls.
 *
 *  Header conventions:
 *    - opaque session handles (macrdp_session_t) — Swift never peeks inside
 *    - all callbacks take a void* ctx that Swift sets to an
 *      Unmanaged<SwiftSession>.toOpaque()
 *    - all pointer parameters are non-owning (the caller frees)
 *    - all integer returns: 0 on success, negative MACRDP_E_* on failure
 */

#ifndef CFREERDP_BRIDGE_H
#define CFREERDP_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#if defined(__cplusplus)
extern "C" {
#endif

/* -------- error codes ---------------------------------------------- */

#define MACRDP_OK                       0
#define MACRDP_E_INVALID_ARG          (-1)
#define MACRDP_E_NOT_IMPLEMENTED      (-2)
#define MACRDP_E_FREERDP_UNAVAILABLE  (-3)
#define MACRDP_E_PEER_INIT            (-4)
#define MACRDP_E_NLA_FAILED           (-5)
#define MACRDP_E_TLS_FAILED           (-6)
#define MACRDP_E_DISCONNECTED         (-7)
#define MACRDP_E_FRAME_DROPPED        (-8)   /* flow-controlled, not fatal */
#define MACRDP_E_INTERNAL             (-99)

/* -------- monitor layout ------------------------------------------- */

/* Raw RDP-side monitor entry. The Swift side decorates this with a
 * CGDirectDisplayID drawn from its DisplayMapping. */
typedef struct macrdp_raw_monitor {
    int32_t  rdp_slot;
    int32_t  x;
    int32_t  y;
    int32_t  width;
    int32_t  height;
    int32_t  refresh_hz;
    int32_t  orientation;             /* 0/90/180/270 */
    int32_t  scale_x100;              /* DesktopScaleFactor as percent */
    int32_t  device_scale_x100;       /* DeviceScaleFactor as percent  */
    int32_t  physical_width_mm;       /* 0 if unknown */
    int32_t  physical_height_mm;
    int32_t  is_primary;              /* 0/1 */
} macrdp_raw_monitor;

/* -------- callbacks ------------------------------------------------ */

/* Audio redirection mode the client requested. */
#define MACRDP_AUDIO_MODE_NONE       0  /* "Do not play" — client never asked for audio */
#define MACRDP_AUDIO_MODE_REMOTE     1  /* "Play on remote computer" — let Mac speakers play */
#define MACRDP_AUDIO_MODE_REDIRECTED 2  /* "Play on this computer" — capture + send via RDPSND */

/* Audio format chosen at RDPSND activation. */
#define MACRDP_AUDIO_FORMAT_PCM      0
#define MACRDP_AUDIO_FORMAT_AAC      1

/* Connection lifecycle */
typedef void (*macrdp_on_activated_fn)(
    void *ctx,
    int32_t  desktop_width,
    int32_t  desktop_height,
    int32_t  color_depth_bpp,
    int32_t  client_connection_type,  /* TS_UD_CS_CORE.connectionType */
    int32_t  audio_mode               /* MACRDP_AUDIO_MODE_* */
);

typedef void (*macrdp_on_closed_fn)(void *ctx, int32_t reason);

/* Display visibility (client minimized / minimized to tray / window hidden). */
typedef void (*macrdp_on_suppress_output_fn)(
    void *ctx, int32_t allow_updates);

/* Input PDUs (Phase 2) */
typedef void (*macrdp_on_input_mouse_fn)(
    void *ctx, uint16_t flags, int32_t x, int32_t y);

typedef void (*macrdp_on_input_keyboard_fn)(
    void *ctx, uint16_t flags, uint16_t scancode);

typedef void (*macrdp_on_input_unicode_fn)(
    void *ctx, uint16_t flags, uint16_t code);

/* DISP channel (Phase 3) */
typedef void (*macrdp_on_disp_monitor_layout_fn)(
    void *ctx,
    const macrdp_raw_monitor *monitors,
    int32_t monitor_count);

/* GFX flow-control (Phase 1) */
typedef void (*macrdp_on_frame_acknowledge_fn)(
    void *ctx, uint32_t frame_id);

/* CLIPRDR (Phase 6+7) */
/* Each format entry: numeric id + optional UTF-8 name (NULL for stock
 * Windows formats like CF_UNICODETEXT). */
typedef struct macrdp_clip_format {
    uint32_t    id;
    const char *name;            /* nullable, UTF-8, NUL-terminated */
} macrdp_clip_format;

typedef void (*macrdp_on_clip_format_list_fn)(
    void *ctx, const macrdp_clip_format *formats, int32_t count);

typedef void (*macrdp_on_clip_data_request_fn)(
    void *ctx, uint32_t format_id);

typedef void (*macrdp_on_clip_data_response_fn)(
    void *ctx, uint32_t format_id, const uint8_t *data, size_t len);

/* Fired once the CLIPRDR capability handshake + MonitorReady completes.
 * Until this is true, sending a format list is racy. */
typedef void (*macrdp_on_clip_ready_fn)(void *ctx);

/* Client's response to a prior CB_FORMAT_LIST. success=0 indicates
 * CB_RESPONSE_FAIL — typically transient (Office polling Windows
 * clipboard). Swift uses this to schedule a retry. */
typedef void (*macrdp_on_clip_format_list_response_fn)(
    void *ctx, int32_t success);

typedef void (*macrdp_on_clip_file_contents_request_fn)(
    void *ctx,
    uint32_t stream_id,
    uint32_t list_index,
    int32_t  want_size,        /* 0 = want data, 1 = want size */
    uint64_t offset,
    uint32_t length);

typedef void (*macrdp_on_clip_file_contents_response_fn)(
    void *ctx,
    uint32_t stream_id,
    const uint8_t *data,
    size_t len);

/* RDPDR static VC (Phase 5 drive sharing) — fires once per
 * Win→Mac redirected drive announce. `dos_name` is up to 8 ASCII
 * characters (e.g. "C", "D", "MyShare"); `device_type` is the
 * RDPDR_DTYP_* numeric constant (8 == FILESYSTEM, 4 == PRINT, …).
 *
 * Phase 1 just logs; later phases will mount the drive as a
 * FileProvider domain and route reads through the same XPC
 * channel the clipboard uses. */
typedef void (*macrdp_on_rdpdr_device_added_fn)(
    void *ctx,
    uint32_t  device_id,
    uint32_t  device_type,
    const char *dos_name);     /* NUL-terminated, ASCII */

typedef void (*macrdp_on_rdpdr_device_removed_fn)(
    void *ctx,
    uint32_t  device_id);

/* RDPDR drive I/O completions. Every request carries a `token` chosen by
 * Swift; the matching completion echoes it back so the caller can wake
 * the right pending request. All fire on the FreeRDP channel thread.
 *
 * Directory enumeration streams: one query yields N entry callbacks
 * (is_entry=1, fields valid), terminated by one with is_entry=0 (no
 * fields; io_status carries the terminal status, e.g. STATUS_NO_MORE_FILES). */
typedef void (*macrdp_on_rdpdr_dir_entry_fn)(
    void *ctx, uint64_t token, int32_t is_entry, uint32_t io_status,
    const char *name,            /* UTF-8; valid only when is_entry */
    uint32_t file_attributes,
    uint64_t size,
    int64_t  mtime_unix_ms);

typedef void (*macrdp_on_rdpdr_open_complete_fn)(
    void *ctx, uint64_t token, uint32_t io_status,
    uint32_t device_id, uint32_t file_id);

typedef void (*macrdp_on_rdpdr_read_complete_fn)(
    void *ctx, uint64_t token, uint32_t io_status,
    const uint8_t *buffer, uint32_t length);

typedef void (*macrdp_on_rdpdr_write_complete_fn)(
    void *ctx, uint64_t token, uint32_t io_status, uint32_t bytes_written);

/* close / create-dir / delete / rename all just report an io_status. */
typedef void (*macrdp_on_rdpdr_status_complete_fn)(
    void *ctx, uint64_t token, uint32_t io_status);

/* AUDIN dynamic VC (Phase 5) */
typedef void (*macrdp_on_audio_in_frame_fn)(
    void *ctx,
    const uint8_t *pcm_le16,
    size_t bytes,
    int32_t sample_rate,
    int32_t channels);

/* Fired once RDPSND format negotiation completes and we know whether
 * the client wants PCM or AAC. Swift uses this to decide whether to
 * engage AVAudioConverter for AAC encoding. */
typedef void (*macrdp_on_audio_format_selected_fn)(
    void *ctx, int32_t format /* MACRDP_AUDIO_FORMAT_* */);

/* Aggregate */
typedef struct macrdp_callbacks {
    macrdp_on_activated_fn                       on_activated;
    macrdp_on_closed_fn                          on_closed;
    macrdp_on_input_mouse_fn                     on_input_mouse;
    macrdp_on_input_keyboard_fn                  on_input_keyboard;
    macrdp_on_input_unicode_fn                   on_input_unicode;
    macrdp_on_disp_monitor_layout_fn             on_disp_monitor_layout;
    macrdp_on_frame_acknowledge_fn               on_frame_acknowledge;
    macrdp_on_clip_format_list_fn                on_clip_format_list;
    macrdp_on_clip_data_request_fn               on_clip_data_request;
    macrdp_on_clip_data_response_fn              on_clip_data_response;
    macrdp_on_clip_ready_fn                      on_clip_ready;
    macrdp_on_clip_format_list_response_fn       on_clip_format_list_response;
    macrdp_on_clip_file_contents_request_fn      on_clip_file_contents_request;
    macrdp_on_clip_file_contents_response_fn     on_clip_file_contents_response;
    macrdp_on_audio_in_frame_fn                  on_audio_in_frame;
    macrdp_on_suppress_output_fn                 on_suppress_output;
    macrdp_on_audio_format_selected_fn           on_audio_format_selected;
    macrdp_on_rdpdr_device_added_fn              on_rdpdr_device_added;
    macrdp_on_rdpdr_device_removed_fn            on_rdpdr_device_removed;
    macrdp_on_rdpdr_dir_entry_fn                 on_rdpdr_dir_entry;
    macrdp_on_rdpdr_open_complete_fn             on_rdpdr_open_complete;
    macrdp_on_rdpdr_read_complete_fn             on_rdpdr_read_complete;
    macrdp_on_rdpdr_write_complete_fn            on_rdpdr_write_complete;
    macrdp_on_rdpdr_status_complete_fn           on_rdpdr_close_complete;
    macrdp_on_rdpdr_status_complete_fn           on_rdpdr_simple_complete;
} macrdp_callbacks;

/* -------- session lifecycle --------------------------------------- */

typedef struct macrdp_session* macrdp_session_t;

typedef struct macrdp_session_config {
    /* TLS */
    const char *tls_cert_pem_path;     /* nullable: bridge auto-generates */
    const char *tls_key_pem_path;
    int32_t     require_nla;           /* 0/1 */

    /* H.264 / GFX defaults */
    int32_t     default_bitrate_kbps;
    int32_t     default_max_fps;
    int32_t     prefer_avc444;         /* 0/1 */

    /* GFX flow control: max in-flight frames before send_h264_frame
     * returns MACRDP_E_FRAME_DROPPED. */
    int32_t     max_outstanding_frames;
    /* AVC420 metablock quant hint (per-frame; QoE only — VT drives encoder). */
    int32_t     avc420_qp;
    int32_t     avc420_quality_val;

    /* Channel enables */
    int32_t     enable_audio_out;      /* 0/1 */
    int32_t     enable_audio_in;       /* 0/1 */
    int32_t     enable_clipboard;      /* 0/1 */
    int32_t     enable_disp;           /* 0/1 */
    int32_t     enable_rdpdr;          /* 0/1 — drive redirection */
} macrdp_session_config;

/* Create a session for an already-accepted file descriptor. The bridge
 * takes ownership of the fd. */
int32_t macrdp_session_create(
    int                            fd,
    void                          *swift_ctx,
    const macrdp_callbacks        *cbs,
    const macrdp_session_config   *cfg,
    macrdp_session_t              *out_session);

/* Drives the freerdp_peer event loop. Returns when the peer is
 * disconnected or an error occurs. Safe to call on a dedicated thread. */
int32_t macrdp_session_run(macrdp_session_t session);

/* Request the bridge to stop the event loop. Idempotent. */
void macrdp_session_request_stop(macrdp_session_t session);

/* Destroy. Must be called after macrdp_session_run returns. */
void macrdp_session_destroy(macrdp_session_t session);

/* -------- output (Swift -> client via FreeRDP) -------------------- */

/* Phase 1 — push an Annex-B H.264 frame to RDPGFX. SPS/PPS prepended
 * by Swift on every IDR. */
int32_t macrdp_session_send_h264_frame(
    macrdp_session_t session,
    int32_t          surface_id,
    const uint8_t   *annexb,
    size_t           bytes,
    int32_t          is_idr,
    int64_t          pts_microseconds);

/* Alternative path: hand FreeRDP a raw BGRA frame; it runs RemoteFX
 * Progressive V2 (CPU codec, tile-based, automatic damage detection)
 * and sends with codecId=RDPGFX_CODECID_CAPROGRESSIVE_V2. */
int32_t macrdp_session_send_progressive_frame(
    macrdp_session_t session,
    int32_t          surface_id,
    const uint8_t   *bgra,
    int32_t          width,
    int32_t          height,
    int32_t          stride);

/* Returns the number of frames in flight (sent but unacked). Swift checks
 * this before encoding to apply backpressure at the encoder input. */
int32_t macrdp_session_outstanding_frames(macrdp_session_t session);

/* Override the desktop size the bridge uses for RESETGRAPHICS /
 * CreateSurface / MapSurfaceToOutput. Call before the first
 * send_*_frame so the surface is created at the right dimensions.
 * Use this when the captured display has a different aspect ratio
 * than the client's negotiated desktop. */
void macrdp_session_set_desktop_size(macrdp_session_t session,
                                     int32_t width, int32_t height);

/* Phase 1 — surface lifecycle */
int32_t macrdp_session_reset_graphics(
    macrdp_session_t session,
    int32_t          width,
    int32_t          height,
    int32_t          monitor_count);

int32_t macrdp_session_create_surface(
    macrdp_session_t session,
    int32_t          surface_id,
    int32_t          width,
    int32_t          height);

int32_t macrdp_session_map_surface_to_output(
    macrdp_session_t session,
    int32_t          surface_id,
    int32_t          output_origin_x,
    int32_t          output_origin_y);

/* Phase 4 — push PCM (Int16LE stereo @ 48k) to RDPSND.
 * Only valid when mstsc selected WAVE_FORMAT_PCM (the on_audio_format_selected
 * callback fired with MACRDP_AUDIO_FORMAT_PCM). */
int32_t macrdp_session_send_audio_pcm(
    macrdp_session_t session,
    const uint8_t   *pcm_le16,
    size_t           bytes);

/* Phase 4 — push a single AAC packet (already MPEG-4 AAC encoded) to
 * RDPSND via Wave2 PDU. Only valid when MACRDP_AUDIO_FORMAT_AAC was
 * selected. `pcm_sample_count` is the number of PCM samples this
 * packet represents (e.g., 1024 for AAC-LC) — used for the Wave2 PDU
 * audioTimeStamp. */
int32_t macrdp_session_send_audio_aac(
    macrdp_session_t session,
    const uint8_t   *aac,
    size_t           bytes,
    uint32_t         pcm_sample_count);

/* Phase 6/7 — clipboard outbound */
int32_t macrdp_session_send_clip_format_list(
    macrdp_session_t           session,
    const macrdp_clip_format  *formats,
    int32_t                    count);

int32_t macrdp_session_send_clip_data_response(
    macrdp_session_t session,
    uint32_t         format_id,
    const uint8_t   *data,
    size_t           len);

/* Mac app pasting from RDP clipboard → ask client for the bytes. */
int32_t macrdp_session_send_clip_data_request(
    macrdp_session_t session,
    uint32_t         format_id);

int32_t macrdp_session_send_clip_file_contents_response(
    macrdp_session_t session,
    uint32_t         stream_id,
    int32_t          success,        /* 1 OK, 0 FAIL */
    const uint8_t   *data,
    size_t           len);

/* Win→Mac: ask the client for a chunk of file bytes (or a file size).
 * `want_size` 1 means "just give me the 8-byte size at offset 0".
 * On success, the client returns via on_clip_file_contents_response. */
int32_t macrdp_session_send_clip_file_contents_request(
    macrdp_session_t session,
    uint32_t         stream_id,
    uint32_t         list_index,
    int32_t          want_size,
    uint64_t         offset,
    uint32_t         length);

/* Same as above but stamps the PDU with a `clipDataId` so the client
 * routes the fetch to a specific (lock-pinned) clipboard snapshot
 * rather than its current FGDW. Used for concurrent paste sessions. */
int32_t macrdp_session_send_clip_file_contents_request_with_clipdata(
    macrdp_session_t session,
    uint32_t         stream_id,
    uint32_t         list_index,
    int32_t          want_size,
    uint64_t         offset,
    uint32_t         length,
    int32_t          have_clipdata_id,
    uint32_t         clipdata_id);

/* Tell the client to preserve the current clipboard snapshot under
 * `clipdata_id` even after a future FORMAT_LIST replaces it.
 * Negotiated via canLockClipData = TRUE in the server capability set. */
int32_t macrdp_session_send_clip_lock(macrdp_session_t session,
                                       uint32_t        clipdata_id);

/* Tell the client we no longer need the snapshot — it can free it. */
int32_t macrdp_session_send_clip_unlock(macrdp_session_t session,
                                         uint32_t        clipdata_id);

/* -------- RDPDR drive I/O (server → client IRPs) ------------------ */
/* Each takes a Swift-chosen `token` echoed back on the matching
 * completion callback. `path` is a backslash-rooted Windows path
 * relative to the drive root (e.g. "\\Users\\me\\file.txt", or "\\"
 * + "*" pattern for a directory listing). Return MACRDP_OK if the IRP
 * was enqueued. */
int32_t macrdp_session_rdpdr_query_dir(macrdp_session_t s, uint64_t token,
                                       uint32_t device_id, const char *path);
int32_t macrdp_session_rdpdr_open_file(macrdp_session_t s, uint64_t token,
                                       uint32_t device_id, const char *path,
                                       uint32_t desired_access,
                                       uint32_t create_disposition);
int32_t macrdp_session_rdpdr_read_file(macrdp_session_t s, uint64_t token,
                                       uint32_t device_id, uint32_t file_id,
                                       uint32_t length, uint32_t offset);
int32_t macrdp_session_rdpdr_write_file(macrdp_session_t s, uint64_t token,
                                        uint32_t device_id, uint32_t file_id,
                                        const uint8_t *buffer, uint32_t length,
                                        uint32_t offset);
int32_t macrdp_session_rdpdr_close_file(macrdp_session_t s, uint64_t token,
                                        uint32_t device_id, uint32_t file_id);
int32_t macrdp_session_rdpdr_create_dir(macrdp_session_t s, uint64_t token,
                                        uint32_t device_id, const char *path);
int32_t macrdp_session_rdpdr_delete_file(macrdp_session_t s, uint64_t token,
                                         uint32_t device_id, const char *path);
int32_t macrdp_session_rdpdr_delete_dir(macrdp_session_t s, uint64_t token,
                                        uint32_t device_id, const char *path);
int32_t macrdp_session_rdpdr_rename_file(macrdp_session_t s, uint64_t token,
                                         uint32_t device_id, const char *old_path,
                                         const char *new_path);

/* -------- versioning ---------------------------------------------- */

const char *macrdp_bridge_version(void);
const char *macrdp_bridge_freerdp_version(void);

#if defined(__cplusplus)
}
#endif

#endif /* CFREERDP_BRIDGE_H */
