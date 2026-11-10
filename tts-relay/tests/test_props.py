"""プロパティベーステスト(#14)。"""

from conftest import KEY, StubSynth, make_app, tts
from hypothesis import HealthCheck, assume, given, settings
from hypothesis import strategies as st

import server

http_settings = settings(
    max_examples=50, deadline=None, suppress_health_check=[HealthCheck.too_slow]
)

KANA = st.characters(min_codepoint=0x3041, max_codepoint=0x3096)
HANGUL = st.characters(min_codepoint=0xAC00, max_codepoint=0xD7A3)
KANJI = st.characters(min_codepoint=0x4E00, max_codepoint=0x9FFF)
# 仕様の述語がどれか1つの文字種を混ぜた文字列になるよう、各文字種を必ず出す
mixed_text = st.lists(st.one_of(st.text(), KANA, HANGUL, KANJI)).map("".join)


# --- 認証 ---


@given(st.text())
@settings(max_examples=500)
def test_key_matches_only_the_key(k: str) -> None:
    key = server.check_key(KEY)
    assert server.key_matches(k, key) == (k == KEY)


@given(st.text(alphabet=st.characters(blacklist_categories=["Cs", "Cc"])))
@http_settings
def test_any_other_header_is_401(k: str) -> None:
    assume(k != KEY)
    # ヘッダーに載せられない文字(改行など)は aiohttp が送る前に弾くので除いている
    assume(all(ord(c) < 0x100 for c in k))
    synth = StubSynth([{"type": "audio", "data": b"x"}])
    r = tts(make_app(synth), key=k)
    assert r.status == 401
    assert synth.calls == []


@given(st.text())
def test_check_key_accepts_exactly_long_keys(k: str) -> None:
    n = len(k.encode("utf-8", "surrogatepass"))
    try:
        server.check_key(k)
    except server.ConfigError:
        assert n < server.MIN_KEY_BYTES
    else:
        assert n >= server.MIN_KEY_BYTES


# --- サニタイズ ---


@given(st.text())
@settings(max_examples=1000)
def test_sanitize(text: str) -> None:
    out = server.sanitize(text)
    assert len(out) <= server.MAX_CHARS
    assert not set(out) & set("*_`#>[]")
    assert "http://" not in out
    assert "https://" not in out
    assert out == out.strip()
    assert server.sanitize(out) == out


@given(st.text(min_size=server.MAX_CHARS + 1, alphabet="abc"))
def test_sanitize_truncates(text: str) -> None:
    assert server.sanitize(text) == text[: server.MAX_CHARS]


# --- 声の選択 ---


def expected_lang(text: str, default_lang: str) -> str:
    if any(server.KANA.match(c) for c in text):
        return "ja"
    if any(server.HANGUL.match(c) for c in text):
        return "ko"
    if any(server.KANJI.match(c) for c in text):
        return default_lang
    return "en"


@given(mixed_text, st.sampled_from(["ja", "ko", "en", "fr", ""]))
@settings(max_examples=500)
def test_pick_voice(text: str, default_lang: str) -> None:
    voices = {"ja": "J", "ko": "K", "en": "E"}
    got = server.pick_voice(text, voices, default_lang)
    assert got in voices.values()
    assert got == voices.get(expected_lang(text, default_lang), "E")


# --- ストリーミング ---


@given(st.lists(st.binary(max_size=4096), max_size=20))
@http_settings
def test_body_is_concatenation_of_chunks(parts: list[bytes]) -> None:
    synth = StubSynth([{"type": "audio", "data": p} for p in parts])
    r = tts(make_app(synth))
    joined = b"".join(parts)
    if joined:
        assert (r.status, r.body) == (200, joined)
    else:
        assert r.status == 502


@given(st.lists(st.binary(min_size=1, max_size=64), max_size=10), st.integers(0, 10))
@http_settings
def test_failure_status_depends_on_whether_audio_was_sent(parts: list[bytes], n: int) -> None:
    synth = StubSynth([{"type": "audio", "data": p} for p in parts], fail_after=n)
    r = tts(make_app(synth))
    if min(n, len(parts)) == 0:
        assert r.status == 502
    else:
        assert r.status == 200
        assert r.error is not None
