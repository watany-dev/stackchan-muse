#!/usr/bin/env bats
# restore.sh overwrites the whole flash, so every bad input must stop it
# before esptool runs. esptool is a stub.

load test_helper

setup() {
    setup_firmware
    stub esptool
    export ESPTOOL="$STUBS/esptool" PORT=/dev/fake-port
    GOOD="$BATS_TEST_TMPDIR/my backups/stackchan_backup.bin"
    mkdir -p "$(dirname "$GOOD")"
    make_file_of_size "$GOOD" 16777216
}

@test "no argument: usage, esptool not called" {
    run "$WORK/restore.sh"
    assert_failure 1
    assert_output --partial "usage:"
    assert_not_called esptool
}

@test "two arguments: usage, esptool not called" {
    run "$WORK/restore.sh" "$GOOD" "$GOOD"
    assert_failure 1
    assert_output --partial "usage:"
    assert_not_called esptool
}

@test "a file that doesn't exist: usage, esptool not called" {
    run "$WORK/restore.sh" "$BATS_TEST_TMPDIR/nope.bin"
    assert_failure 1
    assert_output --partial "usage:"
    assert_not_called esptool
}

@test "a directory: usage, esptool not called" {
    run "$WORK/restore.sh" "$BATS_TEST_TMPDIR"
    assert_failure 1
    assert_output --partial "usage:"
    assert_not_called esptool
}

@test "anything but 16,777,216 bytes: refused, esptool not called" {
    for size in 0 1 16777215 16777217 33554432; do
        make_file_of_size "$BATS_TEST_TMPDIR/b.bin" "$size"
        run "$WORK/restore.sh" "$BATS_TEST_TMPDIR/b.bin"
        assert_failure 1
        assert_output --partial "is not a 16 MB backup"
    done
    assert_not_called esptool
}

@test "a 16 MB file: write-flash 0 <file> on the chosen port, once" {
    run "$WORK/restore.sh" "$GOOD"
    assert_success
    run calls esptool
    assert_output "esptool [--port] [/dev/fake-port] [--baud] [460800] [write-flash] [0] [$GOOD]"
}

@test "no board: fails after the checks, esptool not called" {
    unset PORT
    stub ls 'exit 2'
    run "$WORK/restore.sh" "$GOOD"
    assert_failure 1
    assert_output --partial "No board found"
    assert_not_called esptool
}

@test "esptool failing makes restore.sh fail" {
    stub esptool 'exit 3'
    run "$WORK/restore.sh" "$GOOD"
    assert_failure 3
}
