// Properties of the UTF-8 boundary cuts (issue #12).
#include <stdbool.h>

#include "prop.h"
#include "stackchan_utf8.h"

// Strict UTF-8 check, written separately from the code under test: no overlong
// forms, no surrogates, nothing above U+10FFFF.
static bool valid_utf8(const unsigned char *s, size_t n) {
    size_t i = 0;
    while (i < n) {
        unsigned char c = s[i];
        size_t len;
        uint32_t cp, min;
        if (c < 0x80) { i++; continue; }
        if ((c & 0xE0) == 0xC0) { len = 2; cp = c & 0x1F; min = 0x80; }
        else if ((c & 0xF0) == 0xE0) { len = 3; cp = c & 0x0F; min = 0x800; }
        else if ((c & 0xF8) == 0xF0) { len = 4; cp = c & 0x07; min = 0x10000; }
        else return false;
        if (i + len > n) return false;
        for (size_t k = 1; k < len; k++) {
            if ((s[i + k] & 0xC0) != 0x80) return false;
            cp = (cp << 6) | (s[i + k] & 0x3F);
        }
        if (cp < min || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)) return false;
        i += len;
    }
    return true;
}

static bool valid_str(const char *s) { return valid_utf8((const unsigned char *)s, strlen(s)); }

static size_t put_cp(char *out, uint32_t cp) {
    unsigned char *o = (unsigned char *)out;
    if (cp < 0x80) { o[0] = (unsigned char)cp; return 1; }
    if (cp < 0x800) { o[0] = (unsigned char)(0xC0 | (cp >> 6)); o[1] = (unsigned char)(0x80 | (cp & 0x3F)); return 2; }
    if (cp < 0x10000) {
        o[0] = (unsigned char)(0xE0 | (cp >> 12));
        o[1] = (unsigned char)(0x80 | ((cp >> 6) & 0x3F));
        o[2] = (unsigned char)(0x80 | (cp & 0x3F));
        return 3;
    }
    o[0] = (unsigned char)(0xF0 | (cp >> 18));
    o[1] = (unsigned char)(0x80 | ((cp >> 12) & 0x3F));
    o[2] = (unsigned char)(0x80 | ((cp >> 6) & 0x3F));
    o[3] = (unsigned char)(0x80 | (cp & 0x3F));
    return 4;
}

// A random valid string of up to max bytes (plus NUL), mixing ASCII, Latin,
// kana/kanji/Hangul and emoji so cuts fall at every offset within a character.
static size_t gen_utf8(char *out, size_t max) {
    size_t n = 0, want = prop_below((uint32_t)max + 1);
    while (n + 4 <= want) {
        uint32_t cp;
        switch (prop_below(5)) {
        case 0: cp = 0x20 + prop_below(0x5F); break;
        case 1: cp = 0x80 + prop_below(0x800 - 0x80); break;
        case 2: cp = 0x3040 + prop_below(0x9FFF - 0x3040); break;
        case 3: cp = 0xE000 + prop_below(0x10000 - 0xE000); break;
        default: cp = 0x10000 + prop_below(0x110000 - 0x10000); break;
        }
        n += put_cp(out + n, cp);
    }
    out[n] = '\0';
    return n;
}

static void test_examples(void) {
    char a[] = "\xe3\x81";  // the relay's 400 in the issue
    CHECK(utf8_trim_tail(a) == 0 && a[0] == '\0', "cut kana");
    char b[] = "ok\xe3\x81\x82";  // complete あ
    CHECK(utf8_trim_tail(b) == 5, "whole kana kept");
    char c[] = "x\xf0\x9f\x98";  // 3 of an emoji's 4 bytes
    CHECK(utf8_trim_tail(c) == 1 && strcmp(c, "x") == 0, "cut emoji");
    char d[] = "\x81\x82y";
    CHECK(utf8_trim_head(d) == 1 && strcmp(d, "y") == 0, "cut head");
    char e[] = "";
    CHECK(utf8_trim_tail(e) == 0 && utf8_trim_head(e) == 0, "empty");
    char f[] = "\x80\x80\x80\x80\x80";  // stray bytes, not a cut character
    CHECK(utf8_trim_tail(f) == 5, "stray continuation bytes left");
    CHECK(utf8_trim_head(f) == 2, "head drops at most 3");

    char buf[8] = "ab";
    CHECK(!utf8_strlcat(buf, "\xe3\x81\x82\xe3\x81\x84", sizeof(buf)), "doesn't fit");
    CHECK(strcmp(buf, "ab\xe3\x81\x82") == 0, "cut after あ: %s", buf);
    CHECK(!utf8_strlcat(buf, "z", sizeof(buf)) || strlen(buf) == 6, "room for one more");
    char full[4] = "abc";
    CHECK(!utf8_strlcat(full, "d", sizeof(full)) && strcmp(full, "abc") == 0, "already full");
    char s[8] = "a";
    CHECK(utf8_strlcat(s, "\xe3\x81", sizeof(s)) && strcmp(s, "a\xe3\x81") == 0, "partial src kept when it fits");
}

