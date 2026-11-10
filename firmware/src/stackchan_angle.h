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

#pragma once

// Neck geometry and the degree <-> servo step conversion. No hardware here so
// the host tests can check it.

#ifdef __cplusplus
extern "C" {
#endif

#define YAW_ID          1
#define PITCH_ID        2
#define YAW_ZERO_RAW    460
#define PITCH_ZERO_RAW  620
#define YAW_MIN_DEG     (-128.0f)
#define YAW_MAX_DEG     128.0f
#define PITCH_MIN_DEG   0.0f
#define PITCH_MAX_DEG   90.0f
#define RAW_PER_DEG     3.2f  // one step is 0.3125 degrees
#define RAW_MIN         0
#define RAW_MAX         1000

// v limited to [lo, hi]. NaN gives lo.
float clampf(float v, float lo, float hi);

// Servo position for deg degrees from zero. Always in [RAW_MIN, RAW_MAX],
// for any float: +-Inf go to the ends, NaN to zero (clamped).
int deg_to_raw(int zero, float deg);

float raw_to_deg(int zero, int raw);

#ifdef __cplusplus
}
#endif
