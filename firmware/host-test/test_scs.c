// Properties of the SCS packet code (issue #17, part 1).
#include "prop.h"
#include "stackchan_scs.h"

static void random_bytes(uint8_t *b, size_t n) {
    for (size_t i = 0; i < n; i++) b[i] = prop_byte();
}

// A fixed packet from the Feetech docs' shape, worked out by hand: write 1 to
// register 40 (torque) of servo 1.
static void test_known_request(void) {
    uint8_t v = 1, pkt[SCS_PKT_MAX];
    size_t n = scs_build(1, SCS_INST_WRITE, 40, &v, 1, pkt, sizeof(pkt));
    const uint8_t want[] = {0xFF, 0xFF, 0x01, 0x04, 0x03, 0x28, 0x01, 0xCE};
    CHECK(n == sizeof(want), "n=%zu", n);
    CHECK(memcmp(pkt, want, sizeof(want)) == 0, "bytes differ");
}

static void test_build_limits(void) {
    uint8_t data[SCS_DATA_MAX + 1] = {0}, pkt[SCS_PKT_MAX + 1];
    CHECK(scs_build(1, 3, 0, data, SCS_DATA_MAX, pkt, SCS_PKT_MAX) == SCS_PKT_MAX, "max fits");
    CHECK(scs_build(1, 3, 0, data, SCS_DATA_MAX + 1, pkt, sizeof(pkt)) == 0, "too much data");
    CHECK(scs_build(1, 3, 0, data, 2, pkt, 8) == 0, "out too small");
    CHECK(scs_build(1, 3, 0, NULL, 2, pkt, sizeof(pkt)) == 0, "NULL data");
    CHECK(scs_build(1, 3, 0, NULL, 0, pkt, sizeof(pkt)) == 7, "no data");
    CHECK(scs_build_status(1, 0, data, SCS_REPLY_MAX + 1, pkt, sizeof(pkt)) == 0, "status too long");
}

// Round trip: any id / err / 0..SCS_REPLY_MAX data bytes.
static void prop_round_trip(void) {
    for (long r = 0; r < prop_runs; r++) {
        uint8_t id = prop_byte(), err = prop_byte(), n = (uint8_t)prop_below(SCS_REPLY_MAX + 1);
        if (id == 0xFF) id = 0xFE;  // broadcast, never a reply
        uint8_t data[SCS_REPLY_MAX], pkt[6 + SCS_REPLY_MAX];
        random_bytes(data, n);
        size_t len = scs_build_status(id, err, data, n, pkt, sizeof(pkt));
        CHECK(len == 6u + n, "len=%zu n=%u", len, n);

        scs_reply_t reply;
        size_t used = 0;
        CHECK(scs_parse(pkt, len, &reply, &used) == SCS_PARSE_OK, "id=%u n=%u", id, n);
        CHECK(reply.id == id && reply.err == err && reply.n == n, "id=%u n=%u", id, n);
        CHECK(memcmp(reply.data, data, n) == 0, "data differs");
        CHECK(used == len, "used=%zu len=%zu", used, len);

        // Every proper prefix is incomplete, never accepted or rejected.
        for (size_t k = 0; k < len; k++) {
            CHECK(scs_parse(pkt, k, &reply, NULL) == SCS_PARSE_NEED_MORE, "prefix %zu of %zu", k, len);
        }
    }
}

// Flip any one bit after the FF FF header. The caller expects the id and data
// length it asked for, so the packet must either fail to parse or not match.
static void prop_bit_flip_rejected(void) {
    for (long r = 0; r < prop_runs / 10 + 1; r++) {
        uint8_t id = (uint8_t)prop_below(0xFE), n = (uint8_t)prop_below(SCS_REPLY_MAX + 1);
        uint8_t data[SCS_REPLY_MAX], pkt[6 + SCS_REPLY_MAX];
        random_bytes(data, n);
        size_t len = scs_build_status(id, prop_byte(), data, n, pkt, sizeof(pkt));
        for (size_t bit = 16; bit < len * 8; bit++) {
            uint8_t bad[sizeof(pkt)];
            memcpy(bad, pkt, len);
            bad[bit / 8] ^= (uint8_t)(1u << (bit % 8));
            scs_reply_t reply;
            scs_parse_result_t st = scs_parse(bad, len, &reply, NULL);
            int accepted = st == SCS_PARSE_OK && reply.id == id && reply.n == n;
            CHECK(!accepted, "id=%u n=%u bit=%zu", id, n, bit);
        }
    }
}

