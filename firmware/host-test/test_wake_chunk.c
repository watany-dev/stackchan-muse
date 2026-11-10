// Properties of the wake word chunking (muse_wake.c's feed loop; issue #17).
// WakeNet is replaced by a fake that records every chunk it is given and
// reports a detection on the calls a test picks.
#include <stdbool.h>

#include "prop.h"
#include "stackchan_wake_chunk.h"

#define MAX_AUDIO 12000
#define MAX_CHUNK 700

typedef struct {
    size_t chunk;
    int16_t log[MAX_AUDIO];   // every chunk detect() saw, back to back
    size_t logged;            // samples in log
    size_t calls;             // detect() calls so far
    const bool *hits;         // hits[i]: call i reports a detection (NULL: never)
    bool always;              // every call reports a detection
} fake_wn_t;

static bool fake_detect(void *ctx, int16_t *chunk) {
    fake_wn_t *f = ctx;
    if (f->logged + f->chunk <= MAX_AUDIO) {
        memcpy(f->log + f->logged, chunk, f->chunk * sizeof(int16_t));
    }
    f->logged += f->chunk;
    size_t i = f->calls++;
    return f->always || (f->hits && f->hits[i]);
}

static size_t settle_chunks(size_t chunk) { return WAKE_CHUNK_SETTLE_SAMPLES / chunk; }

static void random_audio(int16_t *a, size_t n) {
    for (size_t i = 0; i < n; i++) a[i] = (int16_t)prop_u64();
}

static size_t random_chunk(void) {
    // The sizes ESP-SR models use, and anything else.
    static const size_t real[] = {480, 512, 160, 320};
    return prop_below(4) == 0 ? real[prop_below(4)] : 1 + prop_below(MAX_CHUNK);
}

// The issue's cases with the model's real chunk sizes.
static void test_examples(void) {
    static int16_t buf[MAX_CHUNK];
    static int16_t audio[MAX_AUDIO];
    static fake_wn_t f;
    wake_chunk_t c;

    // No model: never true, and nothing reaches the detector.
    memset(&f, 0, sizeof(f));
    f.always = true;
    wake_chunk_init(&c, buf, 0, fake_detect, &f);
    CHECK(!wake_chunk_feed(&c, audio, 320), "chunk 0 fed");
    wake_chunk_reset(&c);
    CHECK(!wake_chunk_feed(&c, audio, 320), "chunk 0 fed after reset");
    wake_chunk_init(&c, NULL, 512, fake_detect, &f);
    CHECK(!wake_chunk_feed(&c, audio, 1024), "NULL buffer fed");
    wake_chunk_init(&c, buf, 512, NULL, &f);
    CHECK(!wake_chunk_feed(&c, audio, 1024), "NULL detector fed");
    CHECK(f.calls == 0, "detect called %zu times without a model", f.calls);

    // 1.5 s after a reset with 480- and 512-sample chunks (the mic reads 320).
    static const size_t sizes[] = {480, 512};
    for (int s = 0; s < 2; s++) {
        size_t chunk = sizes[s];
        memset(&f, 0, sizeof(f));
        f.chunk = chunk;
        f.always = true;
        wake_chunk_init(&c, buf, chunk, fake_detect, &f);
        random_audio(audio, chunk);
        CHECK(wake_chunk_feed(&c, audio, chunk), "chunk %zu: first detection before any reset ignored", chunk);
        wake_chunk_reset(&c);
        size_t n = settle_chunks(chunk);
        CHECK(n == (chunk == 480 ? 50 : 46), "chunk %zu: settle %zu chunks", chunk, n);
        for (size_t i = 0; i < n; i++) {
            CHECK(!wake_chunk_feed(&c, audio, chunk), "chunk %zu: detection %zu of the settle period counted", chunk, i);
        }
        CHECK(wake_chunk_feed(&c, audio, chunk), "chunk %zu: detection after the settle period ignored", chunk);
        CHECK(n * chunk <= WAKE_CHUNK_SETTLE_SAMPLES && (n + 1) * chunk > WAKE_CHUNK_SETTLE_SAMPLES,
              "chunk %zu: settle %zu chunks isn't about 1.5 s", chunk, n);
    }

    // A reset drops the partial chunk: the next chunk is new audio only.
    memset(&f, 0, sizeof(f));
    f.chunk = 512;
    wake_chunk_init(&c, buf, 512, fake_detect, &f);
    random_audio(audio, 512 + 300);
    wake_chunk_feed(&c, audio, 300);
    wake_chunk_reset(&c);
    wake_chunk_feed(&c, audio + 300, 512);
    CHECK(f.calls == 1 && memcmp(f.log, audio + 300, 512 * sizeof(int16_t)) == 0,
          "after a reset the chunk mixed old audio in (%zu calls)", f.calls);
}

