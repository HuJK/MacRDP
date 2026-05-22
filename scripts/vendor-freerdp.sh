#!/usr/bin/env bash
#
# vendor-freerdp.sh — set up FreeRDP as a git submodule and build the
# server-side static libs we link against from macOS.
#
# Strategy:
#   1. Try upstream FreeRDP 3.x with aggressive CMake disables.
#   2. If that fails or upstream drifts away from macOS-server-friendly,
#      switch the submodule URL to our local fork (server-only).
#      The fork's commit history IS our patch series — no separate
#      .patch files maintained in this repo.
#
# Run from repo root:
#   ./scripts/vendor-freerdp.sh init     # add submodule (one-time)
#   ./scripts/vendor-freerdp.sh build    # cmake + build static libs
#   ./scripts/vendor-freerdp.sh clean    # remove build artifacts
#   ./scripts/vendor-freerdp.sh fork     # switch submodule URL to fork
#
# Requirements:
#   brew install cmake ninja openssl@3 pkg-config

set -euo pipefail

# Source Homebrew env if brew isn't already on PATH (Xcode shells don't
# inherit the login environment, so /opt/homebrew/bin is often missing).
if ! command -v brew >/dev/null 2>&1; then
  for brew_bin in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    if [ -x "$brew_bin" ]; then
      eval "$("$brew_bin" shellenv)"
      break
    fi
  done
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SUBMODULE_PATH="ThirdParty/FreeRDP"
UPSTREAM_URL="https://github.com/FreeRDP/FreeRDP.git"
# Adjust this once a fork exists:
FORK_URL_PLACEHOLDER="git@github.com:CHANGE-ME/FreeRDP-macrdp.git"
# Branch (NOT a tag — git submodule -b needs a branch). FreeRDP doesn't
# have a stable-3.x branch; the 3.x line lives on master with tagged
# releases. We submodule-track master and pin to a tag inside.
FREERDP_BRANCH="master"
# Specific tag we check out inside the submodule for reproducible builds.
# Bump this when we want a newer release.
# Temporarily on master HEAD while we re-test LOCK_CLIPDATA behaviour.
FREERDP_TAG="origin/master"

BUILD_DIR="$REPO_ROOT/ThirdParty/FreeRDP-build"
INSTALL_DIR="$REPO_ROOT/ThirdParty/FreeRDP-install"

require_openssl3() {
  OPENSSL_PREFIX="$(brew --prefix openssl@3 2>/dev/null || true)"
  if [ -z "$OPENSSL_PREFIX" ]; then
    echo "openssl@3 not found via brew — please install:  brew install openssl@3" >&2
    exit 1
  fi
}

cmd_init() {
  if [ -d "$REPO_ROOT/$SUBMODULE_PATH/.git" ] || \
     [ -f "$REPO_ROOT/$SUBMODULE_PATH/.git" ]; then
    echo "FreeRDP submodule already initialised at $SUBMODULE_PATH"
    return
  fi
  echo "Adding FreeRDP submodule from $UPSTREAM_URL (branch $FREERDP_BRANCH)"
  # We add without --depth 1 because we want to be able to check out a
  # specific tag below; shallow clones can't always reach tags.
  git -C "$REPO_ROOT" submodule add -b "$FREERDP_BRANCH" \
      "$UPSTREAM_URL" "$SUBMODULE_PATH"
  git -C "$REPO_ROOT" submodule update --init --recursive "$SUBMODULE_PATH"

  echo "Checking out tag $FREERDP_TAG"
  git -C "$REPO_ROOT/$SUBMODULE_PATH" fetch --tags origin
  git -C "$REPO_ROOT/$SUBMODULE_PATH" checkout "tags/$FREERDP_TAG" -b "macrdp/$FREERDP_TAG"
  echo "FreeRDP @ $FREERDP_TAG ready at $SUBMODULE_PATH"
}

cmd_fork() {
  echo "Switching submodule URL to: $FORK_URL_PLACEHOLDER"
  echo "(edit $0 to set FORK_URL_PLACEHOLDER first)"
  test "$FORK_URL_PLACEHOLDER" != "git@github.com:CHANGE-ME/FreeRDP-macrdp.git"
  git -C "$REPO_ROOT" config --file .gitmodules \
      "submodule.$SUBMODULE_PATH.url" "$FORK_URL_PLACEHOLDER"
  git -C "$REPO_ROOT" submodule sync "$SUBMODULE_PATH"
  git -C "$REPO_ROOT/$SUBMODULE_PATH" remote set-url origin "$FORK_URL_PLACEHOLDER"
  git -C "$REPO_ROOT/$SUBMODULE_PATH" fetch origin
}

