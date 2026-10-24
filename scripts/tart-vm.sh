#!/usr/bin/env bash
#
# tart-vm.sh — run MacRDP inside a disposable Tart macOS VM, so capture,
# input injection, TCC and FileProvider can be exercised without touching
# the host's own session.
#
# A golden VM (macrdp-golden) is provisioned once from the cirruslabs Tahoe
# base image; every run works on an APFS clone of it (macrdp-dev), so each
# run starts from a known state in seconds.
#
#   ./scripts/tart-vm.sh golden [--fresh]  # provision golden (--fresh: re-clone from base image)
#   ./scripts/tart-vm.sh up                # new clone of golden, booted (GUI=1 for a window)
#   ./scripts/tart-vm.sh deploy [--no-build]  # build Debug MacRDP, install it + Config/vm.yaml
#   ./scripts/tart-vm.sh start             # (re)launch MacRDP in the guest's GUI session
#   ./scripts/tart-vm.sh stop              # quit MacRDP
#   ./scripts/tart-vm.sh logs [secs]       # MacRDP unified log: last N secs, or stream
#   ./scripts/tart-vm.sh wlog [lines]      # MacRDP stdout/stderr (FreeRDP WLog output)
#   ./scripts/tart-vm.sh screenshot <png>  # guest screen to a host file
#   ./scripts/tart-vm.sh alerts            # list open system alerts in the guest
#   ./scripts/tart-vm.sh exec <cmd...>     # run a command in the guest
#   ./scripts/tart-vm.sh tool <file.swift> # compile a helper, install it as /usr/local/bin/<name>
#   ./scripts/tart-vm.sh audio-driver      # build MacRDP's virtual microphone, install it, restart coreaudiod
#   ./scripts/tart-vm.sh grant-camera      # let GuestCheck.app use the camera (no prompts with AMFI off)
#   ./scripts/tart-vm.sh ip | down | destroy
#
# Environment:
#   MACRDP_VM_ROOT  where VMs, builds and Tart itself live (default /Volumes/DATA/tart)
#   TART_HOME       VM storage (default $MACRDP_VM_ROOT/home)
#   TART            tart binary (default: `tart` on PATH, else $MACRDP_VM_ROOT/tart.app)
#   VM              clone name (default macrdp-dev)
#   GUI=1           `up` opens a VM window instead of running headless
#   BRIDGE          host interface `up` bridges the clone onto, so it gets a
#                   LAN address (default: the default-route interface);
#                   BRIDGE= (empty) keeps it on the host-only NAT instead
#
# Guest login is admin/admin (cirruslabs default). With bridging that login,
# over RDP and SSH, is reachable from the whole LAN.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="${MACRDP_VM_ROOT:-/Volumes/DATA/tart}"
export TART_HOME="${TART_HOME:-$ROOT/home}"
TART="${TART:-$(command -v tart || echo "$ROOT/tart.app/Contents/MacOS/tart")}"
BASE_IMAGE="ghcr.io/cirruslabs/macos-tahoe-base:latest"
GOLDEN="macrdp-golden"
VM="${VM:-macrdp-dev}"
BRIDGE="${BRIDGE-$(route -n get default 2>/dev/null | awk '/interface:/ {print $2}')}"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/DerivedData/Build/Products/Debug/MacRDP.app"
GUEST_CONFIG='$HOME/Library/Application Support/MacRDP/vm.yaml'
GUEST_LOGS='$HOME/Library/Logs/MacRDP'

die() { echo "error: $*" >&2; exit 1; }
gexec() { "$TART" exec "$@"; }

exists() { "$TART" get "$1" >/dev/null 2>&1; }
# The default DHCP-lease resolver only knows NAT guests; ask the agent. It
# can miss for a moment (seen right after restarting MacRDP), so retry and
# fall back to the host's ARP table, which knows bridged guests too.
vm_ip() {
  local i
  for i in 1 2 3; do
    "$TART" ip "$1" --resolver agent 2>/dev/null && return
    "$TART" ip "$1" --resolver arp 2>/dev/null && return
    sleep 1
  done
  "$TART" ip "$1" --resolver agent
}
running() { "$TART" get "$1" --format json 2>/dev/null | grep -q '"State" : "running"'; }