// Noise before the packet is skipped, as long as it has no FF FF pair (a
// header that is then wrong is reported as such, not searched past).
static void prop_sync_after_noise(void) {
    for (long r = 0; r < prop_runs; r++) {
        uint8_t buf[64 + 6 + SCS_REPLY_MAX];
        size_t noise = prop_below(64);
        for (size_t i = 0; i < noise; i++) {
            buf[i] = prop_byte();
            if (i && buf[i - 1] == 0xFF && buf[i] == 0xFF) buf[i] = 0x00;
        }
        uint8_t id = (uint8_t)prop_below(0xFE), n = (uint8_t)prop_below(SCS_REPLY_MAX + 1);
        uint8_t data[SCS_REPLY_MAX];
        random_bytes(data, n);
        size_t len = scs_build_status(id, 0, data, n, buf + noise, sizeof(buf) - noise);
        scs_reply_t reply;
        size_t used = 0;
        CHECK(scs_parse(buf, noise + len, &reply, &used) == SCS_PARSE_OK, "noise=%zu", noise);
        CHECK(reply.id == id && reply.n == n && memcmp(reply.data, data, n) == 0, "noise=%zu", noise);
        CHECK(used == noise + len, "used=%zu", used);
    }
}

// Any bytes at all: the result is one of the three values, and on OK the
// reply is within bounds. AddressSanitizer catches out-of-range reads.
static void prop_any_bytes(void) {
    for (long r = 0; r < prop_runs; r++) {
        size_t len = prop_below(40);
        uint8_t *buf = malloc(len ? len : 1);  // exact size so ASan sees overreads
        for (size_t i = 0; i < len; i++) buf[i] = prop_below(4) == 0 ? 0xFF : prop_byte();
        scs_reply_t reply;
        size_t used = 0;
        scs_parse_result_t st = scs_parse(buf, len, &reply, &used);
        CHECK(st == SCS_PARSE_OK || st == SCS_PARSE_NEED_MORE || st == SCS_PARSE_BAD, "st=%d", st);
        if (st == SCS_PARSE_OK) {
            CHECK(reply.n <= SCS_REPLY_MAX && used <= len, "n=%u used=%zu len=%zu", reply.n, used, len);
        }
        free(buf);
    }
}

static void test_examples(void) {
    scs_reply_t reply;
    // A header followed by a too-long length is rejected, not read past.
    const uint8_t too_long[] = {0xFF, 0xFF, 0x01, 0xFF, 0x00};
    CHECK(scs_parse(too_long, sizeof(too_long), &reply, NULL) == SCS_PARSE_BAD, "too long");
    const uint8_t too_short[] = {0xFF, 0xFF, 0x01, 0x01, 0x00, 0x00};
    CHECK(scs_parse(too_short, sizeof(too_short), &reply, NULL) == SCS_PARSE_BAD, "len < 2");
    // Extra FFs before the id (e.g. a stray FF in front of the header).
    uint8_t pkt[16] = {0xFF};
    size_t len = scs_build_status(2, 0, NULL, 0, pkt + 1, sizeof(pkt) - 1);
    CHECK(scs_parse(pkt, len + 1, &reply, NULL) == SCS_PARSE_OK && reply.id == 2, "FF FF FF id");
    CHECK(scs_parse(NULL, 0, &reply, NULL) == SCS_PARSE_BAD, "NULL buf");
}

int main(void) {
    prop_init();
    test_known_request();
    test_build_limits();
    test_examples();
    prop_round_trip();
    prop_bit_flip_rejected();
    prop_sync_after_noise();
    prop_any_bytes();
    return prop_done("test_scs");
}