// Valid text is never changed.
static void prop_valid_unchanged(void) {
    char s[256], t[256];
    for (long r = 0; r < prop_runs; r++) {
        size_t n = gen_utf8(s, sizeof(s) - 1);
        memcpy(t, s, n + 1);
        CHECK(utf8_trim_tail(t) == n && memcmp(s, t, n + 1) == 0, "tail changed %zu bytes", n);
        CHECK(utf8_trim_head(t) == n && memcmp(s, t, n + 1) == 0, "head changed %zu bytes", n);
    }
}

// Valid text cut at any byte: the tail trim gives valid text, a prefix of the
// original, at most 3 bytes shorter. The same for the head and suffixes.
static void prop_cut_anywhere(void) {
    char s[256], t[256];
    for (long r = 0; r < prop_runs; r++) {
        size_t n = gen_utf8(s, sizeof(s) - 1);
        size_t cut = prop_below((uint32_t)n + 1);
        memcpy(t, s, cut);
        t[cut] = '\0';
        size_t m = utf8_trim_tail(t);
        CHECK(m == strlen(t) && m <= cut && cut - m <= 3, "tail dropped %zu", cut - m);
        CHECK(valid_str(t) && memcmp(t, s, m) == 0, "tail not a valid prefix (cut %zu of %zu)", cut, n);

        strcpy(t, s + cut);
        m = utf8_trim_head(t);
        CHECK(m == strlen(t) && m <= n - cut && n - cut - m <= 3, "head dropped %zu", n - cut - m);
        CHECK(valid_str(t) && strcmp(t, s + n - m) == 0, "head not a valid suffix (cut %zu of %zu)", cut, n);
    }
}

// utf8_strlcat with valid pieces and any capacity: valid result, a prefix of
// dst + src, shorter than cap, at most 3 bytes short of what strlcat keeps,
// and true exactly when everything fit.
static void prop_strlcat(void) {
    char a[200], b[200], whole[400], buf[420];  // buf > the largest cap (406)
    for (long r = 0; r < prop_runs; r++) {
        size_t na = gen_utf8(a, sizeof(a) - 1), nb = gen_utf8(b, sizeof(b) - 1);
        size_t cap = na + 1 + prop_below((uint32_t)nb + 8);
        memcpy(whole, a, na);
        memcpy(whole + na, b, nb + 1);
        memset(buf, 0x55, sizeof(buf));
        memcpy(buf, a, na + 1);
        bool all = utf8_strlcat(buf, b, cap);
        size_t m = strlen(buf), keep = na + nb < cap - 1 ? na + nb : cap - 1;
        CHECK(m < cap && m <= keep && keep - m <= 3, "kept %zu of %zu (cap %zu)", m, keep, cap);
        CHECK(valid_str(buf) && memcmp(buf, whole, m) == 0, "not a valid prefix (cap %zu)", cap);
        CHECK(all == (m == na + nb), "returned %d with %zu of %zu", all, m, na + nb);
        CHECK(cap < sizeof(buf) && (unsigned char)buf[cap] == 0x55, "wrote past cap");
    }
}

// The firmware's use: a reply streamed in chunks split at any byte, appended
// until the first one that doesn't fit. What's left is valid and a prefix.
static void prop_streamed(void) {
    char s[600], buf[128];
    for (long r = 0; r < prop_runs; r++) {
        size_t n = gen_utf8(s, sizeof(s) - 1);
        size_t cap = 1 + prop_below(sizeof(buf));
        buf[0] = '\0';
        bool all = true;
        for (size_t i = 0; i < n && all;) {
            size_t len = 1 + prop_below(16);
            if (len > n - i) len = n - i;
            char chunk[17];
            memcpy(chunk, s + i, len);
            chunk[len] = '\0';
            all = utf8_strlcat(buf, chunk, cap);
            i += len;
        }
        size_t m = strlen(buf);
        CHECK(m < cap && memcmp(buf, s, m) == 0, "not a prefix");
        CHECK(valid_str(buf), "invalid after streaming (cap %zu, kept %zu of %zu)", cap, m, n);
        CHECK(all ? m == n : n - m >= 1 && (cap - 1) - m <= 3, "kept %zu of %zu, cap %zu", m, n, cap);
    }
}

// Any bytes at all: within bounds, at most 3 bytes dropped, prefix/suffix kept.
static void prop_any_bytes(void) {
    char s[64], t[64], buf[64];
    for (long r = 0; r < prop_runs; r++) {
        size_t n = prop_below(sizeof(s));
        for (size_t i = 0; i < n; i++) s[i] = (char)(1 + prop_below(255));
        s[n] = '\0';
        strcpy(t, s);
        size_t m = utf8_trim_tail(t);
        CHECK(m <= n && n - m <= 3 && memcmp(t, s, m) == 0 && t[m] == '\0', "tail on bytes");
        strcpy(t, s);
        m = utf8_trim_head(t);
        CHECK(m <= n && n - m <= 3 && strcmp(t, s + n - m) == 0, "head on bytes");
        size_t cap = 1 + prop_below(sizeof(buf));
        size_t pre = prop_below((uint32_t)cap);
        memcpy(buf, s, pre);
        buf[pre] = '\0';
        utf8_strlcat(buf, s, cap);
        CHECK(strlen(buf) < cap, "strlcat past cap");
    }
}

int main(void) {
    prop_init();
    test_examples();
    prop_valid_unchanged();
    prop_cut_anywhere();
    prop_strlcat();
    prop_streamed();
    prop_any_bytes();
    return prop_done("test_utf8");
}