wait_agent() {
  local vm="$1" i
  for i in $(seq 1 60); do
    gexec "$vm" /usr/bin/true >/dev/null 2>&1 && return 0
    sleep 3
  done
  die "$vm: guest agent did not come up (see $ROOT/run-$vm.log)"
}

boot() {
  local vm="$1"; shift
  if ! running "$vm"; then
    nohup "$TART" run "$@" "$vm" >"$ROOT/run-$vm.log" 2>&1 &
  fi
  wait_agent "$vm"
}

# Power off from inside the guest: only a guest-initiated shutdown persists
# NVRAM (boot-args set before a plain `tart stop` are lost), and an in-guest
# `shutdown -r` leaves a VZ macOS guest hung, so reboot = halt + boot.
halt() {
  local vm="$1" i
  running "$vm" || return 0
  gexec "$vm" sh -c 'sudo /sbin/shutdown -h now' >/dev/null 2>&1 || true
  for i in $(seq 1 20); do
    running "$vm" || return 0
    sleep 3
  done
  "$TART" stop "$vm" --timeout 10 >/dev/null || true
}

build_swift() { # <src.swift> -> prints the binary path
  local src="$1" bin; bin="$BUILD_DIR/bin/$(basename "$1" .swift)"
  if [[ ! -x "$bin" || "$src" -nt "$bin" ]]; then
    mkdir -p "$BUILD_DIR/bin"
    # Explicit: errexit doesn't reach into the $(...) callers run this in.
    swiftc -O -target arm64-apple-macos26.0 "$src" -o "$bin" || { rm -f "$bin"; return 1; }
  fi
  echo "$bin"
}

cmd_golden() {
  if [[ "${1:-}" == "--fresh" ]] && exists "$GOLDEN"; then
    halt "$GOLDEN"; "$TART" delete "$GOLDEN"
  fi
  if ! exists "$GOLDEN"; then
    echo "==> cloning $BASE_IMAGE (pulls ~26 GB on first use)"
    "$TART" clone "$BASE_IMAGE" "$GOLDEN"
    "$TART" set "$GOLDEN" --cpu 4 --memory 8192 --display 1920x1080
  fi
  echo "==> provisioning $GOLDEN"
  boot "$GOLDEN" --no-graphics
  gexec -i "$GOLDEN" sh -c 'sudo mkdir -p /usr/local/bin && sudo tee /usr/local/bin/axpress >/dev/null && sudo chmod 755 /usr/local/bin/axpress' \
    < "$(build_swift "$REPO_ROOT/scripts/vm/axpress.swift")"
  gexec -i "$GOLDEN" sh -s < "$REPO_ROOT/scripts/vm/provision-guest.sh"
  halt "$GOLDEN"
  echo "==> $GOLDEN ready"
}

cmd_up() {
  exists "$GOLDEN" || die "no $GOLDEN VM; run: $0 golden"
  if exists "$VM"; then halt "$VM"; "$TART" delete "$VM"; fi
  "$TART" clone "$GOLDEN" "$VM"
  local args=()
  [[ "${GUI:-0}" == 1 ]] || args+=(--no-graphics)
  [[ -z "$BRIDGE" ]] || args+=(--net-bridged="$BRIDGE")
  boot "$VM" "${args[@]}"
  echo "$VM up at $(vm_ip "$VM")${BRIDGE:+ (bridged on $BRIDGE)}"
}

