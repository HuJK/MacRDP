# MacRDP

A native **RDP _server_ for macOS** — turn a Mac into a remote desktop host that any
standard RDP client (Windows `mstsc`, FreeRDP, Microsoft Remote Desktop, etc.) can
connect into. It is built on FreeRDP's server-side libraries and uses Apple-native
frameworks (ScreenCaptureKit, VideoToolbox, Core Audio) for hardware-accelerated
screen capture, encoding, and audio.

> **Status: early / work-in-progress.** Interfaces, config schema, and on-disk
> formats are still changing. Not yet hardened for production or hostile networks —
> see [Security](#security).

---

## Features

- **Hardware-accelerated video** over the RDP Graphics Pipeline (`RDPGFX`):
  - H.264 (AVC420 / AVC444) via the VideoToolbox hardware encoder, or
  - RemoteFX Progressive V2 (CPU, wavelet, great for sparse desktop changes).
- **Adaptive quality** — per-link profiles (`lan` / `broadband` / `modem`),
  client connection-type hints, and runtime bandwidth autodetect.
- **Multi-monitor** capture with explicit or auto RDP-slot ↔ display bindings.
- **Audio out** — system audio capture (Core Audio process tap) streamed via
  `RDPSND`, AAC or PCM, with optional local-speaker muting while tapped.
- **Audio in** — client microphone (`AUDIN`) played into a chosen Mac output device.
- **Clipboard** (`CLIPRDR`) — bidirectional text, image, and **file** transfer.
  Windows→Mac file copies are surfaced in Finder through a File Provider extension.
- **Input injection** — keyboard and mouse (including scroll-wheel mapping) via
  the Accessibility / CGEvent APIs.
- **Dynamic resize** (`DISP`) — client resolution changes can run a configurable
  hook command to switch the Mac's display mode.
- **NLA authentication** (NTLM) and auto-generated self-signed TLS certificates.

## Architecture

Two Xcode targets in one project:

| Target          | Kind                              | Role |
| --------------- | --------------------------------- | ---- |
| `rds`           | Background macOS app (`.accessory`) | The RDP server. Owns the socket listener, FreeRDP peer event loops, and all capture/encode/input pipelines. |
| `fileprovider`  | File Provider extension           | Read-only `NSFileProviderReplicatedExtension` that exposes clipboard / redirected files in Finder. Talks to the host over XPC. |

The two share an App Group (`group.com.mac-rdp.rds`) and a small set of duplicated
model files (`SharedManifest.swift`, `FileProviderXPCProtocol.swift`).

FreeRDP itself is vendored as a **git submodule** (`ThirdParty/FreeRDP`, pinned to
release `3.26.0`) and built as static server libraries by
[`scripts/vendor-freerdp.sh`](scripts/vendor-freerdp.sh) — only the server channels
MacRDP needs are enabled; the client, X11/Wayland, and most extra codecs are
disabled.

```
rds/
  AppDelegate.swift          # @main: permission gate, listener bootstrap, signals
  CLI/                       # arg parsing + JSON config model
  Bridge/                    # C ↔ Swift FreeRDP bridge
  Server/                    # listener, per-peer session, and the pipelines:
                             #   Display, AudioOut, AudioIn, Clipboard, InputInjector,
                             #   DisplayControl, CredentialStore, TLS, Permissions, …
  Shared/                    # models shared with the extension
fileprovider/                # File Provider extension
scripts/
  vendor-freerdp.sh          # build FreeRDP server libs into ThirdParty/FreeRDP-install
  bundle-dylibs.sh           # Xcode build phase: copy runtime dylibs into the .app
ThirdParty/FreeRDP/          # submodule (source of truth)
ThirdParty/FreeRDP-build/    # generated build tree   (git-ignored)
ThirdParty/FreeRDP-install/  # generated libs/headers (git-ignored)
```

## Requirements

- **macOS 26+** on **Apple Silicon (arm64)**.
- **Xcode** (with command-line tools).
- Homebrew build dependencies for FreeRDP:
  ```sh
  brew install cmake ninja openssl@3 pkg-config
  ```

## Building

```sh
# 1. Clone with the FreeRDP submodule
git clone <repo-url> MacRDP
cd MacRDP
git submodule update --init --recursive

# 2. Build the FreeRDP server static libs (one-time; re-run after submodule bumps)
./scripts/vendor-freerdp.sh build
#    -> produces ThirdParty/FreeRDP-install/{include,lib}

# 3. Build & run the app target `rds` in Xcode
open MacRDP.xcodeproj
```

`ThirdParty/FreeRDP-build/` and `ThirdParty/FreeRDP-install/` are generated artifacts
and are intentionally **not** committed — regenerate them with the script above.

## Running

`rds` is a background daemon (no Dock icon). On first launch it probes the macOS TCC
permissions it needs and shows a prompt for anything missing; granting them once
avoids mid-session dialogs:

- **Screen Recording** — screen capture (ScreenCaptureKit).
- **Accessibility** — keyboard/mouse injection.
- **System Audio Recording** — audio-out capture (when enabled).

Command-line options (also `rds --help`):

```
rds [options]
  -c, --config <path>   Config JSON (default: search ~/Library/Application Support/MacRDP/, /etc/)
      --host <addr>     Listen address (default 0.0.0.0)
      --port <n>        Listen port    (default 3389)
  -v, --verbose         Verbose logging
  rds exercise --help   Standalone smoke tests (no RDP client needed)
```

## Configuration

Config is JSON, loaded from the first of:

1. `--config <path>`
2. `~/Library/Application Support/MacRDP/config.json`
3. `/etc/macrdp.json`

If none exist, built-in defaults are used. The schema covers `listen`, `auth`,
`video`, `display`, `input`, `audioOut`, `audioIn`, and `clipboard` — see
[`rds/CLI/Config.swift`](rds/CLI/Config.swift) for every field and its default.

### Authentication & credentials

NLA validates clients against NT-hashes stored in a credentials file
(default `~/Library/Application Support/MacRDP/credentials.json`, or
`auth.credentialsFile`):

```json
{ "users": [
    { "username": "alice", "domain": "MACRDP", "ntlmHash": "<32-hex-chars>" }
] }
```

Generate an NT-hash from a password:

```sh
printf '%s' 'MyPassword' | iconv -t UTF-16LE | openssl dgst -md4
```

The TLS certificate is self-signed and auto-generated on first run (configurable via
`auth.certificateFile` / `auth.privateKeyFile`).

## Security

- Credentials are currently stored as **plaintext NT-hashes on disk** (Keychain
  backing is a planned improvement). Protect `credentials.json` accordingly.
- The TLS certificate is **self-signed**, so clients will see a trust prompt.
- This is early software and **has not been security-audited** — run it on trusted
  networks only, and do not expose port 3389 directly to the internet.
- `.gitignore` is configured to keep secrets (`credentials.json`, keys, certs,
  `.env`, signing material) out of the repo. Don't commit them.

## License

MacRDP is licensed under the **GNU General Public License v3.0** — see
[`LICENSE`](LICENSE).

It links **FreeRDP**, which is licensed under the Apache License 2.0 (GPLv3-compatible).
