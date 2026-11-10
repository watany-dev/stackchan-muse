/*
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include "stackchan_angle.h"

#include <math.h>

static int clampi(int v, int lo, int hi) {
    return v < lo ? lo : (v > hi ? hi : v);
}

float clampf(float v, float lo, float hi) {
    if (!(v >= lo)) return lo;  // also NaN
    return v > hi ? hi : v;
}

int deg_to_raw(int zero, float deg) {
    if (isnan(deg)) return clampi(zero, RAW_MIN, RAW_MAX);
    // Clamp before rounding so lroundf never sees a value that overflows.
    float steps = clampf(deg * RAW_PER_DEG, -2.0f * RAW_MAX, 2.0f * RAW_MAX);
    return clampi(zero + (int)lroundf(steps), RAW_MIN, RAW_MAX);
}

float raw_to_deg(int zero, int raw) {
    return (float)(raw - zero) / RAW_PER_DEG;
}