cmd_deploy() {
  if [[ "${1:-}" != "--no-build" ]]; then
    echo "==> building MacRDP (Debug)"
    mkdir -p "$BUILD_DIR"
    # A fresh bundle version per build: macOS only replaces an installed
    # system extension (the virtual camera) with a different version.
    if ! xcodebuild -project "$REPO_ROOT/MacRDP.xcodeproj" -scheme rds -configuration Debug \
        -destination 'platform=macOS,arch=arm64' -derivedDataPath "$BUILD_DIR/DerivedData" -allowProvisioningUpdates \
        CURRENT_PROJECT_VERSION="$(date +%s)" build >"$BUILD_DIR/xcodebuild.log" 2>&1; then
      grep -E "error:" "$BUILD_DIR/xcodebuild.log" | head -20 >&2
      die "build failed (full log: $BUILD_DIR/xcodebuild.log)"
    fi
  fi
  [[ -d "$APP" ]] || die "no build at $APP"
  echo "==> installing into $VM"
  gexec "$VM" /usr/bin/pkill -x MacRDP || true
  COPYFILE_DISABLE=1 tar -C "$(dirname "$APP")" -cf - MacRDP.app \
    | gexec -i "$VM" sh -c 'sudo rm -rf /Applications/MacRDP.app && sudo tar -C /Applications -xf - && sudo chown -R admin:staff /Applications/MacRDP.app'
  gexec -i "$VM" sh -c "mkdir -p \"\$(dirname \"$GUEST_CONFIG\")\" && cat > \"$GUEST_CONFIG\"" \
    < "$REPO_ROOT/Config/vm.yaml"
}

cmd_start() {
  gexec -i "$VM" sh -s <<EOF
/usr/bin/pkill -x MacRDP && sleep 1
mkdir -p "$GUEST_LOGS"
/usr/bin/open -a /Applications/MacRDP.app \
  --stdout "$GUEST_LOGS/stdout.log" --stderr "$GUEST_LOGS/stderr.log" \
  --args --config "$GUEST_CONFIG"
for i in \$(seq 1 30); do
  /usr/sbin/lsof -nP -iTCP:3389 -sTCP:LISTEN >/dev/null && break
  sleep 1
done
# Fallback for the SCK picker-bypass alert, should provisioning not cover it.
/usr/local/bin/axpress UserNotificationCenter Allow MacRDP >/dev/null 2>&1 \
  && echo "warning: dismissed a screen-capture alert for MacRDP; re-run golden" >&2
/usr/sbin/lsof -nP -iTCP:3389 -sTCP:LISTEN >/dev/null || { echo "MacRDP is not listening" >&2; exit 1; }
EOF
  echo "MacRDP listening on $(vm_ip "$VM"):3389"
}

cmd_tool() {
  local bin; bin="$(build_swift "$1")" || die "build failed: $1"
  # Write a new file and rename it over the old: overwriting a binary in
  # place leaves the kernel's cached code signature stale, and the next run
  # is SIGKILLed ("load code signature error 2").
  local dst="/usr/local/bin/$(basename "$bin")"
  gexec -i "$VM" sh -c "sudo tee $dst.new >/dev/null && sudo chmod 755 $dst.new && sudo mv -f $dst.new $dst" < "$bin"
  echo "installed /usr/local/bin/$(basename "$bin")"
  if [[ "$(basename "$bin")" == guestcheck ]]; then install_guestcheck_app "$bin"; fi
}

# guestcheck as an app too, for camera-grab: run through `open` it is its own
# responsible process, so macOS can ask (once) whether it may use the camera,
# which it can't for the guest agent's children. Signed with the development
# identity when there is one, so the grant survives rebuilds.
install_guestcheck_app() {
  local app="$BUILD_DIR/GuestCheck.app" id
  rm -rf "$app" && mkdir -p "$app/Contents/MacOS"
  cp "$1" "$app/Contents/MacOS/guestcheck"
  cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key><string>com.mac-rdp.guestcheck</string>
	<key>CFBundleName</key><string>GuestCheck</string>
	<key>CFBundleExecutable</key><string>guestcheck</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>LSUIElement</key><true/>
	<key>NSCameraUsageDescription</key><string>MacRDP's tests check that a redirected webcam reaches Mac apps.</string>
</dict>
</plist>
PLIST
  id="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Apple Development[^"]*\)".*/\1/p' | head -1)"
  codesign --force --sign "${id:--}" "$app" >/dev/null 2>&1 || die "cannot sign $app"
  COPYFILE_DISABLE=1 tar -C "$BUILD_DIR" -cf - GuestCheck.app \
    | gexec -i "$VM" sh -c 'sudo rm -rf /Applications/GuestCheck.app && sudo tar -C /Applications -xf - && sudo chown -R admin:staff /Applications/GuestCheck.app'
  echo "installed /Applications/GuestCheck.app (signed: ${id:-ad hoc})"
}

