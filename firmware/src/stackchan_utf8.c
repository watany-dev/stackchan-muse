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

#include "stackchan_utf8.h"

#include <string.h>

static int is_cont(unsigned char c) { return (c & 0xC0) == 0x80; }

// Length of the sequence a lead byte starts; 1 for ASCII and for bytes that
// can't start one (left alone: trimming only deals with cut characters).
static size_t seq_len(unsigned char c) {
    if (c >= 0xF0 && c <= 0xF7) return 4;
    if (c >= 0xE0) return c <= 0xEF ? 3 : 1;
    if (c >= 0xC0) return 2;
    return 1;
}

static size_t trim_tail_n(char *s, size_t n) {
    size_t k = 0;  // continuation bytes at the end
    while (k < 3 && k < n && is_cont((unsigned char)s[n - 1 - k])) k++;
    if (k == n) return n;  // nothing but continuation bytes: not a cut character
    size_t lead = n - 1 - k;
    if (k + 1 < seq_len((unsigned char)s[lead])) {
        s[lead] = '\0';
        return lead;
    }
    return n;
}

size_t utf8_trim_tail(char *s) { return trim_tail_n(s, strlen(s)); }

size_t utf8_trim_head(char *s) {
    size_t n = strlen(s), k = 0;
    while (k < 3 && k < n && is_cont((unsigned char)s[k])) k++;
    if (k) memmove(s, s + k, n - k + 1);
    return n - k;
}

bool utf8_strlcat(char *dst, const char *src, size_t cap) {
    size_t have = strnlen(dst, cap);
    if (have >= cap) return false;
    size_t add = strlen(src), room = cap - 1 - have;
    if (add <= room) {
        memcpy(dst + have, src, add + 1);
        return true;
    }
    memcpy(dst + have, src, room);
    dst[have + room] = '\0';
    trim_tail_n(dst, have + room);
    return false;
}
