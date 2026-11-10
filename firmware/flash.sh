#!/usr/bin/env bash
# Writes the build to the board: bootloader, partition table, app and the
# wake word model. NVS (pairing, Wi-Fi) is left alone.
set -euo pipefail
. "$(dirname "$0")/env.sh"
idf_env
find_port
[ -f "$BUILD_DIR/flash_args" ] || {
    echo "Run ./build.sh first." >&2
    exit 1
}
cd "$BUILD_DIR"
python -m esptool --chip esp32s3 -p "$PORT" -b 460800 \
    --before default-reset --after hard-reset write-flash "@flash_args"
