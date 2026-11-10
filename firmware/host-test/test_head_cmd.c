// Properties of head.* argument checks (issue #17, part 3).
#include <math.h>

#include "prop.h"
#include "stackchan_head_cmd.h"

static head_cmd_status_t parse_json(const char *command, const char *json, head_cmd_t *cmd) {
    cJSON *params = json ? cJSON_Parse(json) : NULL;
    head_cmd_status_t st = head_cmd_parse(command, params, cmd);
    cJSON_Delete(params);
    return st;
}

static int error_code_is(cJSON *r, const char *code) {
    const cJSON *e = cJSON_GetObjectItem(r, "error");
    const cJSON *c = cJSON_GetObjectItem(e, "code");
    return cJSON_IsFalse(cJSON_GetObjectItem(r, "ok")) && cJSON_IsString(c) &&
           strcmp(c->valuestring, code) == 0 && cJSON_IsString(cJSON_GetObjectItem(e, "message"));
}

static void test_examples(void) {
    head_cmd_t cmd;
    CHECK(parse_json("head.move", "{\"yaw\":10,\"pitch\":20}", &cmd) == HEAD_CMD_OK, "move");
    CHECK(cmd.op == HEAD_MOVE && cmd.yaw == 10 && cmd.pitch == 20 && cmd.duration_ms == DURATION_DEF_MS, "move values");
    CHECK(parse_json("head.move", "{\"yaw\":1,\"pitch\":2,\"duration_ms\":5}", &cmd) == HEAD_CMD_OK &&
          cmd.duration_ms == DURATION_MIN_MS, "short duration");
    CHECK(parse_json("head.move", "{\"yaw\":1,\"pitch\":2,\"duration_ms\":1e300}", &cmd) == HEAD_CMD_OK &&
          cmd.duration_ms == DURATION_MAX_MS, "long duration");
    CHECK(parse_json("head.move", "{\"yaw\":1e300,\"pitch\":2}", &cmd) == HEAD_CMD_OK && isfinite(cmd.yaw),
          "huge yaw stays finite");
    CHECK(parse_json("head.move", "{\"yaw\":\"10\",\"pitch\":20}", &cmd) == HEAD_CMD_MISSING_PARAM, "string yaw");
    CHECK(parse_json("head.move", "{\"pitch\":20}", &cmd) == HEAD_CMD_MISSING_PARAM, "no yaw");
    CHECK(parse_json("head.move", "[1,2]", &cmd) == HEAD_CMD_MISSING_PARAM, "array params");
    CHECK(parse_json("head.move", NULL, &cmd) == HEAD_CMD_MISSING_PARAM, "no params");
    CHECK(parse_json("head.gesture", "{\"name\":\"nod\"}", &cmd) == HEAD_CMD_OK && cmd.gesture == GESTURE_NOD, "nod");
    CHECK(parse_json("head.gesture", "{\"name\":\"home\"}", &cmd) == HEAD_CMD_OK && cmd.gesture == GESTURE_HOME, "home");
    CHECK(parse_json("head.gesture", "{\"name\":\"dance\"}", &cmd) == HEAD_CMD_INVALID_PARAM, "dance");
    CHECK(parse_json("head.gesture", "{\"name\":null}", &cmd) == HEAD_CMD_INVALID_PARAM, "null name");
    CHECK(parse_json("head.get", NULL, &cmd) == HEAD_CMD_OK && cmd.op == HEAD_GET, "get");
    CHECK(parse_json("tail.wag", "{}", &cmd) == HEAD_CMD_NOT_HEAD, "other command");
    CHECK(head_cmd_parse(NULL, NULL, &cmd) == HEAD_CMD_NOT_HEAD, "NULL command");

    cJSON *r = head_cmd_status_error(HEAD_CMD_MISSING_PARAM);
    CHECK(error_code_is(r, "missing_param"), "missing_param json");
    cJSON_Delete(r);
    r = head_cmd_status_error(HEAD_CMD_INVALID_PARAM);
    CHECK(error_code_is(r, "invalid_param"), "invalid_param json");
    cJSON_Delete(r);
}

static cJSON *random_value(int depth);

static char *random_string(void) {
    static const char *const known[] = {"nod", "shake", "look_around", "home", "yaw", "pitch",
                                        "duration_ms", "name", "Nod", "nod ", ""};
    static char buf[16];
    if (prop_below(2)) return (char *)known[prop_below(sizeof(known) / sizeof(*known))];
    size_t n = prop_below(sizeof(buf));
    for (size_t i = 0; i < n; i++) buf[i] = (char)(1 + prop_below(255));
    buf[n] = 0;
    return buf;
}

