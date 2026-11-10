# Shared setup for the firmware/*.sh tests. Nothing here touches a real board,
# ESP-IDF or the network: esptool, idf.py and friends are stubs on PATH that
# record how they were called.

bats_load_library bats-support
bats_load_library bats-assert

FIRMWARE_SRC="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

# Copies the scripts into a fresh directory whose path has a space in it
# (like ~/My Projects/), so every test also checks the quoting of $HERE.
setup_firmware() {
    WORK="$BATS_TEST_TMPDIR/My Projects/firmware"
    mkdir -p "$WORK"
    cp "$FIRMWARE_SRC"/*.sh "$WORK"/
    cp -R "$FIRMWARE_SRC/src" "$WORK"/   # build.sh copies these into the SDK

    STUBS="$BATS_TEST_TMPDIR/stubs"
    mkdir -p "$STUBS"
    export STUB_LOG="$BATS_TEST_TMPDIR/calls.log"
    : > "$STUB_LOG"
    PATH="$STUBS:$PATH"

    export HOME="$BATS_TEST_TMPDIR/home"
    mkdir -p "$HOME"
    unset PORT SDK_REPO SDK_REV SDK_DIR BUILD_DIR IDF_EXPORT WAKE_WORD FONT_HANGUL ESPTOOL
}

# stub NAME [BODY]: puts a fake NAME first on PATH. Each call appends one line
# to $STUB_LOG: the name, then every argument in brackets, so arguments with
# spaces stay readable. BODY (shell code) runs after that, with "$@" intact.
stub() {
    local name="$1" body="${2:-}"
    cat > "$STUBS/$name" <<STUB
#!/usr/bin/env bash
{ printf '%s' "$name"; printf ' [%s]' "\$@"; echo; } >> "\$STUB_LOG"
$body
STUB
    chmod +x "$STUBS/$name"
}

# The calls recorded for one stub, one per line.
calls() {
    grep -E "^$1( |\$)" "$STUB_LOG" || true
}

assert_not_called() {
    local got
    got="$(calls "$1")"
    [ -z "$got" ] || fail "$1 should not have been called, but got:
$got"
}

# A file of exactly SIZE bytes (sparse, so 16 MB costs nothing).
make_file_of_size() {
    dd if=/dev/zero of="$1" bs=1 count=0 seek="$2" 2>/dev/null
}
