// Properties of the degree <-> servo step conversion (issue #17, part 2).
#include <math.h>

#include "prop.h"
#include "stackchan_angle.h"

static const float TOL = 0.5f / RAW_PER_DEG + 1e-4f;  // half a step, plus float slack

// The ends of the neck's range must map inside 0..1000 without clamping, or a
// constant change has made part of the range unreachable.
static void test_range_inside_servo(void) {
    const struct { int zero; float min, max; } axes[] = {
        {YAW_ZERO_RAW, YAW_MIN_DEG, YAW_MAX_DEG},
        {PITCH_ZERO_RAW, PITCH_MIN_DEG, PITCH_MAX_DEG},
    };
    for (int i = 0; i < 2; i++) {
        int zero = axes[i].zero;
        float lo = (float)zero + axes[i].min * RAW_PER_DEG, hi = (float)zero + axes[i].max * RAW_PER_DEG;
        CHECK(lo >= RAW_MIN && hi <= RAW_MAX, "axis %d maps to %.1f..%.1f", i, lo, hi);
        CHECK(fabsf(raw_to_deg(zero, deg_to_raw(zero, axes[i].min)) - axes[i].min) <= TOL, "axis %d min", i);
        CHECK(fabsf(raw_to_deg(zero, deg_to_raw(zero, axes[i].max)) - axes[i].max) <= TOL, "axis %d max", i);
    }
}

static void test_special_values(void) {
    CHECK(deg_to_raw(YAW_ZERO_RAW, NAN) == YAW_ZERO_RAW, "NaN");
    CHECK(deg_to_raw(YAW_ZERO_RAW, INFINITY) == RAW_MAX, "+Inf");
    CHECK(deg_to_raw(YAW_ZERO_RAW, -INFINITY) == RAW_MIN, "-Inf");
    CHECK(deg_to_raw(YAW_ZERO_RAW, 3e38f) == RAW_MAX, "huge");
    CHECK(clampf(NAN, 1, 2) == 1, "clampf NaN");
    CHECK(clampf(-INFINITY, 1, 2) == 1 && clampf(INFINITY, 1, 2) == 2, "clampf Inf");
}

// Any float, any zero in 0..1000: result in 0..1000. With every bit pattern
// when PROP_EXHAUSTIVE=1 (about 4 billion floats per zero; a minute or so).
static void prop_always_in_servo_range(void) {
    const int zeros[] = {YAW_ZERO_RAW, PITCH_ZERO_RAW, 0, RAW_MAX};
    const char *ex = getenv("PROP_EXHAUSTIVE");
    if (ex && *ex == '1') {
        for (int z = 0; z < 2; z++) {
            uint32_t bits = 0;
            do {
                float f;
                memcpy(&f, &bits, sizeof(f));
                int raw = deg_to_raw(zeros[z], f);
                if (raw < RAW_MIN || raw > RAW_MAX) CHECK(0, "bits=0x%08x raw=%d", bits, raw);
            } while (++bits != 0);
        }
        printf("exhaustive float sweep done\n");
    }
    for (long r = 0; r < prop_runs * 10; r++) {
        int zero = r < 4 ? zeros[r] : (int)prop_below(RAW_MAX + 1);
        float f = prop_any_float();
        int raw = deg_to_raw(zero, f);
        CHECK(raw >= RAW_MIN && raw <= RAW_MAX, "zero=%d deg=%g raw=%d", zero, f, raw);
    }
}

// Inside the neck's range: monotonic, and raw_to_deg undoes deg_to_raw to
// within half a step.
static void check_axis(int zero, float lo, float hi, const char *axis) {
    for (long r = 0; r < prop_runs; r++) {
        float a = prop_float_in(lo, hi), b = prop_float_in(lo, hi);
        if (a > b) { float t = a; a = b; b = t; }
        CHECK(deg_to_raw(zero, a) <= deg_to_raw(zero, b), "%s: %g -> %d, %g -> %d", axis,
              a, deg_to_raw(zero, a), b, deg_to_raw(zero, b));
        float back = raw_to_deg(zero, deg_to_raw(zero, a));
        CHECK(fabsf(back - a) <= TOL, "%s: %g -> %g", axis, a, back);
    }
    // And walking the range in small steps never goes backwards.
    int prev = deg_to_raw(zero, lo);
    for (float d = lo; d <= hi; d += 0.01f) {
        int raw = deg_to_raw(zero, d);
        CHECK(raw >= prev, "%s: not monotonic at %g", axis, d);
        prev = raw;
    }
}

int main(void) {
    prop_init();
    test_range_inside_servo();
    test_special_values();
    prop_always_in_servo_range();
    check_axis(YAW_ZERO_RAW, YAW_MIN_DEG, YAW_MAX_DEG, "yaw");
    check_axis(PITCH_ZERO_RAW, PITCH_MIN_DEG, PITCH_MAX_DEG, "pitch");
    return prop_done("test_angle");
}
