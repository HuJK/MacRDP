#!/usr/bin/env bash
#
# win-client.sh — drive a Windows RDP client (mstsc) over SSH, so MacRDP can
# be tested against the real Microsoft client. Pairs with scripts/tart-vm.sh.
#
#   ./scripts/win-client.sh setup               # copy scripts/win/*.ps1 to the client
#   ./scripts/win-client.sh connect [host]      # mstsc -> host (default: the Tart VM), wait for it
#   ./scripts/win-client.sh disconnect          # close mstsc
#   ./scripts/win-client.sh windows             # titled windows on the client desktop
#   ./scripts/win-client.sh screenshot <png>    # the client's desktop
#   ./scripts/win-client.sh mstsc-shot <png>    # just the mstsc window (PrintWindow)
#   ./scripts/win-client.sh input '<json>'      # mouse/keys into mstsc (scripts/win/input.ps1)
#   ./scripts/win-client.sh clip '<json>'       # read/write the clipboard (scripts/win/clip.ps1)
#   ./scripts/win-client.sh put <local> <dir>   # upload into macrdp-test\<dir>
#   ./scripts/win-client.sh paste <dir> [secs]  # Explorer + Ctrl+V into <dir> (scripts/win/explorer-paste.ps1)
#   ./scripts/win-client.sh build <file.cs>     # compile a C# tool there (csc, C# 5)
#   ./scripts/win-client.sh fetch <remote> <local>  # copy from the client's macrdp-test dir
#   ./scripts/win-client.sh ps <powershell...>  # run PowerShell over SSH
#   ./scripts/win-client.sh cleanup             # forget saved mstsc logins
#
# The client must keep a user logged on at its console, left alone while
# tests run: GUI programs started over SSH land in a session without a
# desktop, so helpers run there through an interactive scheduled task
# (scripts/win/session-run.ps1), and Windows client SKUs allow only one
# interactive session, so logging on elsewhere kicks it.
#
# Environment:
#   WIN            ssh target (default hujkconsole@192.168.168.41)
#   RDP_USER       MacRDP login (default admin, the Tart VM's user)
#   RDP_PASSWORD   (default admin)
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WIN="${WIN:-hujkconsole@192.168.168.41}"
RDP_USER="${RDP_USER:-admin}"
RDP_PASSWORD="${RDP_PASSWORD:-admin}"
RDIR='macrdp-test'                       # scp path, relative to the user's profile
PSDIR='$env:USERPROFILE\macrdp-test'     # the same, as PowerShell sees it

die() { echo "error: $*" >&2; exit 1; }
# PowerShell over SSH exits non-zero whenever its last command set $? to
# false, even with -ErrorAction SilentlyContinue; append `; exit 0` there.
ps() { ssh -o BatchMode=yes -o ConnectTimeout=10 "$WIN" "$@"; }
put() { scp -q -o BatchMode=yes "$@" "$WIN:$RDIR/"; }
get() { scp -q -o BatchMode=yes "$WIN:$RDIR/$1" "$2"; }

# Run scripts/win/<name> inside the desktop session and wait for it
# (up to $2 seconds, default 60).
desktop() {
  ps "powershell -NoProfile -ExecutionPolicy Bypass -File \"$PSDIR\\session-run.ps1\" \"$PSDIR\\$1\" -TimeoutSec ${2:-60}" >/dev/null
}

# Hand <script>.ps1 its <script>.json, run it in the desktop session and
# print the <script>.txt it leaves behind.
run_json() { # <script.ps1> <json> [timeout]
  local name tmp; name="$(basename "$1" .ps1)"; tmp="$(mktemp -d)"
  printf '%s' "$2" > "$tmp/$name.json"; put "$tmp/$name.json"; rm -rf "$tmp"
  desktop "$1" "${3:-60}"
  ps "Get-Content \"$PSDIR\\$name.txt\""
}

windows() { desktop windows.ps1 && ps "Get-Content \"$PSDIR\\windows.txt\""; }

press() { run_json press.ps1 "$1" | grep -q '^pressed'; }

connected() { windows | grep -qF -- "$1 - Remote Desktop Connection"; }

cmd_setup() {
  ps "New-Item -ItemType Directory -Force \"$PSDIR\\tools\" | Out-Null"
  put "$REPO_ROOT"/scripts/win/*.ps1
}

cmd_connect() {
  local host="${1:-$("$REPO_ROOT/scripts/tart-vm.sh" ip)}" i tmp
  if connected "$host"; then echo "mstsc already connected to $host"; return; fi
  ps "Get-Process mstsc -ErrorAction SilentlyContinue | Stop-Process -Force; exit 0"
  tmp="$(mktemp -d)"
  printf '{"host":"%s","user":"%s","password":"%s"}' "$host" "$RDP_USER" "$RDP_PASSWORD" > "$tmp/connect.json"
  put "$tmp/connect.json"; rm -rf "$tmp"
  desktop connect.ps1
  for i in $(seq 1 20); do
    sleep 2
    # mstsc warns about every unsigned .rdp file before connecting.
    press '{"process": "mstsc", "button": "Connect"}' && echo "pressed Connect"
    connected "$host" && { echo "mstsc connected to $host"; return; }
  done
  die "mstsc did not connect to $host"
}

cmd_build() {
  local src="$1" name; name="$(basename "$src" .cs)"
  scp -q -o BatchMode=yes "$src" "$WIN:$RDIR/tools/"
  ps "& C:\\Windows\\Microsoft.NET\\Framework64\\v4.0.30319\\csc.exe /nologo /optimize /out:\"$PSDIR\\tools\\$name.exe\" \"$PSDIR\\tools\\$name.cs\"; exit \$LASTEXITCODE"
}

sub="${1:-}"; shift || true
case "$sub" in
  setup)      cmd_setup ;;
  connect)    cmd_connect "$@" ;;
  disconnect) ps "Get-Process mstsc -ErrorAction SilentlyContinue | Stop-Process -Force; exit 0" ;;
  windows)    windows ;;
  screenshot) [[ -n "${1:-}" ]] || die "usage: $0 screenshot <png>"; desktop shot.ps1; get shot.png "$1"; echo "$1" ;;
  mstsc-shot) [[ -n "${1:-}" ]] || die "usage: $0 mstsc-shot <png>"
              desktop winshot.ps1; ps "Get-Content \"$PSDIR\\winshot.txt\""; get mstsc.png "$1"; echo "$1" ;;
  input)      run_json input.ps1 "${1:?json}" ;;
  clip)       run_json clip.ps1 "${1:?json}" 240 ;;
  paste)      run_json explorer-paste.ps1 "{\"dir\": \"${1:?dir}\", \"timeout\": ${2:-120}}" $(( ${2:-120} + 60 )) ;;
  put)        [[ $# -eq 2 ]] || die "usage: $0 put <local> <dir>"
              ps "New-Item -ItemType Directory -Force \"$PSDIR\\$2\" | Out-Null"
              scp -q -r -o BatchMode=yes "$1" "$WIN:$RDIR/$2/" ;;
  build)      [[ -n "${1:-}" ]] || die "usage: $0 build <file.cs>"; cmd_build "$1" ;;
  fetch)      [[ $# -eq 2 ]] || die "usage: $0 fetch <remote> <local>"; get "$1" "$2" ;;
  ps)         ps "$@" ;;
  cleanup)    desktop cleanup.ps1; ps "Get-Content \"$PSDIR\\cleanup.txt\""
              ps "Get-ScheduledTask -TaskName 'MacRDPTest-*' -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:\$false" ;;
  *)          sed -n '3,32p' "$0"; exit 1 ;;
esac
