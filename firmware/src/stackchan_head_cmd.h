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

// Checks head.* command arguments and builds error replies. No FreeRTOS here
// so the host tests and fuzzer can run it.

#include <stdbool.h>

#include "cJSON.h"

#ifdef __cplusplus
extern "C" {
#endif

#define DURATION_MIN_MS 100
#define DURATION_MAX_MS 3000
#define DURATION_DEF_MS 600

// Longest request_id a head command keeps for its async reply. A longer one
// would have to be cut, and Muse couldn't match the reply, so it's refused.
#define HEAD_REQUEST_ID_MAX 63

typedef enum { HEAD_MOVE, HEAD_GESTURE, HEAD_GET } head_op_t;
typedef enum { GESTURE_NOD, GESTURE_SHAKE, GESTURE_LOOK_AROUND, GESTURE_HOME } gesture_t;

typedef struct {
    head_op_t op;
    float yaw, pitch;   // HEAD_MOVE: finite, not yet clamped to the neck's range
    int duration_ms;    // HEAD_MOVE: always DURATION_MIN_MS..DURATION_MAX_MS
    gesture_t gesture;  // HEAD_GESTURE
} head_cmd_t;

typedef enum {
    HEAD_CMD_OK,
    HEAD_CMD_NOT_HEAD,       // not a head.* command; someone else handles it
    HEAD_CMD_MISSING_PARAM,
    HEAD_CMD_INVALID_PARAM,
} head_cmd_status_t;

// Reads command and params into *out. params may be NULL or any JSON value.
head_cmd_status_t head_cmd_parse(const char *command, const cJSON *params,
                                 head_cmd_t *out);

// {"ok": false, "error": {"code": ..., "message": ...}} for a status other
// than HEAD_CMD_OK / HEAD_CMD_NOT_HEAD.
cJSON *head_cmd_status_error(head_cmd_status_t status);

// True if request_id (NULL counts as "") is at most HEAD_REQUEST_ID_MAX bytes.
bool head_cmd_request_id_ok(const char *request_id);

// {"ok": false, "error": {"code": code, "message": message}}.
cJSON *head_cmd_error(const char *code, const char *message);

#ifdef __cplusplus
}
#endif
