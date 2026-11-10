#!/usr/bin/env bats
# build.sh: token check, sdkconfig overlays, wake word. idf.py is a stub.

load test_helper

B64='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_'
LAST='AEIMQUYcgkosw048' # base64url characters whose low 2 bits are 0
BAD_LAST='BCDFGHJKLNOPRSTVWXZabdefhijlmnpqrtuvxyz1235679-_'
NOT_B64=' +/=.!~@#%*(),:' # no " \ ; [ ] $ (they'd change how the line is parsed)
VALID_TOKEN="mgst_$(printf 'a%.0s' {1..42})A"

setup() {
    setup_firmware
    E="$WORK/muse-gadget-sdk/esp32" # default SDK_DIR, under the path with a space
    mkdir -p "$E/devices" "$E/main" "$E/components/muse"
    export BUILD_DIR="$BATS_TEST_TMPDIR/build"
    export IDF_EXPORT="$BATS_TEST_TMPDIR/export.sh"
    : >"$IDF_EXPORT"
    stub idf.py
}

write_token() {
    printf 'CONFIG_GADGET_SDK_TOKEN="%s"\n' "$1" >"$WORK/sdkconfig.local-token"
}

# The -DSDKCONFIG_DEFAULTS value idf.py got on its last call.
defaults_arg() {
    calls idf.py | tail -1 | grep -o '\[-DSDKCONFIG_DEFAULTS=[^]]*\]' | sed 's/^\[-DSDKCONFIG_DEFAULTS=//; s/\]$//'
}

# --- token check -------------------------------------------------------------

@test "a valid token builds, with idf.py run in the SDK's esp32 directory" {
    write_token "$VALID_TOKEN"
    stub idf.py 'echo "cwd=$PWD" >> "$STUB_LOG"'
    run "$WORK/build.sh"
    assert_success
    assert_output --partial "Built in $BUILD_DIR"
    assert_equal "$(grep '^cwd=' "$STUB_LOG")" "cwd=$E"
    assert_equal "$(cat "$E/devices/sdkconfig.local-token")" "$(cat "$WORK/sdkconfig.local-token")"
    run calls idf.py
    assert_output --partial "[-B] [$BUILD_DIR] [-DIDF_TARGET=esp32s3] [-DSDKCONFIG=$BUILD_DIR/sdkconfig]"
    assert_output --regexp '\[build\]$'
}

