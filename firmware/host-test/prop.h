// Tiny test helpers: CHECK, and a seeded random source for property tests.
// PROP_SEED fixes the seed (printed on every run) and PROP_RUNS the number of
// cases per property, so a failure in CI can be replayed locally.
#pragma once

#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static int prop_failures;
static uint64_t prop_state;
static long prop_runs = 10000;

#define CHECK(cond, ...)                                                    \
    do {                                                                    \
        if (!(cond)) {                                                      \
            prop_failures++;                                                \
            fprintf(stderr, "%s:%d: CHECK(%s) failed: ", __FILE__, __LINE__, \
                    #cond);                                                 \
            fprintf(stderr, __VA_ARGS__);                                   \
            fprintf(stderr, "\n");                                          \
            if (prop_failures > 20) {                                       \
                fprintf(stderr, "too many failures\n");                     \
                exit(1);                                                    \
            }                                                               \
        }                                                                   \
    } while (0)

static inline void prop_init(void) {
    const char *s = getenv("PROP_SEED");
    prop_state = s && *s ? strtoull(s, NULL, 0) : (uint64_t)time(NULL);
    const char *r = getenv("PROP_RUNS");
    if (r && *r) prop_runs = strtol(r, NULL, 0);
    printf("PROP_SEED=%" PRIu64 " PROP_RUNS=%ld\n", prop_state, prop_runs);
    if (prop_state == 0) prop_state = 1;
}

// splitmix64
static inline uint64_t prop_u64(void) {
    uint64_t z = (prop_state += 0x9E3779B97F4A7C15ull);
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ull;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBull;
    return z ^ (z >> 31);
}

static inline uint32_t prop_below(uint32_t n) { return n ? (uint32_t)(prop_u64() % n) : 0; }
static inline uint8_t prop_byte(void) { return (uint8_t)prop_u64(); }

// Uniform in [lo, hi).
static inline float prop_float_in(float lo, float hi) {
    return lo + (hi - lo) * ((float)(uint32_t)(prop_u64() >> 40) / 16777216.0f);
}

// Any bit pattern: NaNs, infinities, subnormals included.
static inline float prop_any_float(void) {
    uint32_t bits = (uint32_t)prop_u64();
    float f;
    memcpy(&f, &bits, sizeof(f));
    return f;
}

static inline int prop_done(const char *name) {
    if (prop_failures) {
        fprintf(stderr, "%s: %d failure(s)\n", name, prop_failures);
        return 1;
    }
    printf("%s: ok\n", name);
    return 0;
}
