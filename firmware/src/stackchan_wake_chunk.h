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

// Cutting idle mic audio into WakeNet-sized chunks (issue #17). The mic hands
// over 20 ms reads, WakeNet wants its own chunk size, so audio is gathered in
// a buffer and each full chunk goes to the detector. After a reset the
// detector's window still holds the old audio, so detections are ignored for
// about 1.5 s. No ESP-SR here: the detector is a callback, so the host tests
// can run it with a fake.

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Samples (16 kHz) whose detections are ignored after wake_chunk_reset.
#define WAKE_CHUNK_SETTLE_SAMPLES (16000 * 3 / 2)

// Runs the detector on one full chunk; true when the wake word was detected.
typedef bool (*wake_chunk_detect_fn)(void *ctx, int16_t *chunk);

typedef struct {
    int16_t *buf;    // room for one chunk, owned by the caller
    size_t chunk;    // samples per chunk; 0 means no model
    size_t fill;     // samples gathered in buf so far
    int ignore;      // chunks still to run without acting on
    wake_chunk_detect_fn detect;
    void *ctx;
} wake_chunk_t;

// Sets up c. With buf NULL or chunk 0 (no model) feeding is a no-op.
void wake_chunk_init(wake_chunk_t *c, int16_t *buf, size_t chunk, wake_chunk_detect_fn detect, void *ctx);

// Feeds frames samples; every full chunk goes to the detector. True if a
// detection counted (one outside the settle period after a reset).
bool wake_chunk_feed(wake_chunk_t *c, const int16_t *pcm, size_t frames);

// Drops the partly filled chunk and starts the settle period.
void wake_chunk_reset(wake_chunk_t *c);

#ifdef __cplusplus
}
#endif
