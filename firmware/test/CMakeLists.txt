# Host tests for the hardware-free firmware code in ../src (issue #17).
#
#   cmake -S firmware/test -B build/host-test && cmake --build build/host-test
#   ctest --test-dir build/host-test --output-on-failure
#
# Fuzzers (clang only): add -DSTACKCHAN_FUZZ=ON -DCMAKE_C_COMPILER=clang.
cmake_minimum_required(VERSION 3.20)
project(stackchan_host_test C)

option(STACKCHAN_SANITIZE "Build with AddressSanitizer and UBSan" ON)
option(STACKCHAN_FUZZ "Build the libFuzzer targets (needs clang)" OFF)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS ON)
set(SRC ${CMAKE_CURRENT_SOURCE_DIR}/../src)

# The firmware gets cJSON from ESP-IDF; here we fetch a pinned release.
include(FetchContent)
FetchContent_Declare(cjson
    GIT_REPOSITORY https://github.com/DaveGamble/cJSON.git
    GIT_TAG acc76239bee01d8e9c858ae2cab296704e52d916  # v1.7.18
    GIT_SHALLOW FALSE
    SOURCE_SUBDIR no-cmake)  # only the sources; skip cJSON's own build
FetchContent_MakeAvailable(cjson)

add_compile_options(-Wall -Wextra -Werror -Wshadow -Wconversion -Wno-sign-conversion)
if(STACKCHAN_SANITIZE)
    set(SAN -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer)
    if(CMAKE_C_COMPILER_ID MATCHES "Clang")
        list(APPEND SAN -fsanitize=float-cast-overflow)
    endif()
    add_compile_options(${SAN})
    add_link_options(${SAN})
endif()

# The libraries are built once per flavour: plain for the tests, and with
# coverage instrumentation for the fuzzers so libFuzzer can see inside them.
function(stackchan_libs suffix)
    add_library(cjson${suffix} STATIC ${cjson_SOURCE_DIR}/cJSON.c)
    target_include_directories(cjson${suffix} PUBLIC ${cjson_SOURCE_DIR})
    target_compile_options(cjson${suffix} PRIVATE -w ${ARGN})
    if(STACKCHAN_SANITIZE AND CMAKE_C_COMPILER_ID MATCHES "Clang")
        # cJSON_CreateNumber(NAN) casts NaN to int for valueint; that's cJSON's,
        # and only the tests' random generator makes such numbers.
        target_compile_options(cjson${suffix} PRIVATE -fno-sanitize=float-cast-overflow)
    endif()

    add_library(stackchan_core${suffix} STATIC
        ${SRC}/stackchan_scs.c
        ${SRC}/stackchan_angle.c
        ${SRC}/stackchan_head_cmd.c)
    target_include_directories(stackchan_core${suffix} PUBLIC ${SRC})
    target_compile_options(stackchan_core${suffix} PRIVATE ${ARGN})
    target_link_libraries(stackchan_core${suffix} PUBLIC cjson${suffix} m)
endfunction()

stackchan_libs("")

enable_testing()
foreach(t test_scs test_angle test_head_cmd)
    add_executable(${t} ${t}.c)
    target_link_libraries(${t} PRIVATE stackchan_core)
    add_test(NAME ${t} COMMAND ${t})
endforeach()

if(STACKCHAN_FUZZ)
    if(NOT CMAKE_C_COMPILER_ID MATCHES "Clang")
        message(FATAL_ERROR "STACKCHAN_FUZZ needs clang (-DCMAKE_C_COMPILER=clang)")
    endif()
    stackchan_libs(_fuzz -fsanitize=fuzzer-no-link)
    foreach(f fuzz_scs_parse fuzz_head_cmd)
        add_executable(${f} fuzz/${f}.c)
        target_compile_options(${f} PRIVATE -fsanitize=fuzzer)
        target_link_options(${f} PRIVATE -fsanitize=fuzzer)
        target_link_libraries(${f} PRIVATE stackchan_core_fuzz)
    endforeach()
endif()
