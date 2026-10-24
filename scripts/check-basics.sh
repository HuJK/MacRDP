#!/usr/bin/env bash
#
# check-basics.sh — end-to-end regression checks between the Windows mstsc
# client and MacRDP in the Tart VM. Each check prints PASS or FAIL.
#
#   ./scripts/check-basics.sh               # all checks
#   ./scripts/check-basics.sh display mouse # a subset
#
# Checks:
#   display   mstsc's picture vs the Mac's screen (PSNR, colour bars) and liveness
#   keyboard  scancode typing          unicode   TS_UNICODE_EVENT typing
#   mouse     move/click mapping       wheel     scroll direction and size
#   cursor    pointer shapes reach the client
#   resize    dynamic resolution: DISP layouts from FreeRDP's client in the
#             VM (brew install freerdp), then mstsc window sizes (known to
#             fail: mstsc sends MacRDP no layouts, reported as XFAIL)
#   text image files   clipboard, both directions (files mac->win: XFAIL on the
#             LTSC test client, whose mstsc pastes no server files at all;
#             files win->mac needs MacRDP's File Provider on)
#   mic       client microphone: tone bursts played into VB-Cable on Windows
#             come out of the Mac's "MacRDP Microphone" at the right pitch
#             and spacing (needs MacRDP's audio driver in the VM:
#             ./scripts/tart-vm.sh audio-driver)
#   camera    client webcam: VCamSample's test pattern on the client (scripts/win/
#             vcam.ps1) streams over RDPECAM into MacRDP's camera view, and
#             into the Mac camera "… (MacRDP)" (virtual camera extension
#             approved; GuestCheck.app, from `tart-vm.sh tool`, needs camera
#             access once)
#   nla       nthash login policy over NLA: right password in, wrong one out
#             (restarts MacRDP with a temporary config, then restores it)
#
# The input and display checks run against `guestcheck sink`, a full-screen
# test pattern in the VM that logs what it receives. Artifacts (captures)
# go to $OUT (default $MACRDP_VM_ROOT/runs/basics-<time>).
#
# Expects MacRDP running in the VM (scripts/tart-vm.sh up/deploy/start) and
# opens a fresh mstsc session (scripts/win-client.sh), full screen by default.
# Needs `guestcheck` in the VM: ./scripts/tart-vm.sh tool tools/guestcheck/guestcheck.swift
#
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VMSH="$REPO_ROOT/scripts/tart-vm.sh"
WINSH="$REPO_ROOT/scripts/win-client.sh"
WINDIR='$env:USERPROFILE\macrdp-test'
CHECKS=("$@"); [[ ${#CHECKS[@]} -gt 0 ]] ||
  CHECKS=(display keyboard unicode mouse wheel cursor resize text image files mic camera nla)
OUT="${OUT:-${MACRDP_VM_ROOT:-/Volumes/DATA/tart}/runs/basics-$(date +%Y%m%d-%H%M%S)}"
IMGCMP="${MACRDP_VM_ROOT:-/Volumes/DATA/tart}/build/bin/imgcmp"
mkdir -p "$OUT"
failures=0

vm() { "$VMSH" exec "$@"; }
win() { "$WINSH" "$@"; }
result() { # <name> <ok> <detail>
  if [[ "$2" == 1 ]]; then echo "PASS  $1  $3"; else echo "FAIL  $1  $3"; failures=$((failures + 1)); fi
}
# A check for a known, still open bug: XFAIL doesn't count as a failure,
# XPASS means the bug is gone and the check should become a result().
known() { # <name> <ok> <detail>
  if [[ "$2" == 1 ]]; then echo "XPASS $1  $3"; else echo "XFAIL $1  $3"; fi
}
# Clipboard ownership travels as a format list; give it a moment to land.
settle() { sleep 2; }

# "relative/path|size|sha256" lines for every file under a VM directory.
vm_manifest() {
  vm sh -c "cd '$1' && find . -type f | sed 's|^\./||' | sort | while read -r f; do
    printf '%s|%s|%s\n' \"\$f\" \"\$(stat -f %z \"\$f\")\" \"\$(shasum -a 256 \"\$f\" | cut -d' ' -f1)\"; done"
}

check_text() {
  local s="MacRDP clipboard 剪貼簿 ✓ $RANDOM" got want
  want="$(printf %s "$s" | shasum -a 256 | cut -d' ' -f1)"

  win clip "{\"op\": \"set-text\", \"text\": \"$s\"}" >/dev/null; settle
  got="$(vm /usr/local/bin/guestcheck clip-text-get 2>&1)"
  [[ "$(printf %s "$got" | shasum -a 256 | cut -d' ' -f1)" == "$want" ]] && ok=1 || ok=0
  result "text win->mac" $ok "got: $got"

  vm /usr/local/bin/guestcheck clip-text-set "$s"; settle
  got="$(win clip '{"op": "get-text"}' | head -1 | tr -d '\r\357\273\277')"
  [[ "$got" == "utf8-sha256=$want" ]] && ok=1 || ok=0
  result "text mac->win" $ok "$got"
}

check_image() {
  local got
  win ps "Add-Type -AssemblyName System.Drawing; \$b = New-Object Drawing.Bitmap 320,200
    for (\$x = 0; \$x -lt 320; \$x++) { for (\$y = 0; \$y -lt 200; \$y += 4) { \$b.SetPixel(\$x, \$y, [Drawing.Color]::FromArgb(\$x % 256, \$y, 128)) } }
    New-Item -ItemType Directory -Force \"$WINDIR\\clip\" | Out-Null; \$b.Save(\"$WINDIR\\clip\\win-img.png\")"
  win clip "{\"op\": \"set-image\", \"path\": \"C:\\\\Users\\\\hujkconsole\\\\macrdp-test\\\\clip\\\\win-img.png\"}" >/dev/null; settle
  got="$(vm /usr/local/bin/guestcheck clip-image-get /tmp/win-img.png 2>&1)"
  [[ "$got" == "320x200" ]] && ok=1 || ok=0
  result "image win->mac" $ok "got: $got"

  vm sh -c '/usr/sbin/screencapture -x -R0,0,320,200 /tmp/mac-img.png && /usr/local/bin/guestcheck clip-image-set /tmp/mac-img.png'; settle
  got="$(win clip '{"op": "get-image", "path": "C:\\Users\\hujkconsole\\macrdp-test\\clip\\mac-img.png"}' | tr -d '\r\357\273\277')"
  [[ "$got" =~ ^[0-9]+x[0-9]+$ ]] && ok=1 || ok=0
  result "image mac->win" $ok "got: $got"
}

check_files() {
  local want got paths
  # Windows source: a text file, a 3 MiB binary, a folder with a nested binary.
  want="$(win ps "\$d = \"$WINDIR\\clipsrc\"; Remove-Item -Recurse -Force \$d -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force \"\$d\\folder\\sub\" | Out-Null
    [IO.File]::WriteAllText(\"\$d\\hello.txt\", 'hello from windows')
    \$r = New-Object byte[] 3145728; (New-Object Random 42).NextBytes(\$r); [IO.File]::WriteAllBytes(\"\$d\\blob.bin\", \$r)
    [IO.File]::WriteAllText(\"\$d\\folder\\a.txt\", 'a')
    \$r = New-Object byte[] 1048576; (New-Object Random 7).NextBytes(\$r); [IO.File]::WriteAllBytes(\"\$d\\folder\\sub\\b.bin\", \$r)
    Get-ChildItem \$d -Recurse -File | ForEach-Object { \"\$(\$_.FullName.Substring(\$d.Length + 1).Replace('\\', '/'))|\$(\$_.Length)|\$((Get-FileHash \$_.FullName).Hash.ToLower())\" } | Sort-Object" | tr -d '\r')"
  win clip '{"op": "set-files", "paths": ["C:\\Users\\hujkconsole\\macrdp-test\\clipsrc\\hello.txt", "C:\\Users\\hujkconsole\\macrdp-test\\clipsrc\\blob.bin", "C:\\Users\\hujkconsole\\macrdp-test\\clipsrc\\folder"]}' >/dev/null
  settle
  paths="$(vm /usr/local/bin/guestcheck clip-files-get 2>&1)"
  vm sh -c 'rm -rf /tmp/clipdst && mkdir -p /tmp/clipdst'
  # Lazy mode (the default fileFetchMode) puts one MacRDP_<id> folder on
  # the pasteboard and fetches the real items when it's read, so a Finder
  # paste lands them inside that folder; compare its contents. guestcheck
  # cp reads File Provider placeholders, which plain cp under tart exec
  # can't (EDEADLK).
  while IFS= read -r p; do
    case "$p" in
      */MacRDP_*) vm sh -c "rmdir /tmp/clipdst && /usr/local/bin/guestcheck cp '$p' /tmp/clipdst" 2>&1 | head -2 ;;
      ?*) vm /usr/local/bin/guestcheck cp "$p" "/tmp/clipdst/${p##*/}" 2>&1 | head -2 ;;
    esac
  done <<< "$paths"
  got="$(vm_manifest /tmp/clipdst)"
  [[ "$got" == "$want" ]] && ok=1 || ok=0
  # macOS creates the clipboard's File Provider domain disabled until the
  # user switches MacRDP on under System Settings > General > Login Items &
  # Extensions > File Providers (shown only once a visible domain exists,
  # clipboard.showInFinder); until then no URL ever reaches the pasteboard.
  [[ "$paths" == *"no file URLs"* ]] && paths+=" (MacRDP's File Provider switched off?)"
  result "files win->mac" $ok "$(echo "$got" | wc -l | tr -d ' ') files; pasteboard: $(echo "$paths" | tr '\n' ' ')"
  [[ $ok == 1 ]] || diff <(echo "$want") <(echo "$got") | sed 's/^/      /'

  # Mac source, same shape, in a fresh folder so the pasteboard always
  # changes; copied in Finder and pasted with Ctrl+V in Explorer, as a user
  # would (a tool writing several file URLs keeps only the first, and a
  # scripted Shell paste behaves differently from Explorer's).
  local src="/tmp/clipsrc-$RANDOM"
  vm sh -c "mkdir -p $src/mac-folder/sub && cd $src &&
    printf 'hello from mac' > mac-hello.txt && head -c 3145728 /dev/urandom > mac-blob.bin &&
    printf a > mac-folder/a.txt && head -c 1048576 /dev/urandom > mac-folder/sub/b.bin"
  want="$(vm_manifest "$src")"
  vm /usr/local/bin/guestcheck finder-copy "$src" >/dev/null
  settle
  win ps "Remove-Item -Recurse -Force \"$WINDIR\\clipdst\" -ErrorAction SilentlyContinue; exit 0"
  got="$(win paste 'C:\\Users\\hujkconsole\\macrdp-test\\clipdst' 180 |
    tr -d '\r\357\273\277' | sed 's|\\|/|g' | sort)"
  [[ "$got" == "$want" ]] && ok=1 || ok=0
  # Known to fail on this test client only: its mstsc (Windows 11 LTSC,
  # 10.0.26100.8875) fetches FileGroupDescriptorW, then its clipboard object
  # rejects FileContents for every lindex (DV_E_FORMATETC), so Explorer
  # pastes nothing. It does the same against xrdp; Mac->Windows file paste
  # works from a regular Windows client (checked by hand, 2026-10-25).
  known "files mac->win" $ok "$(echo "$got" | grep -c '|') files"
  [[ $ok == 1 ]] || diff <(echo "$want") <(echo "$got") | sed 's/^/      /'
}

# MARK: - Test pattern, geometry, input

SINK_LOG=/tmp/sink.log
SINK_LINES=0

# Start the full-screen pattern (if it isn't up) and give it focus.
start_sink() {
  if ! vm /usr/bin/pgrep -f "guestcheck sink" >/dev/null; then
    "$VMSH" exec /usr/local/bin/guestcheck sink 1800 "$SINK_LOG" >/dev/null 2>&1 &
    local i
    for i in $(seq 1 20); do
      vm /usr/bin/grep -q '"ready"' "$SINK_LOG" 2>/dev/null && break
      sleep 1
    done
  fi
  # A click in a quiet area makes the sink the key window, as a user would.
  input "{\"move\": [$(cx 0.6), $(cy 0.9)], \"click\": true}" >/dev/null
  sleep 1
}
stop_sink() { vm /usr/bin/pkill -f "guestcheck sink" >/dev/null 2>&1 || true; }

# Remember the end of the sink log; sink_events prints what came after.
mark() { SINK_LINES="$(vm sh -c "wc -l < $SINK_LOG" | tr -d ' ')"; }
sink_events() { vm /usr/bin/tail -n "+$((SINK_LINES + 1))" "$SINK_LOG"; }

# input.ps1 with a JSON request; prints its log (client geometry first).
input() { win input "$1" | tr -d '\r'; }

# mstsc's client size, refreshed by geometry(); client-pixel helpers for
# fractions of it.
CW=1920 CH=1080
geometry() {
  local g; g="$(input '{}' | sed -n 's/.*clientSize=\([0-9]*\)x\([0-9]*\).*/\1 \2/p')"
  CW="${g% *}" CH="${g#* }"
}
cx() { python3 -I -c "print(round($1 * $CW))"; }
cy() { python3 -I -c "print(round($1 * $CH))"; }

# The session size MacRDP last settled on ("Desktop size override → WxH").
session_size() {
  "$VMSH" logs "${1:-30}" | sed -n 's/.*Desktop size override → \([0-9]*x[0-9]*\).*/\1/p' | tail -1
}

# Compare mstsc's picture with the Mac's screen. Prints a detail string and
# returns non-zero on mismatch. The frame counter (top right) is skipped in
# the PSNR and used for liveness instead.
compare_display() { # <tag> [WxH: the session, when smaller than mstsc's client area]
  local tag="$1" a="$OUT/$1-client.png" b="$OUT/$1-client2.png" mac="$OUT/$1-mac.png" f
  win mstsc-shot "$a" >/dev/null
  "$VMSH" screenshot "$mac" >/dev/null
  sleep 1.2
  win mstsc-shot "$b" >/dev/null
  if [[ -n "${2:-}" && "$2" != "${CW}x${CH}" ]]; then
    for f in "$a" "$b"; do sips --cropToHeightWidth "${2#*x}" "${2%x*}" --cropOffset 0 0 "$f" >/dev/null; done
  fi
  local psnr live bad="" i
  psnr="$("$IMGCMP" psnr "$a" "$mac" --skip 0.875 0 1 0.15)"
  live="$("$IMGCMP" diff "$a" "$b" 0.875 0 1 0.15)"
  local want=("255 255 255" "255 255 0" "0 255 255" "0 255 0" "255 0 255" "255 0 0" "0 0 255" "0 0 0")
  for i in 0 1 2 3 4 5 6 7; do
    local got; got="$("$IMGCMP" mean "$a" "$(python3 -I -c "print($i/8+0.02)")" 0.2 "$(python3 -I -c "print(($i+1)/8-0.02)")" 0.45)"
    python3 -I -c "import sys; g=[int(v) for v in '$got'.split()]; w=[int(v) for v in '${want[$i]}'.split()]; sys.exit(max(abs(a-b) for a,b in zip(g,w))>40)" ||
      bad="$bad bar$i=($got)"
  done
  local p; p="$(sed 's/psnr=\([0-9.]*\).*/\1/' <<< "$psnr")"
  echo "$psnr counter-diff=$live${bad:+ wrong-colours:$bad}"
  python3 -I -c "import sys; sys.exit(not ($p >= 25 and $live > 1.0))" && [[ -z "$bad" ]]
}

# MARK: - Checks: display and input

check_display() {
  start_sink; geometry
  local d ok=1
  d="$(compare_display display)" || ok=0
  result "display ${CW}x${CH}" $ok "$d"
}

check_keyboard() {
  start_sink; geometry; mark
  local s='Hello, MacRDP 1234 !@#$%^&*()_+-=[]{};:,.<>/?`~|'
  input "$(python3 -I -c 'import json,sys; print(json.dumps({"text": sys.argv[1], "enter": True}))' "$s")" >/dev/null
  sleep 1
  local got; got="$(sink_events | python3 -I -c '
import json, sys
print("".join(e["chars"] for e in map(json.loads, sys.stdin) if e["type"] == "key"), end="")')"
  [[ "$got" == "$s"$'\r' ]] && ok=1 || ok=0
  result "keyboard" $ok "got: $(printf %q "$got")"
}

check_unicode() {
  start_sink; geometry; mark
  local s='中文測試✓é€'
  input "$(python3 -I -c 'import json,sys; print(json.dumps({"unicode": sys.argv[1]}))' "$s")" >/dev/null
  sleep 1
  local got; got="$(sink_events | python3 -I -c '
import json, sys
print("".join(e["chars"] for e in map(json.loads, sys.stdin) if e["type"] == "key"), end="")')"
  [[ "$got" == "$s" ]] && ok=1 || ok=0
  result "unicode" $ok "got: $got"
}

check_mouse() {
  start_sink; geometry; mark
  local pts="0.1,0.15 0.5,0.5 0.9,0.85" pt
  for pt in $pts; do
    input "{\"move\": [$(cx "${pt%,*}"), $(cy "${pt#*,}")], \"click\": true}" >/dev/null
  done
  input "{\"move\": [$(cx 0.3), $(cy 0.8)], \"rightClick\": true}" >/dev/null
  sleep 1
  local d ok=1
  d="$(sink_events | python3 -I -c '
import json, sys
mac_w, mac_h = 1920, 1080
want = [(0.1, 0.15, "left"), (0.5, 0.5, "left"), (0.9, 0.85, "left"), (0.3, 0.8, "right")]
got = [e for e in map(json.loads, sys.stdin) if e["type"] == "click"]
bad = len(got) != len(want)
out = []
for (fx, fy, b), e in zip(want, got):
    ex, ey = round(fx * mac_w), round(fy * mac_h)
    off = max(abs(e["x"] - ex), abs(e["y"] - ey))
    bad |= off > 4 or e["button"] != b
    x, y = e["x"], e["y"]
    out.append(f"{b}({x},{y})~({ex},{ey})")
print(" ".join(out) or "no clicks")
sys.exit(bad)')" || ok=0
  result "mouse" $ok "$d"
}

check_wheel() {
  start_sink; geometry
  input "{\"move\": [$(cx 0.6), $(cy 0.9)]}" >/dev/null
  mark; input '{"wheel": 1}' >/dev/null; sleep 1
  local up; up="$(sink_events | python3 -I -c 'import json,sys; print(sum(e["dy"] for e in map(json.loads, sys.stdin) if e["type"] == "scroll"))')"
  mark; input '{"wheel": -2}' >/dev/null; sleep 1
  local down; down="$(sink_events | python3 -I -c 'import json,sys; print(sum(e["dy"] for e in map(json.loads, sys.stdin) if e["type"] == "scroll"))')"
  # One notch is input.wheelPixelsPerNotch (50) pixels; down is twice as far, the other way.
  python3 -I -c "import sys; u,d=$up,$down; sys.exit(not (u*d < 0 and 25 <= abs(u) <= 100 and 1.5 <= abs(d/u) <= 2.5))" && ok=1 || ok=0
  result "wheel" $ok "1 notch up -> dy $up, 2 notches down -> dy $down"
}

check_cursor() {
  start_sink; geometry
  local spots="arrow:0.06,0.3 ibeam:0.15,0.625 hand:0.5,0.625 crosshair:0.85,0.625" s shapes="" seen=""
  for s in $spots; do
    local name="${s%%:*}" pt="${s#*:}" c
    c="$(input "{\"move\": [$(cx "${pt%,*}"), $(cy "${pt#*,}")], \"cursor\": true}" | sed -n 's/^cursor //p')"
    shapes="$shapes $name[$c]"
    seen="$seen $(sed -n 's/.*hash=\([0-9a-f]*\).*/\1/p' <<< "$c")"
  done
  local distinct; distinct="$(tr ' ' '\n' <<< "$seen" | sed '/^$/d' | sort -u | wc -l | tr -d ' ')"
  [[ "$distinct" == 4 ]] && ok=1 || ok=0
  result "cursor" $ok "$distinct distinct shapes:$shapes"
}

check_resize() {
  # MacRDP's side of DISP, with a client known to use it: FreeRDP sends its
  # window size as soon as our caps arrive, right as capture starts. The
  # session is the Mac's 16:9 fitted inside it, which it already is.
  win disconnect >/dev/null
  local log ok
  if ! vm test -x /opt/homebrew/bin/sdl-freerdp; then
    result "resize disp layout (freerdp)" 0 "no FreeRDP client in the VM: brew install freerdp"
  else
  vm sh -c '/opt/homebrew/bin/sdl-freerdp /v:127.0.0.1 /u:admin /p:admin /cert:ignore \
    /dynamic-resolution /size:1024x768 >/tmp/sdl-freerdp.log 2>&1 & sleep 12; pkill -f sdl-freerdp; true'
  log="$("$VMSH" logs 20)"
  ok=0
  grep -q "DISP: client requested 1 monitor(s), primary 1024x768" <<<"$log" &&
    ! grep -q "resize failed" <<<"$log" && ok=1
  result "resize disp layout (freerdp)" $ok \
    "$(grep -o 'DISP caps sent.*\|DISP: client requested.*\|resize failed.*' <<<"$log" | tr '\n' ';')"
  fi

  # mstsc, as a user drives it: a windowed session that is resized and
  # maximized. MacRDP keeps the Mac's 16:9 by fitting inside the size mstsc
  # asks for, so the session can be smaller than the window. mstsc gets the
  # same DISP caps but has never sent a layout (maximize stops at the
  # session size), hence known().
  if ! RDP_MODE=window RDP_SIZE=1280x720 win connect >/dev/null; then
    result "resize" 0 "windowed connect failed"; return
  fi
  sleep 2; start_sink
  local step d session fit
  for step in initial 1600x900 1000x700 maximize; do
    case "$step" in
      initial) ;;
      maximize) input '{"maximize": true}' >/dev/null ;;
      *) input "{\"resizeClient\": [${step%x*}, ${step#*x}]}" >/dev/null ;;
    esac
    sleep 4; geometry
    session="$(session_size "$([[ $step == initial ]] && echo 90 || echo 10)")"
    fit="$(python3 -I -c "w,h=$CW,$CH; s=min(w/1920,h/1080); print(f'{round(1920*s)}x{round(1080*s)}')")"
    ok=1
    [[ "$session" == "$fit" ]] || ok=0
    [[ $step != maximize || $CW -ge 1900 ]] || ok=0   # a maximized window fills the screen
    d="$(compare_display "resize-$step" "$session")" || ok=0
    if [[ $step == initial ]]; then
      result "resize $step" $ok "client ${CW}x${CH}, session ${session:-?} (expected $fit); $d"
    else
      known "resize $step" $ok "client ${CW}x${CH}, session ${session:-?} (expected $fit); $d"
    fi
  done
  # Back to the default full-screen session for the checks that follow.
  stop_sink; win disconnect >/dev/null; win connect >/dev/null
}

# MARK: - Check: microphone

check_mic() {
  # Windows plays LoopbackOnsets' bursts (1 kHz every 2 s) into VB-Cable's
  # "CABLE Input"; its "CABLE Output", made the default recording device,
  # is the mic mstsc redirects (connect.ps1 asks for audiocapturemode). A
  # fresh session picks the device up. MacRDP plays the mic into its own
  # driver's hidden feed device, and it comes out of "MacRDP Microphone",
  # recorded here the way a Mac app would.
  local res n bad
  win audio-default capture "CABLE Output" >/dev/null
  win ps "if (-not (Test-Path \"$WINDIR\\tools\\LoopbackOnsets.exe\")) { exit 1 }" ||
    win build "$REPO_ROOT/tools/latency/LoopbackOnsets.cs" >/dev/null
  win disconnect >/dev/null && win connect >/dev/null
  sleep 3
  "$VMSH" exec /usr/local/bin/guestcheck input-record "MacRDP Microphone" 20 /tmp/mic.raw >"$OUT/mic-record.txt" 2>&1 &
  local rec=$!
  sleep 2
  win ps "& \"$WINDIR\\tools\\LoopbackOnsets.exe\" --self-play 15 \"$WINDIR\\runs\\mic\"" >/dev/null
  wait $rec
  vm cat /tmp/mic.raw >"$OUT/mic.raw"
  res="$(python3 -I "$REPO_ROOT/tools/latency/burst-pitch.py" "$OUT/mic.raw" 48000 1000)"
  echo "$res" >"$OUT/mic-bursts.txt"
  # "burst at  4.380 s   1000.0 Hz  +96000 samples": the pitch within 5 Hz,
  # the spacing (after the first) within 1 ms of 2 s. Not the last burst:
  # stopping the player can cut it short.
  n="$(grep -c '^burst at' <<<"$res")"
  bad="$(grep '^burst at' <<<"$res" | sed '$d' |
    awk '{ if ($5 < 995 || $5 > 1005) b++
           if (NF >= 7) { d = substr($7, 2) + 0; if (d < 95952 || d > 96048) b++ } }
         END { print b + 0 }')"
  ok=0; [[ $n -ge 6 && $bad == 0 ]] && ok=1
  result "mic win->mac" $ok "$n bursts, $bad off; $(head -1 "$OUT/mic-record.txt")"
}

# MARK: - Check: camera

check_camera() {
  # mstsc offers every camera (connect.ps1: camerastoredirect); the client
  # runs VCamSample, a virtual camera drawing a test pattern. mstsc lists
  # cameras when it connects, so reconnect after making sure it runs.
  # Opening the camera from MacRDP's menu starts its RDPECAM stream into
  # the camera view, and the session log counts the samples.
  local vcam log fps t0
  vcam="$(win vcam | tr -d '\r')"
  [[ "$vcam" == running* ]] || { result "camera win->mac" 0 "no test webcam on the client: $vcam"; return; }
  win disconnect >/dev/null && win connect >/dev/null
  sleep 4
  t0=$(date +%s)
  if ! vm /usr/local/bin/guestcheck status-menu com.mac-rdp.rds "Windows Virtual Camera" >/dev/null; then
    result "camera win->mac" 0 "no client camera in MacRDP's menu"; return
  fi
  sleep 12
  log="$("$VMSH" logs $(( $(date +%s) - t0 + 3 )))"
  fps="$(sed -n 's/.*Camera [^:]*: \([0-9.]*\) fps.*/\1/p' <<<"$log" | tail -1)"
  ok=0
  [[ -n "$fps" ]] && ! grep -q "decoding failed" <<<"$log" &&
    awk -v f="$fps" 'BEGIN { exit !(f >= 10) }' && ok=1
  result "camera win->mac" $ok \
    "$(grep -o 'streaming H.264 [0-9x]*' <<<"$log" | tail -1), ${fps:-no} samples/s$(grep -q 'decoding failed' <<<"$log" && echo ', decoding failed')"

  # The same webcam as a Mac camera (the virtual camera extension): an app
  # opening it — GuestCheck.app, which needs camera access once — gets the
  # client's moving test pattern, not the still placeholder.
  local grab frames changed
  grab="$(vm sh -c 'rm -f /tmp/vcam.out; /usr/bin/open -W -n /Applications/GuestCheck.app \
    --stdout /tmp/vcam.out --stderr /tmp/vcam.out \
    --args camera-grab "Windows Virtual Camera" 8 /tmp/vcam.png; cat /tmp/vcam.out')"
  vm cat /tmp/vcam.png > "$OUT/vcam.png" 2>/dev/null
  frames="$(sed -n 's/.*: \([0-9]*\) frames in.*/\1/p' <<<"$grab")"
  changed="$(sed -n 's/.* \([0-9]*\)% changed.*/\1/p' <<<"$grab")"
  ok=0
  [[ ${frames:-0} -ge 40 && ${changed:-0} -ge 1 ]] && ok=1
  result "camera as Mac camera" $ok "$(tail -1 <<<"$grab")"
}

# MARK: - Check: NLA with the nthash policy

check_nla() {
  stop_sink
  local pw="Nla-$RANDOM-$RANDOM-x" hash cfg='$HOME/Library/Application Support/MacRDP/vm.yaml'
  hash="$(vm sh -c "printf '%s\n' '$pw' | /Applications/MacRDP.app/Contents/MacOS/MacRDP nthash" | tail -1)"
  vm sh -c "printf '\nauth:\n  passwordPolicy: nthash\n  ntHash: \"$hash\"\n' >> \"$cfg\""
  "$VMSH" start >/dev/null
  win disconnect >/dev/null

  local ok=0 proto t0
  t0=$(date +%s)
  RDP_PASSWORD="$pw" win connect >"$OUT/nla-connect.txt" 2>&1 && sleep 3 &&
    "$VMSH" logs $(( $(date +%s) - t0 + 5 )) | grep "Peer activated" >/dev/null && ok=1
  proto="$("$VMSH" wlog 5000 | sed -n 's/.*Server Security: \(.*\)/\1/p' | tail -1)"
  result "nla right password" $ok "server security: ${proto:-?}"

  win disconnect >/dev/null
  ok=1
  RDP_PASSWORD="wrong-$pw" win connect >/dev/null 2>&1 && ok=0
  result "nla wrong password" $ok "$([[ $ok == 1 ]] && echo rejected || echo 'logged in!')"

  # Back to the deployed config and the default login.
  win disconnect >/dev/null
  "$VMSH" deploy --no-build >/dev/null && "$VMSH" start >/dev/null
  win connect >/dev/null
}

# MARK: - Run

# A fresh session, not whatever mstsc was left in: a stalled one, or one
# whose server has since restarted (its title still names the host, so
# connect would take it as connected), fails every check after it.
"$WINSH" disconnect >/dev/null && "$WINSH" connect >/dev/null || exit 1
for c in "${CHECKS[@]}"; do
  case "$c" in text|image|files|nla) stop_sink ;; esac
  "check_$c"
done
stop_sink
echo "$failures failure(s); artifacts in $OUT"
exit $((failures > 0))
