#!/bin/sh
#
# provision-guest.sh — one-time setup inside the golden VM, streamed in by
# `scripts/tart-vm.sh golden`. Runs as `admin` through the Tart guest agent;
# the cirruslabs base image already has SIP off, passwordless sudo and
# auto-login, which is what makes every step below scriptable.
#
# Expects /usr/local/bin/axpress to be installed already.
#
set -eu

BUNDLE=com.mac-rdp.rds
AGENT=$(/usr/bin/readlink -f /opt/homebrew/bin/tart-guest-agent)

# 1. AMFI off. Our development provisioning profiles only list the host
#    Mac's UDID, so AMFI kills MacRDP in the VM ("Code has restricted
#    entitlements"). Takes effect on next boot, i.e. in every clone, and is
#    only persisted if the guest powers itself off (tart-vm.sh's halt).
sudo /usr/sbin/nvram boot-args="amfi_get_out_of_my_way=1"

# 2. TCC grants. Keyed by bundle id with no csreq (same shape as the rows
#    the base image ships for its own tools), so they survive re-signing.
for db in "/Library/Application Support/com.apple.TCC/TCC.db" \
          "$HOME/Library/Application Support/com.apple.TCC/TCC.db"; do
  for svc in kTCCServiceAccessibility kTCCServiceScreenCapture kTCCServicePostEvent \
             kTCCServiceAudioCapture kTCCServiceMicrophone; do
    sudo /usr/bin/sqlite3 "$db" "INSERT OR REPLACE INTO access
      (service, client, client_type, auth_value, auth_reason, auth_version,
       indirect_object_identifier, flags, last_modified)
      VALUES ('$svc', '$BUNDLE', 0, 2, 0, 1, 'UNUSED', 0,
              CAST(strftime('%s','now') AS INTEGER));"
  done
done
sudo /usr/bin/killall tccd 2>/dev/null || true
/usr/bin/killall tccd 2>/dev/null || true

# 3. ScreenCaptureKit's "requesting to bypass the system private window
#    picker" alert. It is not a TCC row but replayd's own approval record,
#    which re-alerts once the record looks stale. Found empirically on 26.6:
#    the future LastAlerted/HintDate alone are not enough, LastUsed must be
#    in the future too or the app alerts on its first capture after boot.
#    Let replayd create its group container with one real capture, dismiss
#    the alert that raises, then write records for MacRDP and for the guest
#    agent (which takes our screenshots).
/usr/sbin/screencapture -x /tmp/provision.png
sleep 2
/usr/local/bin/axpress UserNotificationCenter Allow >/dev/null 2>&1 || true
rm -f /tmp/provision.png

P="$HOME/Library/Group Containers/group.com.apple.replayd/ScreenCaptureApprovals.plist"
# SIGKILL, not SIGTERM: on a clean exit replayd writes its in-memory copy
# back over our edits.
/usr/bin/killall -9 replayd 2>/dev/null || true
for k in "$BUNDLE" "$AGENT"; do
  /usr/libexec/PlistBuddy -c "Delete :$k" "$P" >/dev/null 2>&1 || true
  /usr/libexec/PlistBuddy \
    -c "Add :$k dict" \
    -c "Add :$k:kScreenCaptureAlertableUsageCount integer 1" \
    -c "Add :$k:kScreenCaptureApprovalLastAlerted date \"Thu Jan 01 00:00:00 UTC 2099\"" \
    -c "Add :$k:kScreenCaptureApprovalLastUsed date \"Thu Jan 01 00:00:00 UTC 2099\"" \
    -c "Add :$k:kScreenCapturePrivacyHintDate date \"Fri Jan 01 00:00:00 UTC 2100\"" \
    -c "Add :$k:kScreenCapturePrivacyHintPolicy integer 3153600000" \
    "$P" >/dev/null
done

echo "provisioned: boot-args=$(/usr/sbin/nvram boot-args | cut -f2)"
