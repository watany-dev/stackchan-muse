"""エンドポイントの例ベースのテスト(#9 #10 #11 #14)。"""

import os
import subprocess
import sys
from pathlib import Path

import pytest
from aiohttp import ClientPayloadError
from conftest import KEY, StubSynth, audio, make_app, request, tts

import server

SERVER = Path(server.__file__)


def test_ok_streams_stub_audio() -> None:
    synth = StubSynth(audio(b"ab", b"cd"))
    r = tts(make_app(synth))
    assert r.status == 200
    assert r.headers["Content-Type"] == "audio/mpeg"
    assert r.body == b"abcd"
    assert synth.calls == [("こんにちは", server.VOICES["ja"])]


def test_non_audio_chunks_are_skipped() -> None:
    synth = StubSynth(
        [
            {"type": "SentenceBoundary", "offset": 0.0, "duration": 1.0, "text": "x"},
            {"type": "audio", "data": b"a"},
            {"type": "WordBoundary", "offset": 0.0, "duration": 1.0, "text": "x"},
            {"type": "audio", "data": b"b"},
        ]
    )
    assert tts(make_app(synth)).body == b"ab"


def test_health() -> None:
    r = request(make_app(), "GET", "/health")
    assert (r.status, r.body) == (200, b"ok")


# --- 認証(#10) ---


@pytest.mark.parametrize("key", [None, "", "wrong", KEY + "x", KEY[:-1], KEY.upper(), "é", "鍵"])
def test_bad_key_is_401(key: str | None) -> None:
    # 前後の空白は HTTP の仕様でヘッダーから落ちるので、ここでは試せない
    synth = StubSynth(audio(b"x"))
    r = tts(make_app(synth), key=key)
    assert r.status == 401
    assert synth.calls == []


def test_non_ascii_raw_header_is_401() -> None:
    # ブラウザ以外のクライアントは生の UTF-8 バイトを送れる
    r = request(make_app(), headers=[("X-TTS-Key", "é")], json={"text": "hi"})
    assert r.status == 401


@pytest.mark.parametrize("key", [None, "", "short", "x" * (server.MIN_KEY_BYTES - 1)])
def test_bad_key_config_is_rejected(key: str | None) -> None:
    with pytest.raises(server.ConfigError):
        server.create_app(key)


def test_long_enough_key_is_accepted() -> None:
    server.create_app("x" * server.MIN_KEY_BYTES)


@pytest.mark.parametrize("env", [{}, {"TTS_KEY": ""}])
def test_server_refuses_to_start_without_key(env: dict[str, str]) -> None:
    base = {k: v for k, v in os.environ.items() if k != "TTS_KEY"}
    p = subprocess.run(  # noqa: S603
        [sys.executable, str(SERVER)],
        env={**base, **env, "PORT": "0"},
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )
    assert p.returncode != 0
    assert "TTS_KEY" in p.stderr
    assert "Traceback" not in p.stderr


# --- 本文の検査(#11) ---


@pytest.mark.parametrize("text", [None, True, 1, 1.5, ["a"], {"a": 1}])
def test_non_string_text_is_400(text: object) -> None:
    synth = StubSynth(audio(b"x"))
    r = tts(make_app(synth), text=text)
    assert r.status == 400
    assert synth.calls == []


@pytest.mark.parametrize(
    "data",
    [b"", b"not json", b"[1]", b'"text"', b"{}", b'{"txt": "a"}'],
)
def test_bad_body_is_400(data: bytes) -> None:
    r = request(make_app(), headers={"X-TTS-Key": KEY}, data=data)
    assert r.status == 400


@pytest.mark.parametrize("text", ["", "   ", "**`#>[]_", "https://example.com", "* http:// _"])
def test_markdown_only_is_400(text: str) -> None:
    r = tts(make_app(), text=text)
    assert (r.status, r.body) == (400, b"empty text")


def test_broken_utf8_bytes_are_dropped() -> None:
    # ファームが文字の途中で切った返答(#12)でも、読める部分は読み上げる
    synth = StubSynth(audio(b"x"))
    r = request(
        make_app(synth),
        headers={"X-TTS-Key": KEY},
        data='{"text":"こんにちは"}'.encode()[:-5] + b'\xe3\x81"}',
    )
    assert r.status == 200
    assert synth.calls == [("こんにち", server.VOICES["ja"])]


def test_too_large_body_is_413() -> None:
    r = tts(make_app(), text="a" * (16 * 1024))
    assert r.status == 413


def test_text_is_sanitized_before_synthesis() -> None:
    synth = StubSynth(audio(b"x"))
    tts(make_app(synth), text="  **hello** see https://example.com  ")
    assert synth.calls == [("hello   see", server.VOICES["en"])]


# --- edge-tts の失敗(#9) ---


def test_failure_before_audio_is_502() -> None:
    r = tts(make_app(StubSynth(audio(b"x"), fail_after=0)))
    assert r.status == 502


def test_failure_when_constructing_is_502() -> None:
    def broken(_text: str, _voice: str) -> StubSynth:
        msg = "Invalid voice"
        raise ValueError(msg)

    r = tts(server.create_app(KEY, synth=broken))
    assert r.status == 502


@pytest.mark.parametrize(
    "chunks",
    [[], audio(b""), [{"type": "SentenceBoundary", "offset": 0.0, "duration": 0.0, "text": "a"}]],
)
def test_no_audio_is_502(chunks: list) -> None:  # type: ignore[type-arg]
    r = tts(make_app(StubSynth(chunks)))
    assert r.status == 502


def test_failure_mid_stream_drops_connection() -> None:
    r = tts(make_app(StubSynth(audio(b"a", b"b", b"c"), fail_after=2)))
    assert r.status == 200
    assert isinstance(r.error, ClientPayloadError)
