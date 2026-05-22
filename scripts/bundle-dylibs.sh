#!/usr/bin/env zsh
#
# bundle-dylibs.sh
#
# Run as a Build Phase on the rds target — copies Homebrew's libssl
# and libcrypto into MacRDP.app/Contents/Frameworks/, rewrites their
# install names + cross-references to use @rpath, fixes the main
# binary's references, then re-signs everything with the build's
# code-signing identity.
#
# Result: a fully self-contained .app that runs on Macs without
# Homebrew installed. Works with notarization (no external deps).
#
# Build Phase setup in Xcode (rds target → Build Phases → +):
#   Shell:           /bin/zsh
#   Script:          "${SRCROOT}/scripts/bundle-dylibs.sh"
#   Input Files:     (empty)
#   Output Files:    $(BUILT_PRODUCTS_DIR)/$(WRAPPER_NAME)/Contents/Frameworks/libssl.3.dylib
#                    $(BUILT_PRODUCTS_DIR)/$(WRAPPER_NAME)/Contents/Frameworks/libcrypto.3.dylib
#   Run order:       AFTER "Link Binary With Libraries", BEFORE
#                    "Embed Foundation Extensions" (so the extension
#                    embed step copies a fully-fixed .app).
#

set -euo pipefail

OPENSSL_PREFIX="/opt/homebrew/opt/openssl@3"
FRAMEWORKS_DIR="${BUILT_PRODUCTS_DIR}/${WRAPPER_NAME}/Contents/Frameworks"
MAIN_BIN="${BUILT_PRODUCTS_DIR}/${WRAPPER_NAME}/Contents/MacOS/${EXECUTABLE_NAME}"
# Swift Debug builds emit a separate .debug.dylib next to the main
# binary; it carries the actual library references. Patch it too.
DEBUG_DYLIB="${BUILT_PRODUCTS_DIR}/${WRAPPER_NAME}/Contents/MacOS/${EXECUTABLE_NAME}.debug.dylib"

DYLIBS=(libssl.3.dylib libcrypto.3.dylib)

if [[ ! -d "$OPENSSL_PREFIX" ]]; then
    echo "error: Homebrew openssl@3 not found at $OPENSSL_PREFIX. Install with: brew install openssl@3" >&2
    exit 1
fi

mkdir -p "$FRAMEWORKS_DIR"

# --- 1. Copy + rewrite each dylib --------------------------------

for lib in "${DYLIBS[@]}"; do
    src="$OPENSSL_PREFIX/lib/$lib"
    dst="$FRAMEWORKS_DIR/$lib"
    if [[ ! -f "$src" ]]; then
        echo "error: missing $src" >&2
        exit 1
    fi
    cp -f "$src" "$dst"
    chmod 644 "$dst"
    # The dylib's own self-id ("@rpath/libssl.3.dylib") so anyone
    # linking it sees a relocatable name.
    install_name_tool -id "@rpath/$lib" "$dst"
done

# libssl internally references libcrypto by absolute Homebrew path.
# That path may be the `opt/openssl@3/lib/...` symlink form OR the
# resolved `Cellar/openssl@3/<ver>/lib/...` form (Homebrew has used
# both at various times). Rewrite whichever is present.
fix_internal_ref() {
    local target_dylib="$1"
    local target_filename="$2"   # libcrypto.3.dylib
    # Grep otool output for any path ending in /$target_filename
    # that isn't already an @rpath reference.
    while IFS= read -r ref; do
        if [[ -n "$ref" && "$ref" != "@rpath/$target_filename" ]]; then
            install_name_tool -change "$ref" "@rpath/$target_filename" "$target_dylib"
        fi
    done < <(otool -L "$target_dylib" | awk '{print $1}' | grep "/${target_filename}$" || true)
}
fix_internal_ref "$FRAMEWORKS_DIR/libssl.3.dylib" "libcrypto.3.dylib"

# --- 2. Patch the main binary + debug dylib ---------------------

patch_binary() {
    local bin="$1"
    [[ -f "$bin" ]] || return 0
    for lib in "${DYLIBS[@]}"; do
        # Find every existing ref that ends in /$lib (whether opt/...
        # symlink form or Cellar/.../version/lib/... realpath form)
        # and rewrite each one to @rpath/$lib.
        while IFS= read -r ref; do
            if [[ -n "$ref" && "$ref" != "@rpath/$lib" ]]; then
                install_name_tool -change "$ref" "@rpath/$lib" "$bin" 2>/dev/null || true
            fi
        done < <(otool -L "$bin" 2>/dev/null | awk '{print $1}' | grep "/${lib}$" || true)
    done
}

patch_binary "$MAIN_BIN"
patch_binary "$DEBUG_DYLIB"

# --- 3. Re-sign the dylibs --------------------------------------
#
# Use the same identity Xcode used for the main binary. Without
# re-signing, Gatekeeper rejects the launch and the new dylibs
# fail library validation.

if [[ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]]; then
    SIGN_ARGS=(--force --sign "${EXPANDED_CODE_SIGN_IDENTITY}")
    # Hardened runtime is required for notarization on macOS 10.15+.
    SIGN_ARGS+=(--options runtime)
    # Don't request a secure timestamp during dev builds (would need
    # network); enable for Release if needed.
    for lib in "${DYLIBS[@]}"; do
        codesign "${SIGN_ARGS[@]}" "$FRAMEWORKS_DIR/$lib"
    done
else
    echo "note: EXPANDED_CODE_SIGN_IDENTITY empty — leaving dylibs unsigned (will fail on distribution builds)"
fi

echo "Bundled dylibs into $FRAMEWORKS_DIR"