cmd_audio_driver() {
  local drv
  drv="$("$REPO_ROOT/scripts/build-audio-driver.sh" "$BUILD_DIR" | tail -1)" || die "driver build failed"
  drv="${drv%% (signed*}"
  echo "==> installing $(basename "$drv") into $VM"
  COPYFILE_DISABLE=1 tar -C "$(dirname "$drv")" -cf - "$(basename "$drv")" \
    | gexec -i "$VM" sh -c 'd=/Library/Audio/Plug-Ins/HAL; sudo rm -rf "$d/MacRDPAudio.driver" &&
        sudo tar -C "$d" -xf - && sudo chown -R root:wheel "$d/MacRDPAudio.driver" && sudo killall coreaudiod'
  # coreaudiod comes back on demand; MacRDP picks the device up when a
  # session's microphone starts.
  sleep 3
  gexec "$VM" /usr/sbin/system_profiler SPAudioDataType | grep -A1 -E '^ +MacRDP' || echo "warning: no MacRDP device listed yet" >&2
}

# The camera row provision-guest.sh writes, for clones of an older golden.
cmd_grant_camera() {
  gexec -i "$VM" sh -s <<'EOF'
for db in "/Library/Application Support/com.apple.TCC/TCC.db" \
          "$HOME/Library/Application Support/com.apple.TCC/TCC.db"; do
  sudo /usr/bin/sqlite3 "$db" "INSERT OR REPLACE INTO access
    (service, client, client_type, auth_value, auth_reason, auth_version,
     indirect_object_identifier, flags, last_modified)
    VALUES ('kTCCServiceCamera', 'com.mac-rdp.guestcheck', 0, 2, 0, 1, 'UNUSED', 0,
            CAST(strftime('%s','now') AS INTEGER));"
done
sudo /usr/bin/killall tccd 2>/dev/null; /usr/bin/killall tccd 2>/dev/null; true
EOF
  echo "GuestCheck.app may now use the camera in $VM"
}

cmd_logs() {
  local pred='subsystem == "com.macrdp.server"'
  if [[ -n "${1:-}" ]]; then
    gexec "$VM" /usr/bin/log show --last "${1}s" --style compact --info --predicate "$pred"
  else
    gexec "$VM" /usr/bin/log stream --style compact --info --predicate "$pred"
  fi
}

cmd_wlog() {
  gexec "$VM" sh -c "tail -n ${1:-200} \"$GUEST_LOGS/stdout.log\" \"$GUEST_LOGS/stderr.log\""
}

cmd_screenshot() {
  [[ -n "${1:-}" ]] || die "usage: $0 screenshot <file.png>"
  gexec "$VM" sh -c '/usr/sbin/screencapture -x /tmp/shot.png && cat /tmp/shot.png' > "$1"
  echo "$1"
}

sub="${1:-}"; shift || true
case "$sub" in
  golden)     cmd_golden "$@" ;;
  up)         cmd_up ;;
  deploy)     cmd_deploy "$@" ;;
  start)      cmd_start ;;
  stop)       gexec "$VM" /usr/bin/pkill -x MacRDP ;;
  logs)       cmd_logs "$@" ;;
  wlog)       cmd_wlog "$@" ;;
  screenshot) cmd_screenshot "$@" ;;
  alerts)     gexec "$VM" /usr/local/bin/axpress UserNotificationCenter __none__ || true ;;
  exec)       gexec "$VM" "$@" ;;
  tool)       [[ -n "${1:-}" ]] || die "usage: $0 tool <file.swift>"; cmd_tool "$1" ;;
  audio-driver) cmd_audio_driver ;;
  grant-camera) cmd_grant_camera ;;
  ip)         vm_ip "$VM" ;;
  down)       halt "$VM" ;;
  destroy)    halt "$VM"; "$TART" delete "$VM" ;;
  *)          sed -n '3,37p' "$0"; exit 1 ;;
esac
