#!/usr/bin/env bash
# Builds the StackChan Muse firmware. Needs sdkconfig.local-token here;
# sdkconfig.local-tts is optional (spoken replies). WAKE_WORD picks the wake
# word: himuse ("Hi, Muse", the default) or histackchan ("Hi, Stack Chan").
set -euo pipefail
. "$(dirname "$0")/env.sh"
idf_env

[ -d "$SDK_DIR/esp32" ] || {
    echo "Run ./setup.sh first." >&2
    exit 1
}
[ -f "$HERE/sdkconfig.local-token" ] || {
    echo "Missing sdkconfig.local-token: cp sdkconfig.local-token.example sdkconfig.local-token and add your token." >&2
    exit 1
}
# Same rule as the SDK's cmake/validate_config.cmake: mgst_ plus 43 base64url characters.
grep -Eq '^CONFIG_GADGET_SDK_TOKEN="mgst_[A-Za-z0-9_-]{42}[AEIMQUYcgkosw048]"' "$HERE/sdkconfig.local-token" || {
    echo "sdkconfig.local-token: CONFIG_GADGET_SDK_TOKEN is missing or not a valid mgst_ token (48 characters)." >&2
    exit 1
}

E="$SDK_DIR/esp32"
# The hardware-free parts of the neck code live in src/ so test/ can run them on a PC.
cp "$HERE"/src/*.c "$HERE"/src/*.h "$E/main/"
# The UTF-8 cuts for replies (#12) are used by the muse component.
cp "$HERE"/src/stackchan_utf8.c "$HERE"/src/stackchan_utf8.h "$E/components/muse/"
cp "$HERE/sdkconfig.local-token" "$E/devices/sdkconfig.local-token"
DEFAULTS="sdkconfig.defaults;devices/sdkconfig.muse;devices/sdkconfig.muse-m5stack-cores3;devices/sdkconfig.muse-stackchan;devices/sdkconfig.local-token"
if [ -f "$HERE/sdkconfig.local-tts" ]; then
    cp "$HERE/sdkconfig.local-tts" "$E/devices/sdkconfig.local-tts"
    DEFAULTS="$DEFAULTS;devices/sdkconfig.local-tts"
    echo "Spoken replies: on"
else
    rm -f "$E/devices/sdkconfig.local-tts"
    echo "Spoken replies: off (captions only)"
fi

case "$WAKE_WORD" in
    himuse)
        rm -f "$E/devices/sdkconfig.local-wake"
        ;;
    histackchan)
        printf '%s\n' '# CONFIG_SR_WN_WN10_HIMUSE is not set' 'CONFIG_SR_WN_WN9L_HISTACKCHAN_TTS3=y' \
            >"$E/devices/sdkconfig.local-wake"
        DEFAULTS="$DEFAULTS;devices/sdkconfig.local-wake"
        ;;
    *)
        echo "WAKE_WORD must be himuse or histackchan, not '$WAKE_WORD'." >&2
        exit 1
        ;;
esac
echo "Wake word: $WAKE_WORD"

mkdir -p "$BUILD_DIR"
rm -f "$BUILD_DIR/sdkconfig" # a stale generated config would override the overlays
cd "$E"
# The patch pins every managed component in dependencies.lock (#7). If the build
# rewrote it, the component versions differ from the ones we measured.
lock_before="$(cksum <dependencies.lock 2>/dev/null || true)"
idf.py -B "$BUILD_DIR" -DIDF_TARGET=esp32s3 -DSDKCONFIG="$BUILD_DIR/sdkconfig" \
    -DSDKCONFIG_DEFAULTS="$DEFAULTS" build
if [ -n "$lock_before" ] && [ "$(cksum <dependencies.lock 2>/dev/null || true)" != "$lock_before" ]; then
    msg="dependencies.lock changed during the build, so components differ from the pinned versions. If you changed idf_component.yml on purpose, put the new lock into muse-stackchan.patch (see README)."
    if [ "${CI:-}" = true ]; then
        echo "Error: $msg" >&2
        exit 1
    fi
    echo "Warning: $msg" >&2
fi
echo "Built in $BUILD_DIR. Next: ./flash.sh"
