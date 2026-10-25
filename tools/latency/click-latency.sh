#!/usr/bin/env bash
#
# click-latency.sh — click-to-photon latency through MacRDP and mstsc, end to
# end, timed on the Windows client's clock alone.
#
# `guestcheck flash` (in the Tart VM) shows a grey screen whose centre square
# flips black/white on every mouse-down; ClickLatency (on the client) clicks
# the square through mstsc and times how long until the client's screen
# changes there. Covers client input, network both ways, the Mac app
# redrawing, capture, encode, decode and compositing; not the monitor.
#
#   tools/latency/click-latency.sh [trials] [animate]    # default 40 trials
#
# animate jitters the square every frame, so the hybrid encoder sends it as
# H.264; without, it is a still tile that changes once (Progressive).
#
# Expects MacRDP running in the VM (scripts/tart-vm.sh up/deploy/start) and
# guestcheck installed there (scripts/tart-vm.sh tool tools/guestcheck/guestcheck.swift);
# connects mstsc full screen via scripts/win-client.sh if needed.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VMSH="$REPO_ROOT/scripts/tart-vm.sh"
WINSH="$REPO_ROOT/scripts/win-client.sh"
trials="${1:-40}" animate="${2:-}"
[[ -z "$animate" || "$animate" == animate ]] || { echo "usage: $0 [trials] [animate]" >&2; exit 2; }

"$WINSH" setup
"$WINSH" ps "if (-not (Test-Path \"\$HOME\\macrdp-test\\tools\\ClickLatency.exe\")) { exit 1 }" >/dev/null 2>&1 ||
  "$WINSH" build "$REPO_ROOT/tools/latency/ClickLatency.cs"
"$WINSH" connect >/dev/null

"$VMSH" exec sh -c "pkill -f 'guestcheck flash'; true"
"$VMSH" exec /usr/local/bin/guestcheck flash $((trials * 3 + 60)) $animate >/dev/null 2>&1 &
flash=$!
trap '"$VMSH" exec sh -c "pkill -f \"guestcheck flash\"; true"; wait $flash 2>/dev/null || true' EXIT
sleep 3   # window up, first frames through

# Mac screen size in points = mstsc's full-screen pixels (1:1 session).
read -r _ _ w h <<<"$("$VMSH" exec /usr/local/bin/guestcheck mouse)"
cx=$((w / 2)) cy=$((h / 2))
"$WINSH" click-latency "$trials" "$cx" "$cy" $((cx + 150)) "$cy"
