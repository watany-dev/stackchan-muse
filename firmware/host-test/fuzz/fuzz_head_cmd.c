// libFuzzer target: head.* argument checks on arbitrary JSON. The first byte
// picks the command, the rest is parsed as params.
#include <math.h>
#include <stdint.h>
#include <stdlib.h>

#include "stackchan_head_cmd.h"

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    static const char *const commands[] = {"head.move", "head.gesture", "head.get", "other"};
    if (size == 0) return 0;
    const char *command = commands[data[0] % 4];
    cJSON *params = cJSON_ParseWithLength((const char *)data + 1, size - 1);
    head_cmd_t cmd;
    head_cmd_status_t st = head_cmd_parse(command, params, &cmd);
    if (st == HEAD_CMD_OK && cmd.op == HEAD_MOVE) {
        if (!isfinite(cmd.yaw) || !isfinite(cmd.pitch)) abort();
        if (cmd.duration_ms < DURATION_MIN_MS || cmd.duration_ms > DURATION_MAX_MS) abort();
    }
    if (st == HEAD_CMD_MISSING_PARAM || st == HEAD_CMD_INVALID_PARAM) {
        cJSON *e = head_cmd_status_error(st);
        if (!e) abort();
        cJSON_Delete(e);
    }
    cJSON_Delete(params);
    return 0;
}
