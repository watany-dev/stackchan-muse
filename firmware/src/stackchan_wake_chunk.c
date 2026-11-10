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

#include "stackchan_wake_chunk.h"

#include <string.h>

void wake_chunk_init(wake_chunk_t *c, int16_t *buf, size_t chunk, wake_chunk_detect_fn detect, void *ctx)
{
    c->buf = buf;
    c->chunk = buf && detect ? chunk : 0;
    c->fill = 0;
    c->ignore = 0;
    c->detect = detect;
    c->ctx = ctx;
}

bool wake_chunk_feed(wake_chunk_t *c, const int16_t *pcm, size_t frames)
{
    if (c->chunk == 0) {
        return false;
    }
    bool heard = false;
    while (frames) {
        size_t take = c->chunk - c->fill < frames ? c->chunk - c->fill : frames;
        memcpy(c->buf + c->fill, pcm, take * sizeof(int16_t));
        c->fill += take;
        pcm += take;
        frames -= take;
        if (c->fill == c->chunk) {
            c->fill = 0;
            if (c->detect(c->ctx, c->buf) && c->ignore <= 0) {
                heard = true;
            }
            if (c->ignore > 0) {
                c->ignore--;
            }
        }
    }
    return heard;
}

void wake_chunk_reset(wake_chunk_t *c)
{
    c->fill = 0;
    c->ignore = c->chunk ? (int)(WAKE_CHUNK_SETTLE_SAMPLES / c->chunk) : 0;
}
