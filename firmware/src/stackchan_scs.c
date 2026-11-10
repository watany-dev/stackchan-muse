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

#include "stackchan_scs.h"

#include <string.h>

static size_t put_packet(uint8_t id, uint8_t code, const uint8_t *pre, uint8_t pre_n,
                         const uint8_t *data, uint8_t n,
                         uint8_t *out, size_t out_cap) {
    size_t total = 6u + pre_n + n;
    if (!out || out_cap < total || (n && !data)) return 0;
    uint8_t len = (uint8_t)(2 + pre_n + n);
    out[0] = 0xFF;
    out[1] = 0xFF;
    out[2] = id;
    out[3] = len;
    out[4] = code;
    uint8_t sum = (uint8_t)(id + len + code);
    size_t at = 5;
    for (uint8_t i = 0; i < pre_n; i++) {
        out[at++] = pre[i];
        sum = (uint8_t)(sum + pre[i]);
    }
    for (uint8_t i = 0; i < n; i++) {
        out[at++] = data[i];
        sum = (uint8_t)(sum + data[i]);
    }
    out[at++] = (uint8_t)~sum;
    return at;
}

size_t scs_build(uint8_t id, uint8_t inst, uint8_t addr,
                 const uint8_t *data, uint8_t n,
                 uint8_t *out, size_t out_cap) {
    if (n > SCS_DATA_MAX) return 0;
    return put_packet(id, inst, &addr, 1, data, n, out, out_cap);
}

size_t scs_build_status(uint8_t id, uint8_t err,
                        const uint8_t *data, uint8_t n,
                        uint8_t *out, size_t out_cap) {
    if (n > SCS_REPLY_MAX) return 0;
    return put_packet(id, err, NULL, 0, data, n, out, out_cap);
}

scs_parse_result_t scs_parse(const uint8_t *buf, size_t len,
                             scs_reply_t *reply, size_t *consumed) {
    if (!buf || !reply) return SCS_PARSE_BAD;

    // Sync on FF FF.
    size_t i = 0;
    for (;;) {
        if (i + 1 >= len) return SCS_PARSE_NEED_MORE;
        if (buf[i] == 0xFF && buf[i + 1] == 0xFF) break;
        i++;
    }
    i += 2;
    while (i < len && buf[i] == 0xFF) i++;

    // id len err
    if (len - i < 3) return SCS_PARSE_NEED_MORE;
    uint8_t id = buf[i], plen = buf[i + 1], err = buf[i + 2];
    if (plen < 2) return SCS_PARSE_BAD;
    uint8_t n = (uint8_t)(plen - 2);
    if (n > SCS_REPLY_MAX) return SCS_PARSE_BAD;

    // data, checksum
    if (len - i < 3u + n + 1u) return SCS_PARSE_NEED_MORE;
    uint8_t sum = (uint8_t)(id + plen + err);
    for (uint8_t k = 0; k < n; k++) sum = (uint8_t)(sum + buf[i + 3 + k]);
    if ((uint8_t)~sum != buf[i + 3 + n]) return SCS_PARSE_BAD;

    reply->id = id;
    reply->err = err;
    reply->n = n;
    memcpy(reply->data, buf + i + 3, n);
    if (consumed) *consumed = i + 3 + n + 1;
    return SCS_PARSE_OK;
}
