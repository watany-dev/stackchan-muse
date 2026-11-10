# Shared settings for the scripts in this directory. Override any of them in the environment.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SDK_REPO="${SDK_REPO:-https://github.com/facebookincubator/muse-gadget-sdk}"
SDK_REV="${SDK_REV:-b139b45064b4dcecf7bfe97e75bc7f99c10c28b6}" # 2026-10-05, what the patch was made against
SDK_DIR="${SDK_DIR:-$HERE/muse-gadget-sdk}"
# ESP-IDF's compiler mangles non-ASCII paths, so the build directory must be ASCII-only.
BUILD_DIR="${BUILD_DIR:-$HOME/.cache/stackchan-muse/build}"
IDF_EXPORT="${IDF_EXPORT:-$HOME/.espressif/esp-idf-v6.0.1/export.sh}"
PORT="${PORT:-}"

find_port() {
    if [ -z "$PORT" ]; then
        PORT=$(ls /dev/cu.usbmodem* /dev/ttyACM* 2>/dev/null | head -1 || true)
    fi
    [ -n "$PORT" ] || {
        echo "No board found. Plug in StackChan or set PORT=/dev/..." >&2
        exit 1
    }
    echo "Using port $PORT"
}

idf_env() {
    [ -f "$IDF_EXPORT" ] || {
        echo "ESP-IDF v6.0.1 not found at $IDF_EXPORT (see README)" >&2
        exit 1
    }
    # shellcheck disable=SC1090
    . "$IDF_EXPORT" >/dev/null
}
