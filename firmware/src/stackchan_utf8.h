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

// Cutting text at UTF-8 character boundaries (issue #12). Byte-wise cuts
// (strlcat into a fixed buffer) can split a character; cJSON passes the broken
// bytes on and the TTS relay rejects the request. No hardware here so the host
// tests can check it.

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Drops an incomplete UTF-8 sequence at the end of s (at most 3 bytes) and
// returns the new length. Text that ends on a whole character is unchanged.
size_t utf8_trim_tail(char *s);

// Drops continuation bytes at the start of s (at most 3), left when the front
// of a character was cut off, and returns the new length.
size_t utf8_trim_head(char *s);

// Like strlcat(dst, src, cap), but when src doesn't fit the cut lands on a
// character boundary. Returns true if all of src was appended. src may end
// in the middle of a character (streamed text); that is kept as is so the
// next call can finish it. Nothing is appended when dst is not a string
// shorter than cap.
bool utf8_strlcat(char *dst, const char *src, size_t cap);

#ifdef __cplusplus
}
#endif