static double random_number(void) {
    switch (prop_below(6)) {
    case 0: return NAN;
    case 1: return prop_below(2) ? INFINITY : -INFINITY;
    case 2: return (double)prop_any_float();
    case 3: return ((double)prop_u64() / 1e5) * (prop_below(2) ? 1 : -1);
    default: return (double)prop_float_in(-5000, 5000);
    }
}

static cJSON *random_value(int depth) {
    switch (prop_below(depth > 2 ? 5 : 7)) {
    case 0: return cJSON_CreateNull();
    case 1: return cJSON_CreateBool(prop_below(2));
    case 2: case 3: return cJSON_CreateNumber(random_number());
    case 4: return cJSON_CreateString(random_string());
    case 5: {
        cJSON *a = cJSON_CreateArray();
        for (uint32_t i = prop_below(4); i > 0; i--) cJSON_AddItemToArray(a, random_value(depth + 1));
        return a;
    }
    default: {
        cJSON *o = cJSON_CreateObject();
        for (uint32_t i = prop_below(5); i > 0; i--) {
            cJSON_AddItemToObject(o, random_string(), random_value(depth + 1));
        }
        return o;
    }
    }
}

// Any params: the result is OK or one error; OK moves have finite angles and
// a duration in range; every error becomes a well-formed error JSON.
static void prop_any_params(void) {
    static const char *const commands[] = {"head.move", "head.gesture", "head.get", "head", ""};
    for (long r = 0; r < prop_runs; r++) {
        const char *command = commands[prop_below(5)];
        cJSON *params = prop_below(8) == 0 ? NULL : random_value(prop_below(2) ? 0 : 3);
        head_cmd_t cmd;
        head_cmd_status_t st = head_cmd_parse(command, params, &cmd);
        char *text = params ? cJSON_PrintUnformatted(params) : NULL;
        const char *shown = text ? text : "(null)";

        if (strncmp(command, "head.", 5) != 0) {
            CHECK(st == HEAD_CMD_NOT_HEAD, "%s %s", command, shown);
        } else if (st == HEAD_CMD_OK) {
            CHECK(cmd.op != HEAD_MOVE || (isfinite(cmd.yaw) && isfinite(cmd.pitch)), "%s", shown);
            CHECK(cmd.op != HEAD_MOVE ||
                      (cmd.duration_ms >= DURATION_MIN_MS && cmd.duration_ms <= DURATION_MAX_MS),
                  "%s -> %d ms", shown, cmd.duration_ms);
        } else if (strcmp(command, "head.move") == 0) {
            CHECK(st == HEAD_CMD_MISSING_PARAM, "%s -> %d", shown, st);
        } else if (strcmp(command, "head.gesture") == 0) {
            CHECK(st == HEAD_CMD_INVALID_PARAM, "%s -> %d", shown, st);
        } else {
            CHECK(0, "head.get failed: %s", shown);
        }
        if (st == HEAD_CMD_MISSING_PARAM || st == HEAD_CMD_INVALID_PARAM) {
            cJSON *e = head_cmd_status_error(st);
            CHECK(error_code_is(e, st == HEAD_CMD_MISSING_PARAM ? "missing_param" : "invalid_param"), "%s", shown);
            cJSON_Delete(e);
        }

        // head.move accepts yaw/pitch exactly when both are finite numbers.
        if (strcmp(command, "head.move") == 0) {
            const cJSON *y = cJSON_IsObject(params) ? cJSON_GetObjectItem(params, "yaw") : NULL;
            const cJSON *p = cJSON_IsObject(params) ? cJSON_GetObjectItem(params, "pitch") : NULL;
            int good = cJSON_IsNumber(y) && isfinite(y->valuedouble) && cJSON_IsNumber(p) && isfinite(p->valuedouble);
            CHECK((st == HEAD_CMD_OK) == good, "%s", shown);
        }
        cJSON_free(text);
        cJSON_Delete(params);
    }
}

// head.gesture: only the four names, exactly.
static void prop_gesture_names(void) {
    static const char *const ok[] = {"nod", "shake", "look_around", "home"};
    for (long r = 0; r < prop_runs; r++) {
        const char *name = random_string();
        cJSON *params = cJSON_CreateObject();
        cJSON_AddStringToObject(params, "name", name);
        head_cmd_t cmd;
        head_cmd_status_t st = head_cmd_parse("head.gesture", params, &cmd);
        int known = 0;
        for (int i = 0; i < 4; i++) known |= strcmp(name, ok[i]) == 0;
        CHECK((st == HEAD_CMD_OK) == known && (known || st == HEAD_CMD_INVALID_PARAM), "name=%s st=%d", name, st);
        cJSON_Delete(params);
    }
}

int main(void) {
    prop_init();
    test_examples();
    prop_any_params();
    prop_gesture_names();
    return prop_done("test_head_cmd");
}
