// libFuzzer target: scs_parse on arbitrary bytes. Run under AddressSanitizer
// so any read outside the input is caught.
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "stackchan_scs.h"

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    scs_reply_t reply;
    size_t used = 0;
    scs_parse_result_t st = scs_parse(data, size, &reply, &used);
    if (st == SCS_PARSE_OK) {
        if (reply.n > SCS_REPLY_MAX || used > size || used < 6u + reply.n) abort();
        // What parsed must rebuild into the bytes it came from.
        uint8_t pkt[6 + SCS_REPLY_MAX];
        size_t len = scs_build_status(reply.id, reply.err, reply.data, reply.n, pkt, sizeof(pkt));
        if (len == 0 || memcmp(pkt + 2, data + used - len + 2, len - 2) != 0) abort();
    } else if (st != SCS_PARSE_NEED_MORE && st != SCS_PARSE_BAD) {
        abort();
    }
    return 0;
}
