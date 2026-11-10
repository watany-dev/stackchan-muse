#!/usr/bin/env bash
# Builds the StackChan Muse firmware. Needs sdkconfig.local-token here;
# sdkconfig.local-tts is optional (spoken replies).
set -euo pipefail
. "$(dirname "$0")/env.sh"
idf_env

[ -d "$SDK_DIR/esp32" ] || { echo "Run ./setup.sh first." >&2; exit 1; }
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

mkdir -p "$BUILD_DIR"
rm -f "$BUILD_DIR/sdkconfig"   # a stale generated config would override the overlays
cd "$E"
idf.py -B "$BUILD_DIR" -DIDF_TARGET=esp32s3 -DSDKCONFIG="$BUILD_DIR/sdkconfig" \
    -DSDKCONFIG_DEFAULTS="$DEFAULTS" build
echo "Built in $BUILD_DIR. Next: ./flash.sh"
