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

#include "stackchan_head_cmd.h"

#include <math.h>
#include <string.h>

static bool number_param(const cJSON *params, const char *key, float *out) {
    const cJSON *item = cJSON_IsObject(params) ? cJSON_GetObjectItem(params, key) : NULL;
    if (!cJSON_IsNumber(item) || !isfinite(item->valuedouble)) return false;
    // A finite double can still be beyond float; keep it finite.
    double v = item->valuedouble;
    if (v > 1e30) v = 1e30;
    if (v < -1e30) v = -1e30;
    *out = (float)v;
    return true;
}

head_cmd_status_t head_cmd_parse(const char *command, const cJSON *params,
                                 head_cmd_t *out) {
    if (!command || !out) return HEAD_CMD_NOT_HEAD;
    head_cmd_t cmd = {0};
    if (strcmp(command, "head.move") == 0) cmd.op = HEAD_MOVE;
    else if (strcmp(command, "head.gesture") == 0) cmd.op = HEAD_GESTURE;
    else if (strcmp(command, "head.get") == 0) cmd.op = HEAD_GET;
    else return HEAD_CMD_NOT_HEAD;

    if (cmd.op == HEAD_MOVE) {
        if (!number_param(params, "yaw", &cmd.yaw) || !number_param(params, "pitch", &cmd.pitch)) {
            return HEAD_CMD_MISSING_PARAM;
        }
        float d = DURATION_DEF_MS;
        number_param(params, "duration_ms", &d);
        if (d < DURATION_MIN_MS) d = DURATION_MIN_MS;
        if (d > DURATION_MAX_MS) d = DURATION_MAX_MS;
        cmd.duration_ms = (int)d;
    } else if (cmd.op == HEAD_GESTURE) {
        const cJSON *name = cJSON_IsObject(params) ? cJSON_GetObjectItem(params, "name") : NULL;
        const char *n = cJSON_IsString(name) && name->valuestring ? name->valuestring : "";
        if (strcmp(n, "nod") == 0) cmd.gesture = GESTURE_NOD;
        else if (strcmp(n, "shake") == 0) cmd.gesture = GESTURE_SHAKE;
        else if (strcmp(n, "look_around") == 0) cmd.gesture = GESTURE_LOOK_AROUND;
        else if (strcmp(n, "home") == 0) cmd.gesture = GESTURE_HOME;
        else return HEAD_CMD_INVALID_PARAM;
    }
    *out = cmd;
    return HEAD_CMD_OK;
}

bool head_cmd_request_id_ok(const char *request_id) {
    if (!request_id) return true;
    // Look no further than one byte past the limit.
    return memchr(request_id, '\0', HEAD_REQUEST_ID_MAX + 1) != NULL;
}

cJSON *head_cmd_error(const char *code, const char *message) {
    cJSON *r = cJSON_CreateObject();
    if (!r) return NULL;
    cJSON_AddBoolToObject(r, "ok", false);
    cJSON *e = cJSON_AddObjectToObject(r, "error");
    if (e) {
        cJSON_AddStringToObject(e, "code", code);
        cJSON_AddStringToObject(e, "message", message);
    }
    return r;
}

cJSON *head_cmd_status_error(head_cmd_status_t status) {
    switch (status) {
    case HEAD_CMD_MISSING_PARAM:
        return head_cmd_error("missing_param", "yaw and pitch are required numbers");
    case HEAD_CMD_INVALID_PARAM:
        return head_cmd_error("invalid_param", "name must be nod, shake, look_around or home");
    default:
        return head_cmd_error("internal", "unexpected status");
    }
}