// Model-based: random audio fed in random pieces (zero-length ones too) with
// random resets in between, against a model written from the spec:
//  - detect() sees, for each stretch between resets, its first
//    floor(len / chunk) * chunk samples, in order, cut into chunks;
//  - a feed is true iff a chunk it completed was detected and is chunk
//    settle or later since the last reset (any, if there was no reset yet).
static void prop_model(void) {
    static int16_t buf[MAX_CHUNK];
    static int16_t audio[MAX_AUDIO];
    static int16_t expect[MAX_AUDIO];
    static bool hits[MAX_AUDIO];
    static fake_wn_t f;
    for (long r = 0; r < prop_runs; r++) {
        size_t chunk = random_chunk();
        size_t total = prop_below(MAX_AUDIO + 1);
        random_audio(audio, total);
        // Sparse or dense detections.
        uint32_t odds = 1 + prop_below(8);
        for (size_t i = 0; i < MAX_AUDIO; i++) hits[i] = prop_below(odds) == 0;

        memset(&f, 0, sizeof(f));
        f.chunk = chunk;
        f.hits = hits;
        wake_chunk_t c;
        wake_chunk_init(&c, buf, chunk, fake_detect, &f);

        size_t pos = 0;          // samples fed
        size_t since = 0;        // samples fed since the last reset
        size_t done = 0;         // chunks completed since the last reset
        size_t ignore = 0;       // settle chunks for this stretch
        size_t calls = 0;        // detect() calls the model expects
        size_t expected = 0;     // samples the model expects in the log
        uint32_t reset_odds = prop_below(3) == 0 ? 0 : 2 + prop_below(30);
        while (pos < total) {
            if (reset_odds && prop_below(reset_odds) == 0) {
                wake_chunk_reset(&c);
                since = 0;
                done = 0;
                ignore = settle_chunks(chunk);
            }
            size_t left = total - pos;
            size_t n = prop_below(4) == 0 ? 0 : 1 + prop_below((uint32_t)(left < 2000 ? left : 2000));
            if (n > left) n = left;
            bool want = false;
            size_t now = (since + n) / chunk;   // chunks complete after this feed
            for (size_t k = done; k < now; k++, calls++) {
                if (hits[calls] && k >= ignore) want = true;
            }
            // The completed chunks are samples [done*chunk, now*chunk) of this
            // stretch; the stretch started at pos - since.
            size_t start = pos - since;
            if (now > done) {
                memcpy(expect + expected, audio + start + done * chunk, (now - done) * chunk * sizeof(int16_t));
                expected += (now - done) * chunk;
            }
            bool got = wake_chunk_feed(&c, audio + pos, n);
            CHECK(got == want, "chunk %zu, feed %zu at %zu: got %d, want %d", chunk, n, pos, got, want);
            pos += n;
            since += n;
            done = now;
            if (prop_failures) return;
        }
        CHECK(f.calls == calls, "chunk %zu: %zu detect calls, want %zu", chunk, f.calls, calls);
        CHECK(f.logged == expected && memcmp(f.log, expect, expected * sizeof(int16_t)) == 0,
              "chunk %zu: detect saw different audio (%zu samples, want %zu)", chunk, f.logged, expected);
        if (prop_failures) return;
    }
}

// Split invariance: however the same audio is cut into feeds, detect() gets
// the same chunks, and the detections that count are the same ones.
static void prop_split_invariant(void) {
    static int16_t buf_a[MAX_CHUNK], buf_b[MAX_CHUNK];
    static int16_t audio[MAX_AUDIO];
    static bool hits[MAX_AUDIO];
    static fake_wn_t fa, fb;
    for (long r = 0; r < prop_runs / 10; r++) {
        size_t chunk = random_chunk();
        size_t total = prop_below(MAX_AUDIO + 1);
        random_audio(audio, total);
        for (size_t i = 0; i < MAX_AUDIO; i++) hits[i] = prop_below(5) == 0;
        memset(&fa, 0, sizeof(fa));
        memset(&fb, 0, sizeof(fb));
        fa.chunk = fb.chunk = chunk;
        fa.hits = fb.hits = hits;
        wake_chunk_t a, b;
        wake_chunk_init(&a, buf_a, chunk, fake_detect, &fa);
        wake_chunk_init(&b, buf_b, chunk, fake_detect, &fb);
        wake_chunk_reset(&a);
        wake_chunk_reset(&b);

        // a: one sample at a time, recording which chunk made it true.
        size_t first_a = SIZE_MAX;
        for (size_t i = 0; i < total; i++) {
            if (wake_chunk_feed(&a, audio + i, 1)) {
                if (first_a == SIZE_MAX) first_a = (i + 1) / chunk - 1;   // index of the chunk
            }
        }
        // b: random pieces. Its first true feed completes chunks
        // [pos / chunk, (pos + n) / chunk), which must hold a's first.
        size_t pos = 0;
        bool heard_b = false;
        while (pos < total) {
            size_t n = prop_below((uint32_t)(total - pos + 1));
            if (wake_chunk_feed(&b, audio + pos, n) && !heard_b) {
                heard_b = true;
                CHECK(first_a != SIZE_MAX && pos / chunk <= first_a && first_a < (pos + n) / chunk,
                      "chunk %zu: feed [%zu, %zu) true, chunk-by-chunk first detection at chunk %zu", chunk, pos,
                      pos + n, first_a);
            }
            pos += n;
        }
        CHECK((first_a == SIZE_MAX) == !heard_b, "chunk %zu: detected %d vs %d", chunk, first_a != SIZE_MAX,
              heard_b);
        CHECK(fa.calls == fb.calls && fa.logged == fb.logged &&
                  memcmp(fa.log, fb.log, (fa.logged < MAX_AUDIO ? fa.logged : MAX_AUDIO) * sizeof(int16_t)) == 0,
              "chunk %zu: chunks differ (%zu vs %zu calls)", chunk, fa.calls, fb.calls);
        CHECK(fa.calls == total / chunk, "chunk %zu: %zu calls for %zu samples", chunk, fa.calls, total);
        if (prop_failures) return;
    }
}

int main(void) {
    prop_init();
    test_examples();
    prop_model();
    prop_split_invariant();
    return prop_done("test_wake_chunk");
}
