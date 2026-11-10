#!/usr/bin/env bash
# Clones the Muse Gadget SDK at the tested commit and applies the StackChan
# patch. With FONT_HANGUL=1 it also regenerates the caption font with Hangul.
# Safe to run twice.
set -euo pipefail
. "$(dirname "$0")/env.sh"

if [ ! -d "$SDK_DIR/.git" ]; then
    git clone "$SDK_REPO" "$SDK_DIR"
fi
git -C "$SDK_DIR" fetch -q origin "$SDK_REV" 2>/dev/null || true

if git -C "$SDK_DIR" apply --reverse --check "$HERE/muse-stackchan.patch" 2>/dev/null; then
    echo "Patch already applied."
else
    git -C "$SDK_DIR" checkout -q "$SDK_REV"
    git -C "$SDK_DIR" apply "$HERE/muse-stackchan.patch"
    echo "Patch applied on $(git -C "$SDK_DIR" rev-parse --short HEAD)."
fi

# The SDK's caption font already has kana and kanji, so Japanese needs nothing
# more. FONT_HANGUL=1 regenerates it with Hangul from GNU Unifont (needs curl
# and npx/Node.js, about 2 minutes); FONT_HANGUL=0 puts the SDK's font back.
FONT="esp32/components/muse/fonts/muse_font_cjk_16.c"
if [ "$FONT_HANGUL" = 1 ]; then
    if ! grep -q "0xAC00-0xD7A3" "$SDK_DIR/$FONT" 2>/dev/null; then
        MUSE_FONT_HANGUL=1 sh "$SDK_DIR/esp32/tools/muse/gen_cjk_font.sh"
    fi
elif grep -q "0xAC00-0xD7A3" "$SDK_DIR/$FONT" 2>/dev/null; then
    git -C "$SDK_DIR" checkout -q -- "$FONT"
    echo "Caption font: back to the SDK's (no Hangul)."
fi
echo "Ready. Next: cp sdkconfig.local-token.example sdkconfig.local-token, add your token, then ./build.sh"