@test "the host-tested sources in src/ are copied into the SDK's main component" {
    write_token "$VALID_TOKEN"
    run "$WORK/build.sh"
    assert_success
    for f in "$WORK"/src/*.c "$WORK"/src/*.h; do
        cmp "$f" "$E/main/$(basename "$f")" || fail "$(basename "$f") not copied"
    done
}

@test "the UTF-8 cuts in src/ are copied into the SDK's muse component" {
    write_token "$VALID_TOKEN"
    run "$WORK/build.sh"
    assert_success
    for f in "$WORK"/src/stackchan_utf8.c "$WORK"/src/stackchan_utf8.h; do
        cmp "$f" "$E/components/muse/$(basename "$f")" || fail "$(basename "$f") not copied"
    done
}

@test "missing sdkconfig.local-token: exit 1 with a hint, idf.py not run" {
    run "$WORK/build.sh"
    assert_failure 1
    assert_output --partial "Missing sdkconfig.local-token"
    assert_not_called idf.py
}

@test "SDK not set up: exit 1 and point at setup.sh" {
    rm -rf "$WORK/muse-gadget-sdk"
    write_token "$VALID_TOKEN"
    run "$WORK/build.sh"
    assert_failure 1
    assert_output --partial "Run ./setup.sh first."
    assert_not_called idf.py
}

@test "missing ESP-IDF: exit 1 and say where it was looked for" {
    write_token "$VALID_TOKEN"
    rm "$IDF_EXPORT"
    run "$WORK/build.sh"
    assert_failure 1
    assert_output --partial "ESP-IDF v6.0.1 not found at $IDF_EXPORT"
    assert_not_called idf.py
}

@test "token rule: build.sh agrees with the SDK's validate_config.cmake on random tokens" {
    command -v cmake >/dev/null || skip "needs cmake (the SDK's rule is a cmake regex)"
    local seed="${TOKEN_SEED:-$$}" n="${TOKEN_SAMPLES:-200}"
    RANDOM=$seed

    rand_from() { # rand_from SET COUNT
        local set="$1" i out=""
        for ((i = 0; i < $2; i++)); do out+="${set:RANDOM%${#set}:1}"; done
        printf '%s' "$out"
    }
    gen_token() {
        local t
        case $((RANDOM % 8)) in
            0 | 1) printf 'mgst_%s%s' "$(rand_from "$B64" 42)" "$(rand_from "$LAST" 1)" ;; # valid
            2) printf 'mgst_%s%s' "$(rand_from "$B64" 41)" "$(rand_from "$LAST" 1)" ;;     # one short
            3) printf 'mgst_%s%s' "$(rand_from "$B64" 43)" "$(rand_from "$LAST" 1)" ;;     # one long
            4) printf 'mgst_%s%s' "$(rand_from "$B64" 42)" "$(rand_from "$BAD_LAST" 1)" ;; # bad last
            5)
                t="mgst_$(rand_from "$B64" 42)$(rand_from "$LAST" 1)" # non-base64url
                local p=$((5 + RANDOM % 43))
                printf '%s%s%s' "${t:0:p}" "$(rand_from "$NOT_B64" 1)" "${t:p+1}"
                ;;
            6) printf 'mgst_%s' "$(rand_from "$B64" $((RANDOM % 60 + 1)))" ;; # any length
            7)
                t="mgst_"
                local p=$((RANDOM % 5)) # mangled prefix
                printf '%s%s%s%s' "${t:0:p}" "$(rand_from "$B64" 1)" "${t:p+1}" \
                    "$(rand_from "$B64" 42)$(rand_from "$LAST" 1)"
                ;;
        esac
    }

    local tokens="$BATS_TEST_TMPDIR/tokens" i
    : >"$tokens"
    for ((i = 0; i < n; i++)); do
        gen_token >>"$tokens"
        echo >>"$tokens"
    done

    local verdicts="$BATS_TEST_TMPDIR/verdicts"
    cmake -DTOKENS="$tokens" -P "$BATS_TEST_DIRNAME/sdk_token_rule.cmake" | sed 's/^-- //' >"$verdicts"
    assert_equal "$(wc -l <"$verdicts" | tr -d ' ')" "$n"

    local token sdk ours mismatches="" accepted=0 rejected=0
    while IFS= read -r token <&3 && IFS= read -r sdk <&4; do
        write_token "$token"
        if "$WORK/build.sh" >/dev/null 2>"$BATS_TEST_TMPDIR/err"; then
            ours=accept
        elif grep -q "not a valid mgst_ token" "$BATS_TEST_TMPDIR/err"; then
            ours=reject
        else
            fail "build.sh failed for another reason on '$token': $(cat "$BATS_TEST_TMPDIR/err")"
        fi
        [ "$sdk" = accept ] && accepted=$((accepted + 1)) || rejected=$((rejected + 1))
        [ "$ours" = "$sdk" ] || mismatches+="  '$token' (${#token} chars): SDK $sdk, build.sh $ours"$'\n'
    done 3<"$tokens" 4<"$verdicts"

    [ -z "$mismatches" ] || fail "build.sh and the SDK disagree (TOKEN_SEED=$seed):
$mismatches"
    # The generator must exercise both sides, or the test proves nothing.
    [ "$accepted" -gt 0 ] && [ "$rejected" -gt 0 ] ||
        fail "only one verdict in $n samples (accepted=$accepted, rejected=$rejected, TOKEN_SEED=$seed)"
}

@test "token rule: a commented-out token is not a token" {
    printf '# CONFIG_GADGET_SDK_TOKEN="%s"\n' "$VALID_TOKEN" >"$WORK/sdkconfig.local-token"
    run "$WORK/build.sh"
    assert_failure 1
    assert_output --partial "not a valid mgst_ token"
    assert_not_called idf.py
}

@test "token rule: a commented-out line above the real one is ignored" {
    printf '# CONFIG_GADGET_SDK_TOKEN="old"\nCONFIG_GADGET_SDK_TOKEN="%s"\n' "$VALID_TOKEN" \
        >"$WORK/sdkconfig.local-token"
    run "$WORK/build.sh"
    assert_success
}

@test "token rule: leading whitespace on the line is rejected" {
    printf '  CONFIG_GADGET_SDK_TOKEN="%s"\n' "$VALID_TOKEN" >"$WORK/sdkconfig.local-token"
    run "$WORK/build.sh"
    assert_failure 1
    assert_output --partial "not a valid mgst_ token"
}

@test "token rule: trailing whitespace after the closing quote is accepted" {
    printf 'CONFIG_GADGET_SDK_TOKEN="%s"   \n' "$VALID_TOKEN" >"$WORK/sdkconfig.local-token"
    run "$WORK/build.sh"
    assert_success
}

@test "token rule: whitespace inside the quotes is rejected" {
    for token in " $VALID_TOKEN" "$VALID_TOKEN "; do
        write_token "$token"
        run "$WORK/build.sh"
        assert_failure 1
        assert_output --partial "not a valid mgst_ token"
    done
}

# --- overlays ------------------------------------------------------------------

@test "without sdkconfig.local-tts: captions only, and a stale copy in the SDK is removed" {
    write_token "$VALID_TOKEN"
    echo stale >"$E/devices/sdkconfig.local-tts"
    run "$WORK/build.sh"
    assert_success
    assert_output --partial "Spoken replies: off"
    [ ! -e "$E/devices/sdkconfig.local-tts" ]
    run defaults_arg
    assert_output "sdkconfig.defaults;devices/sdkconfig.muse;devices/sdkconfig.muse-m5stack-cores3;devices/sdkconfig.muse-stackchan;devices/sdkconfig.local-token"
}

@test "with sdkconfig.local-tts: copied into the SDK and appended to SDKCONFIG_DEFAULTS" {
    write_token "$VALID_TOKEN"
    echo 'CONFIG_MUSE_TTS_URL="http://relay"' >"$WORK/sdkconfig.local-tts"
    run "$WORK/build.sh"
    assert_success
    assert_output --partial "Spoken replies: on"
    assert_equal "$(cat "$E/devices/sdkconfig.local-tts")" 'CONFIG_MUSE_TTS_URL="http://relay"'
    run defaults_arg
    assert_output --regexp ';devices/sdkconfig\.local-token;devices/sdkconfig\.local-tts'
}

@test "a stale generated sdkconfig in the build directory is removed before building" {
    write_token "$VALID_TOKEN"
    mkdir -p "$BUILD_DIR"
    echo 'CONFIG_OLD=y' >"$BUILD_DIR/sdkconfig"
    run "$WORK/build.sh"
    assert_success
    [ ! -e "$BUILD_DIR/sdkconfig" ]
}

# --- WAKE_WORD (PR #1) -----------------------------------------------------------

needs_wake_word() {
    grep -q WAKE_WORD "$FIRMWARE_SRC/build.sh" || skip "build.sh has no WAKE_WORD yet (PR #1)"
}

@test "WAKE_WORD: anything but himuse or histackchan fails before idf.py" {
    needs_wake_word
    write_token "$VALID_TOKEN"
    for w in hello HiMuse ""; do
        WAKE_WORD="$w" run "$WORK/build.sh"
        if [ -z "$w" ]; then
            assert_success # empty means "use the default"
        else
            assert_failure 1
            assert_output --partial "WAKE_WORD must be himuse or histackchan"
        fi
    done
    assert_equal "$(calls idf.py | wc -l | tr -d ' ')" 1
}

@test "WAKE_WORD: histackchan writes sdkconfig.local-wake, himuse removes it again" {
    needs_wake_word
    write_token "$VALID_TOKEN"

    WAKE_WORD=histackchan run "$WORK/build.sh"
    assert_success
    assert_output --partial "Wake word: histackchan"
    run cat "$E/devices/sdkconfig.local-wake"
    assert_output --partial "CONFIG_SR_WN_WN9L_HISTACKCHAN_TTS3=y"
    run defaults_arg
    assert_output --regexp ';devices/sdkconfig\.local-wake$'

    WAKE_WORD=himuse run "$WORK/build.sh"
    assert_success
    [ ! -e "$E/devices/sdkconfig.local-wake" ]
    run defaults_arg
    refute_output --partial "sdkconfig.local-wake"
}

@test "WAKE_WORD: the default is himuse" {
    needs_wake_word
    write_token "$VALID_TOKEN"
    run "$WORK/build.sh"
    assert_success
    assert_output --partial "Wake word: himuse"
    [ ! -e "$E/devices/sdkconfig.local-wake" ]
}

# --- dependencies.lock (#7) --------------------------------------------------

@test "lock unchanged by the build: no warning" {
    write_token "$VALID_TOKEN"
    echo pinned >"$E/dependencies.lock"
    run "$WORK/build.sh"
    assert_success
    refute_output --partial "dependencies.lock changed"
}

@test "lock rewritten by the build: warning locally, still succeeds" {
    write_token "$VALID_TOKEN"
    echo pinned >"$E/dependencies.lock"
    stub idf.py 'echo resolved-again > dependencies.lock'
    CI=false run "$WORK/build.sh"
    assert_success
    assert_output --partial "Warning: dependencies.lock changed"
}

@test "lock rewritten by the build: fails in CI" {
    write_token "$VALID_TOKEN"
    echo pinned >"$E/dependencies.lock"
    stub idf.py 'echo resolved-again > dependencies.lock'
    CI=true run "$WORK/build.sh"
    assert_failure 1
    assert_output --partial "Error: dependencies.lock changed"
}
