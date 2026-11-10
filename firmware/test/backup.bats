#!/usr/bin/env bats
# backup.sh must verify what it read, and must fail loudly when that fails
# (it relies on set -e for this). esptool is a stub.

load test_helper

setup() {
    setup_firmware
    # read-flash writes a 16 MB file; verify-flash fails when STUB_VERIFY_FAIL is set.
    stub esptool '
case "$5" in
    read-flash)   [ -z "${STUB_READ_FAIL:-}" ] || exit 4
                  dd if=/dev/zero of="$8" bs=1 count=0 seek=16777216 2>/dev/null ;;
    verify-flash) [ -z "${STUB_VERIFY_FAIL:-}" ] || exit 5 ;;
esac'
    export ESPTOOL="$STUBS/esptool" PORT=/dev/fake-port
    OUT="$BATS_TEST_TMPDIR/my backups/stackchan.bin"
    mkdir -p "$(dirname "$OUT")"
}

@test "read-flash of all 16 MB, then verify-flash of the same file, then the checksum" {
    run "$WORK/backup.sh" "$OUT"
    assert_success
    assert_output --partial "Backup: $OUT"
    assert_output --regexp '[0-9a-f]{64}  '
    run calls esptool
    assert_line --index 0 "esptool [--port] [/dev/fake-port] [--baud] [460800] [read-flash] [0] [0x1000000] [$OUT]"
    assert_line --index 1 "esptool [--port] [/dev/fake-port] [--baud] [460800] [verify-flash] [0] [$OUT]"
    assert_equal "${#lines[@]}" 2
}

@test "verify-flash failing: non-zero exit and no 'Backup:' line" {
    STUB_VERIFY_FAIL=1 run "$WORK/backup.sh" "$OUT"
    assert_failure 5
    refute_output --partial "Backup:"
}

@test "read-flash failing: verify-flash is not run, non-zero exit" {
    STUB_READ_FAIL=1 run "$WORK/backup.sh" "$OUT"
    assert_failure 4
    refute_output --partial "Backup:"
    run calls esptool
    refute_output --partial "verify-flash"
}

@test "without an argument: a timestamped file in the current directory" {
    cd "$BATS_TEST_TMPDIR"
    run "$WORK/backup.sh"
    assert_success
    run calls esptool
    assert_line --index 0 --regexp '\[read-flash\] \[0\] \[0x1000000\] \[stackchan_backup_[0-9]{8}_[0-9]{6}\.bin\]$'
}

@test "no board: fails before esptool" {
    unset PORT
    stub ls 'exit 2'
    run "$WORK/backup.sh" "$OUT"
    assert_failure 1
    assert_output --partial "No board found"
    assert_not_called esptool
}
