#!/usr/bin/env bash
#
# build-audio-driver.sh — build MacRDP's virtual microphone, an Audio Server
# (HAL) plug-in made from BlackHole (ThirdParty/BlackHole, GPL-3.0 like
# MacRDP) with its compile-time options, so no BlackHole source is patched.
#
# One driver, two devices sharing a ring buffer:
#   "MacRDP Microphone"       input only, visible: what Mac apps record from
#   "MacRDP Microphone Feed"  output only, hidden: where MacRDP plays the
#                             RDP client's microphone (AUDIN)
#
#   ./scripts/build-audio-driver.sh [out-dir]   # default: ThirdParty/MacRDPAudio-build
#
# Installing: copy MacRDPAudio.driver into /Library/Audio/Plug-Ins/HAL
# (admin) and restart coreaudiod (`sudo killall coreaudiod`).
#
# Signs with SIGN_IDENTITY, else the first "Developer ID Application"
# identity, else "Apple Development" (fine for the test VM), else ad hoc.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$REPO_ROOT/ThirdParty/BlackHole"
OUT="${1:-$REPO_ROOT/ThirdParty/MacRDPAudio-build}"
NAME=MacRDPAudio
BUNDLE_ID=com.mac-rdp.rds.audio
# The CFPlugIn factory UUID must differ from BlackHole's, or the two drivers
# collide when both are installed.
FACTORY_UUID=18A6F175-CCBC-410E-ABF3-2CCAF0127B63
VERSION="$(sed -n 's/^ *MARKETING_VERSION = \(.*\);/\1/p' "$REPO_ROOT/MacRDP.xcodeproj/project.pbxproj" | head -1)"

[[ -f "$SRC/BlackHole/BlackHole.c" ]] || { echo "missing $SRC (git submodule update --init ThirdParty/BlackHole)" >&2; exit 1; }

# The device and UID names. kHas_Driver_Name_Format=false drops BlackHole's
# "%ich" suffix, so the UIDs are "MacRDP_UID" (microphone) and
# "MacRDP_2_UID" (feed); AudioInPipeline looks the feed up by that UID.
defs=(
  'kDriver_Name=\"MacRDP\"'
  "kPlugIn_BundleID=\\\"$BUNDLE_ID\\\""
  'kPlugIn_Icon=\"MacRDPAudio.icns\"'
  'kManufacturer_Name=\"MacRDP\"'
  'kHas_Driver_Name_Format=false'
  'kDevice_Name=\"MacRDP\ Microphone\"'
  'kDevice_HasInput=true' 'kDevice_HasOutput=false' 'kDevice_IsHidden=false'
  'kDevice2_Name=\"MacRDP\ Microphone\ Feed\"'
  'kDevice2_HasInput=false' 'kDevice2_HasOutput=true' 'kDevice2_IsHidden=true'
  'kNumber_Of_Channels=2'
  'kSampleRates=44100,48000'
  'kCanBeDefaultDevice=true' 'kCanBeDefaultSystemDevice=false'
)

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
xcodebuild -project "$SRC/BlackHole.xcodeproj" -configuration Release -target BlackHole \
  CONFIGURATION_BUILD_DIR="$tmp" OBJROOT="$tmp/obj" SYMROOT="$tmp" \
  PRODUCT_NAME="$NAME" PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" MARKETING_VERSION="$VERSION" \
  MACOSX_DEPLOYMENT_TARGET=12.0 \
  CODE_SIGNING_ALLOWED=NO \
  GCC_PREPROCESSOR_DEFINITIONS="\$(inherited) ${defs[*]}" \
  build >"$tmp/xcodebuild.log" 2>&1 || { grep -E "error:" "$tmp/xcodebuild.log" >&2; exit 1; }

drv="$tmp/$NAME.driver"
plist="$drv/Contents/Info.plist"
sed -i '' "s/e395c745-4eea-4d94-bb92-46224221047c/$FACTORY_UUID/g" "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(date +%s)" "$plist"
# Keep BlackHole's LICENSE (GPL-3.0 attribution); its other notes describe BlackHole.
rm -f "$drv/Contents/Resources/"{BlackHole.icns,README.md,CHANGELOG.md,VERSION}

id="${SIGN_IDENTITY:-}"
if [[ -z "$id" ]]; then
  ids="$(security find-identity -v -p codesigning 2>/dev/null)"
  id="$(sed -n 's/.*"\(Developer ID Application[^"]*\)".*/\1/p' <<<"$ids" | head -1)"
  [[ -n "$id" ]] || id="$(sed -n 's/.*"\(Apple Development[^"]*\)".*/\1/p' <<<"$ids" | head -1)"
fi
codesign --force --options runtime --timestamp=none --sign "${id:--}" "$drv"

mkdir -p "$OUT"
rm -rf "$OUT/$NAME.driver"
mv "$drv" "$OUT/"
echo "$OUT/$NAME.driver (signed: ${id:-ad hoc})"
