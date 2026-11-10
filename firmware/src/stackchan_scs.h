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

// Feetech SCS servo packets, without any UART code so the host tests can run
// them. Request:  FF FF id len inst [addr data...] ~sum
//        Status:  FF FF id len err  [data...]      ~sum
// len counts the bytes after itself; the checksum covers id through the last
// data byte.

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define SCS_INST_READ   0x02
#define SCS_INST_WRITE  0x03

#define SCS_DATA_MAX    9   // request payload after addr
#define SCS_PKT_MAX     (7 + SCS_DATA_MAX)
#define SCS_REPLY_MAX   8   // status payload we accept

typedef struct {
    uint8_t id;
    uint8_t err;   // servo status bits
    uint8_t n;     // bytes in data
    uint8_t data[SCS_REPLY_MAX];
} scs_reply_t;

typedef enum {
    SCS_PARSE_BAD = -1,       // a header was found but what follows is wrong
    SCS_PARSE_NEED_MORE = 0,  // no complete packet yet
    SCS_PARSE_OK = 1,
} scs_parse_result_t;

// Writes one request into out (out_cap bytes). Returns its length, or 0 when
// n > SCS_DATA_MAX, data is NULL with n > 0, or out is too small.
size_t scs_build(uint8_t id, uint8_t inst, uint8_t addr,
                 const uint8_t *data, uint8_t n,
                 uint8_t *out, size_t out_cap);

// Writes one status packet (what a servo sends back). Used by the tests and
// handy for a fake servo. Same return rules as scs_build, with SCS_REPLY_MAX.
size_t scs_build_status(uint8_t id, uint8_t err,
                        const uint8_t *data, uint8_t n,
                        uint8_t *out, size_t out_cap);

// Looks for a status packet in the first len bytes of buf. Bytes before the
// first FF FF are skipped, as are extra FFs after it (0xFF is the broadcast
// id, never a reply). Only that first header is tried: if what follows is
// wrong the result is SCS_PARSE_BAD, not a search for a later header.
// On SCS_PARSE_OK, *reply holds the packet and *consumed (when given) is the
// number of bytes up to and including its checksum.
scs_parse_result_t scs_parse(const uint8_t *buf, size_t len,
                             scs_reply_t *reply, size_t *consumed);

#ifdef __cplusplus
}
#endif
