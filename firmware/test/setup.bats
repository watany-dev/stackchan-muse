#!/usr/bin/env bats
# setup.sh against a local fake SDK (SDK_REPO=file://...) and a small fake
# patch, so it runs offline in seconds. The font generator is a stub script
# inside the fake SDK.

load test_helper

FONT=esp32/components/muse/fonts/muse_font_cjk_16.c

setup() {
    setup_firmware
    export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
    export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid
    export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

    SRC="$BATS_TEST_TMPDIR/sdk-src"
    mkdir -p "$SRC/$(dirname "$FONT")" "$SRC/esp32/tools/muse"
    echo '/* SDK font: kana and kanji */' >"$SRC/$FONT"
    # Appends the Hangul range to the font, like the real generator's output.
    cat >"$SRC/esp32/tools/muse/gen_cjk_font.sh" <<'GEN'
echo "gen_cjk_font MUSE_FONT_HANGUL=${MUSE_FONT_HANGUL:-}" >> "$STUB_LOG"
echo '/* 0xAC00-0xD7A3 */' >> "$(dirname "$0")/../../components/muse/fonts/muse_font_cjk_16.c"
GEN
    git -C "$SRC" init -q
    git -C "$SRC" add -A
    git -C "$SRC" commit -q -m "fake SDK"
    export SDK_REPO="file://$SRC" SDK_REV="$(git -C "$SRC" rev-parse HEAD)"

    cat >"$WORK/muse-stackchan.patch" <<'PATCH'
diff --git a/esp32/stackchan.txt b/esp32/stackchan.txt
new file mode 100644
--- /dev/null
+++ b/esp32/stackchan.txt
@@ -0,0 +1 @@
+stackchan
PATCH
    SDK="$WORK/muse-gadget-sdk" # default SDK_DIR, under the path with a space
}

gen_runs() {
    calls gen_cjk_font | wc -l | tr -d ' '
}

@test "first run clones the SDK at SDK_REV and applies the patch" {
    run "$WORK/setup.sh"
    assert_success
    assert_output --partial "Patch applied on ${SDK_REV:0:7}"
    assert_equal "$(cat "$SDK/esp32/stackchan.txt")" stackchan
    assert_equal "$(git -C "$SDK" rev-parse HEAD)" "$SDK_REV"
}

@test "second run: 'Patch already applied.' and nothing is redone" {
    run "$WORK/setup.sh"
    assert_success
    local gens
    gens="$(gen_runs)"

    run "$WORK/setup.sh"
    assert_success
    assert_output --partial "Patch already applied."
    refute_output --partial "Patch applied on"
    assert_equal "$(gen_runs)" "$gens"
    assert_equal "$(cat "$SDK/esp32/stackchan.txt")" stackchan
}

@test "an SDK on another commit is moved to SDK_REV before patching" {
    git clone -q "$SRC" "$SDK"
    echo newer >"$SRC/newer.txt"
    git -C "$SRC" add -A && git -C "$SRC" commit -q -m newer
    git -C "$SDK" pull -q
    run "$WORK/setup.sh"
    assert_success
    assert_equal "$(git -C "$SDK" rev-parse HEAD)" "$SDK_REV"
}

@test "a patch that doesn't apply fails the script" {
    printf 'not a patch\n' >"$WORK/muse-stackchan.patch"
    run "$WORK/setup.sh"
    assert_failure
    refute_output --partial "Ready."
}

# --- FONT_HANGUL (PR #1) ---------------------------------------------------------

needs_font_hangul() {
    grep -q FONT_HANGUL "$FIRMWARE_SRC/setup.sh" || skip "setup.sh has no FONT_HANGUL yet (PR #1)"
}

@test "FONT_HANGUL unset: the SDK's font is left alone" {
    needs_font_hangul
    run "$WORK/setup.sh"
    assert_success
    assert_equal "$(gen_runs)" 0
    refute grep -q 0xAC00-0xD7A3 "$SDK/$FONT"
}

@test "FONT_HANGUL=1 adds Hangul once; FONT_HANGUL=0 puts the SDK's font back" {
    needs_font_hangul
    FONT_HANGUL=1 run "$WORK/setup.sh"
    assert_success
    assert_equal "$(calls gen_cjk_font)" "gen_cjk_font MUSE_FONT_HANGUL=1"
    assert grep -q 0xAC00-0xD7A3 "$SDK/$FONT"

    FONT_HANGUL=1 run "$WORK/setup.sh"
    assert_success
    assert_equal "$(gen_runs)" 1

    FONT_HANGUL=0 run "$WORK/setup.sh"
    assert_success
    assert_output --partial "Caption font: back to the SDK's"
    assert_equal "$(cat "$SDK/$FONT")" "$(cat "$SRC/$FONT")"
    assert_equal "$(git -C "$SDK" status --porcelain -- "$FONT")" ""
}

# A patch that, like the real one, also adds esp32/dependencies.lock (#7).
patch_with_lock() {
    cat >>"$WORK/muse-stackchan.patch" <<'PATCH'
diff --git a/esp32/dependencies.lock b/esp32/dependencies.lock
new file mode 100644
--- /dev/null
+++ b/esp32/dependencies.lock
@@ -0,0 +1 @@
+pinned
PATCH
}

@test "a dependencies.lock left in a fresh clone does not block the patch (#7)" {
    patch_with_lock
    git clone -q "$SRC" "$SDK"
    echo stale >"$SDK/esp32/dependencies.lock"
    run "$WORK/setup.sh"
    assert_success
    assert_output --partial "Patch applied on"
    assert_equal "$(cat "$SDK/esp32/dependencies.lock")" pinned
    assert_equal "$(cat "$SDK/esp32/stackchan.txt")" stackchan
}

@test "a lock rewritten by a build is put back to the pinned one, the rest left as is (#7)" {
    patch_with_lock
    run "$WORK/setup.sh"
    assert_success
    echo resolved-again >"$SDK/esp32/dependencies.lock"
    run "$WORK/setup.sh"
    assert_success
    assert_output --partial "dependencies.lock reset to the pinned versions"
    assert_equal "$(cat "$SDK/esp32/dependencies.lock")" pinned
    assert_equal "$(cat "$SDK/esp32/stackchan.txt")" stackchan

    run "$WORK/setup.sh"
    assert_success
    assert_output --partial "Patch already applied."
    refute_output --partial "reset to the pinned"
}
