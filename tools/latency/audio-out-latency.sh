#!/usr/bin/env bash
#
# audio-out-latency.sh — measure Mac -> client audio latency end to end, over
# time, against the real Windows client.
#
# latbeep (in the Tart VM) plays timed 1 kHz bursts, by default over a
# continuous 440 Hz bed so the stream never goes quiet (latency that only
# builds during continuous playback needs that); MacRDP streams it over
# RDPSND; LoopbackOnsets (on the Windows client) timestamps when each burst
# comes out of mstsc. Both ends meet on the client's clock via a UDP clock
# exchange with latbeep, and analyze-audio.py lines the result up against
# MacRDP's own RDPSND lag estimate from its log.
#
# SELF=1 is the control: LoopbackOnsets plays the same signal itself on the
# client and measures it through the same capture point, with no Mac or RDP
# involved. Stable locally but not over RDP points at the RDP path.
#
#   tools/latency/audio-out-latency.sh [seconds] [out-dir]    # default 120 s
#
# Expects MacRDP running in the VM (scripts/tart-vm.sh up/deploy/start);
# connects mstsc via scripts/win-client.sh if needed.
#
# Environment:
#   CAPTURE   capture endpoint to record, by friendly-name substring (e.g.
#             "CABLE Output" for VB-Cable); default: loopback of the default
#             render device
#   SELF=1    local self-play control run (no Mac, no RDP)
#   INTERVAL  seconds between bursts (default 2)
#   BED       amplitude of the continuous tone (default 0.1; 0 = silence)
#   PORT      latbeep's UDP clock port (default 47100)
# plus what tart-vm.sh and win-client.sh read.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VMSH="$REPO_ROOT/scripts/tart-vm.sh"
WINSH="$REPO_ROOT/scripts/win-client.sh"
DUR="${1:-120}"
SELF="${SELF:-0}"
OUT="${2:-${MACRDP_VM_ROOT:-/Volumes/DATA/tart}/runs/audio-$([[ $SELF == 1 ]] && echo self- )$(date +%Y%m%d-%H%M%S)}"
INTERVAL="${INTERVAL:-2}"
BED="${BED:-0.1}"
PORT="${PORT:-47100}"
WINDIR='$env:USERPROFILE\macrdp-test'

mkdir -p "$OUT"
"$WINSH" build "$REPO_ROOT/tools/latency/LoopbackOnsets.cs" >/dev/null
win_ps() { "$WINSH" ps "$@" | tr -d '\r'; }

opts="--interval $INTERVAL --bed $BED"
if [[ -n "${CAPTURE:-}" ]]; then
  # MMDevice IDs are the PnP instance ID minus its SWD\MMDEVAPI\ prefix.
  id="$(win_ps "(Get-PnpDevice -Class AudioEndpoint | Where-Object { \$_.Status -eq 'OK' -and \$_.FriendlyName -like '*$CAPTURE*' } |
    Select-Object -First 1).InstanceId" | sed 's/^SWD\\MMDEVAPI\\//' | tr 'A-F' 'a-f')"
  [[ -n "$id" ]] || { echo "error: no capture endpoint like '$CAPTURE'" >&2; exit 1; }
  opts="$opts --capture '$id'"   # quoted: PowerShell reads bare {...} as a script block
fi

if [[ "$SELF" == 1 ]]; then
  echo "==> ${DUR}s local self-play control, bursts every ${INTERVAL}s, bed $BED -> $OUT"
  win_ps "& \"$WINDIR\\tools\\LoopbackOnsets.exe\" --self-play $DUR \"$WINDIR\\runs\\audio\" $opts" | tee "$OUT/client.txt"
  "$WINSH" fetch 'runs/audio/beeps.csv' "$OUT/beeps.csv"
else
  "$VMSH" tool "$REPO_ROOT/tools/latency/latbeep.swift" >/dev/null
  "$WINSH" connect
  ip="$("$VMSH" ip)"
  "$VMSH" exec date +%z > "$OUT/vm-tz"
  echo "==> ${DUR}s run, bursts every ${INTERVAL}s, bed $BED -> $OUT"
  "$VMSH" exec /usr/local/bin/latbeep --interval "$INTERVAL" --duration $((DUR + 8)) \
    --port "$PORT" --bed "$BED" > "$OUT/beeps.csv" 2> "$OUT/latbeep.log" &
  beeper=$!
  sleep 1
  win_ps "& \"$WINDIR\\tools\\LoopbackOnsets.exe\" $ip $PORT $DUR \"$WINDIR\\runs\\audio\" $opts" | tee "$OUT/client.txt"
  wait "$beeper"
  "$WINSH" fetch 'runs/audio/sync.csv' "$OUT/sync.csv"
  "$VMSH" logs $((DUR + 60)) > "$OUT/macrdp.log"
fi
"$WINSH" fetch 'runs/audio/onsets.csv' "$OUT/onsets.csv"

# Name the endpoints involved: the capture (or loopback) device, and for
# self-play the render device, which is the default one mstsc plays to too.
for dev in $(sed -n 's/^[a-z-]* \({[^}]*}\.{[^}]*}\).*/\1/p' "$OUT/client.txt"); do
  echo "$dev = $(win_ps "(Get-PnpDevice -Class AudioEndpoint | Where-Object InstanceId -like '*$dev*').FriendlyName")"
done | tee -a "$OUT/client.txt"
python3 -I "$REPO_ROOT/tools/latency/analyze-audio.py" "$OUT" | tee "$OUT/summary.txt"
