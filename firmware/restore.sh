#!/usr/bin/env bash
# Writes a backup from backup.sh back to the board (the factory firmware, if
# that's what you backed up). Overwrites everything, Muse pairing included.
set -euo pipefail
. "$(dirname "$0")/env.sh"
if [ $# -ne 1 ] || [ ! -f "$1" ]; then
    echo "usage: $0 stackchan_backup.bin" >&2
    exit 1
fi
[ "$(wc -c <"$1" | tr -d ' ')" = 16777216 ] || {
    echo "$1 is not a 16 MB backup" >&2
    exit 1
}
find_port
ESPTOOL="${ESPTOOL:-python3 -m esptool}"
$ESPTOOL --port "$PORT" --baud 460800 write-flash 0 "$1"