cmd_build() {
  require_openssl3
  if [ ! -d "$REPO_ROOT/$SUBMODULE_PATH/.git" ] && \
     [ ! -f "$REPO_ROOT/$SUBMODULE_PATH/.git" ]; then
    cmd_init
  fi
  mkdir -p "$BUILD_DIR"
  cmake -S "$REPO_ROOT/$SUBMODULE_PATH" -B "$BUILD_DIR" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
    -DCMAKE_OSX_ARCHITECTURES="arm64" \
    -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR" \
    -DBUILD_SHARED_LIBS=OFF \
    -DOPENSSL_ROOT_DIR="$OPENSSL_PREFIX" \
    -DWITH_CLIENT=OFF \
    -DWITH_CLIENT_COMMON=OFF \
    -DWITH_CLIENT_INTERFACE=OFF \
    -DWITH_SERVER=ON \
    -DWITH_SERVER_INTERFACE=ON \
    -DWITH_SAMPLE=OFF \
    -DWITH_SHADOW=OFF \
    -DWITH_PROXY=OFF \
    -DWITH_X11=OFF \
    -DWITH_WAYLAND=OFF \
    -DWITH_PULSE=OFF \
    -DWITH_ALSA=OFF \
    -DWITH_OSS=OFF \
    -DWITH_PAM=OFF \
    -DWITH_PCSC=OFF \
    -DWITH_CUPS=OFF \
    -DWITH_FFMPEG=OFF \
    -DWITH_GSM=OFF \
    -DWITH_GSSAPI=OFF \
    -DWITH_KRB5=OFF \
    -DWITH_OPENH264=OFF \
    -DWITH_X264=OFF \
    -DWITH_SWSCALE=OFF \
    -DWITH_LAME=OFF \
    -DWITH_FAAD2=OFF \
    -DWITH_FAAC=OFF \
    -DWITH_SOXR=OFF \
    -DWITH_OPUS=OFF \
    -DWITH_MANPAGES=OFF \
    -DWITH_INTERNAL_RC4=ON \
    -DWITH_INTERNAL_MD4=ON \
    -DWITH_INTERNAL_MD5=ON \
    -DCHANNEL_RDPDR=ON \
    -DCHANNEL_RDPDR_SERVER=ON \
    -DCHANNEL_DRIVE=OFF \
    -DCHANNEL_PARALLEL=OFF \
    -DCHANNEL_SERIAL=OFF \
    -DCHANNEL_SMARTCARD=OFF \
    -DCHANNEL_TSMF=OFF \
    -DCHANNEL_VIDEO=OFF \
    -DCHANNEL_GEOMETRY=OFF \
    -DCHANNEL_RDPGFX=ON \
    -DCHANNEL_RDPGFX_SERVER=ON \
    -DCHANNEL_RDPSND=ON \
    -DCHANNEL_RDPSND_SERVER=ON \
    -DCHANNEL_AUDIN=ON \
    -DCHANNEL_AUDIN_SERVER=ON \
    -DCHANNEL_CLIPRDR=ON \
    -DCHANNEL_CLIPRDR_SERVER=ON \
    -DCHANNEL_DISP=ON \
    -DCHANNEL_DISP_SERVER=ON \
    -DCHANNEL_DRDYNVC=ON \
    -DCHANNEL_DRDYNVC_SERVER=ON \
    -DCHANNEL_ENCOMSP=OFF \
    -DCHANNEL_REMDESK=OFF
  cmake --build "$BUILD_DIR" --target install
  echo ""
  echo "Built FreeRDP server libs:"
  find "$INSTALL_DIR/lib" -name '*.a' 2>/dev/null || true
}

cmd_clean() {
  rm -rf "$BUILD_DIR" "$INSTALL_DIR"
}

case "${1:-}" in
  init)  cmd_init ;;
  fork)  cmd_fork ;;
  build) cmd_build ;;
  clean) cmd_clean ;;
  *)
    echo "Usage: $0 {init|build|fork|clean}"
    exit 1
    ;;
esac
