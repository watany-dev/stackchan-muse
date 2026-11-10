#!/usr/bin/env bats
# env.sh: find_port and paths with spaces. `ls` is stubbed to stand in for /dev.

load test_helper

setup() {
    setup_firmware
}

# Sources env.sh from the copy, runs find_port and prints the result.
run_find_port() {
    run bash -c '. "$1/env.sh"; find_port; echo "PORT=$PORT"' _ "$WORK"
}

@test "PORT set: used as is, /dev not searched" {
    stub ls 'echo /dev/ttyACM9'
    PORT=/dev/my-board run_find_port
    assert_success
    assert_line "Using port /dev/my-board"
    assert_line "PORT=/dev/my-board"
    assert_not_called ls
}

@test "no PORT and no board: exit 1 with a hint" {
    stub ls 'exit 2'   # what ls does when no glob matched
    run_find_port
    assert_failure 1
    assert_output --partial "No board found"
    refute_line --regexp "^PORT="
}

@test "no PORT and several boards: the first one" {
    stub ls 'printf "%s\n" /dev/cu.usbmodem1101 /dev/cu.usbmodem2201 /dev/ttyACM0'
    run_find_port
    assert_success
    assert_line "PORT=/dev/cu.usbmodem1101"
}

@test "no PORT: looks for both macOS and Linux device names" {
    stub ls 'echo /dev/ttyACM0'
    run_find_port
    assert_success
    run calls ls
    assert_output --partial "/dev/cu.usbmodem"
    assert_output --partial "/dev/ttyACM"
}

@test "HERE and the default SDK_DIR keep a path with spaces intact" {
    run bash -c 'cd /; . "$1/env.sh"; printf "%s\n" "$HERE" "$SDK_DIR"' _ "$WORK"
    assert_success
    assert_line --index 0 "$WORK"
    assert_line --index 1 "$WORK/muse-gadget-sdk"
}

@test "HERE is the scripts' directory even when sourced from elsewhere" {
    run bash -c 'cd "$1/.."; . firmware/env.sh; echo "$HERE"' _ "$WORK"
    assert_success
    assert_output "$WORK"
}
