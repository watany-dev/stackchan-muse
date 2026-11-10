"""スタックチャン TTS 中継 — Muse の文字の返答を MP3 にして返す。

POST /tts  {"text": "..."}  ヘッダー X-TTS-Key  →  audio/mpeg (24kHz 48kbps モノラル、チャンクで流す)
GET  /health                                    →  ok

127.0.0.1 だけで待ち受け、nginx 経由で公開する。音声は edge-tts(Microsoft Edge のオンライン読み上げ)を使う。

声は文字種で選ぶ: かなを含めば日本語、ハングルを含めば韓国語、漢字だけなら TTS_DEFAULT_LANG、
それ以外は英語。

返すステータス:
  401  X-TTS-Key が違う
  400  本文が JSON でない、text が文字列でない、記号を除くと空
       (文字の途中で切れた返答(#12)も読めるよう、壊れた UTF-8 のバイトは捨てて読む)
  413  本文が 16KB を超える
  502  edge-tts が最初の音声を返す前に失敗した、または音声を1つも返さなかった
流し始めた後に edge-tts が失敗したときはステータスを変えられないので、終端を送らずに接続を切る
(クライアントからは本文が途中で切れたように見える)。
"""

import hmac
import json
import logging
import os
import re
import sys
import time
from collections.abc import AsyncIterator, Callable, Mapping
from typing import Protocol

import edge_tts
from aiohttp import web
from edge_tts.typing import TTSChunk

MAX_CHARS = 1000
# キーはこのバイト数以上を求める(README の手順 `openssl rand -hex 24` は 48 バイト)
MIN_KEY_BYTES = 16
VOICES = {
    "ja": os.environ.get("TTS_VOICE_JA", "ja-JP-NanamiNeural"),
    "ko": os.environ.get("TTS_VOICE_KO", "ko-KR-SunHiNeural"),
    "en": os.environ.get("TTS_VOICE_EN", "en-US-AriaNeural"),
}
# 漢字だけの返答(「了解」など)は中国語と区別できないので、この言語で読む
DEFAULT_LANG = os.environ.get("TTS_DEFAULT_LANG", "ja")
KANA = re.compile(r"[぀-ヿㇰ-ㇿｦ-ﾟ]")
HANGUL = re.compile(r"[㄰-㆏가-힣]")
KANJI = re.compile(r"[㐀-䶿一-鿿]")
MARKDOWN = re.compile(r"[*_`#>\[\]]|https?://\S*")
log = logging.getLogger("stackchan-tts")


class Synthesizer(Protocol):
    def stream(self) -> AsyncIterator[TTSChunk]: ...


# edge_tts.Communicate と同じ形。テストではスタブに差し替える
SynthFactory = Callable[[str, str], Synthesizer]

KEY = web.AppKey("key", bytes)
VOICES_KEY = web.AppKey("voices", Mapping[str, str])
DEFAULT_LANG_KEY = web.AppKey("default_lang", str)
SYNTH_KEY: web.AppKey[SynthFactory] = web.AppKey("synth")


class ConfigError(ValueError):
    """起動時の設定が不正。"""


def _to_bytes(s: str) -> bytes:
    # surrogatepass は単射なので、bytes が等しいことと str が等しいことは同じ。
    # os.environ や aiohttp のヘッダーが含みうるサロゲートでも例外にならない
    return s.encode("utf-8", "surrogatepass")


def check_key(key: str | None) -> bytes:
    if key is None:
        msg = "TTS_KEY が設定されていません。.env を読み込んでから起動してください(README 参照)"
        raise ConfigError(msg)
    raw = _to_bytes(key)
    if len(raw) < MIN_KEY_BYTES:
        msg = f"TTS_KEY が短すぎます({len(raw)} バイト)。{MIN_KEY_BYTES} バイト以上にしてください(例: openssl rand -hex 24)"
        raise ConfigError(msg)
    return raw


def key_matches(given: str | None, key: bytes) -> bool:
    return hmac.compare_digest(_to_bytes(given or ""), key)


def sanitize(text: str) -> str:
    """読み上げに向かない記号と URL を消し、前後の空白を落として MAX_CHARS 文字までにする。"""
    return MARKDOWN.sub(" ", text).strip()[:MAX_CHARS].rstrip()


def pick_voice(
    text: str, voices: Mapping[str, str] = VOICES, default_lang: str = DEFAULT_LANG
) -> str:
    if KANA.search(text):
        lang = "ja"
    elif HANGUL.search(text):
        lang = "ko"
    elif KANJI.search(text):
        lang = default_lang
    else:
        lang = "en"
    return voices.get(lang, voices["en"])


async def read_text(request: web.Request) -> str | web.Response:
    """本文から読み上げる文字列を取り出す。だめなら 400 のレスポンスを返す(413 は例外のまま上に投げる)。"""
    try:
        body = json.loads((await request.read()).decode("utf-8", errors="ignore"))
    except ValueError:
        return web.Response(status=400, text='need JSON {"text": ...}')
    text = body.get("text") if isinstance(body, dict) else None
    if not isinstance(text, str):
        return web.Response(status=400, text='need JSON {"text": ...} with a string')
    text = sanitize(text)
    if not text:
        return web.Response(status=400, text="empty text")
    return text


async def tts(request: web.Request) -> web.StreamResponse:
    app = request.app
    if not key_matches(request.headers.get("X-TTS-Key"), app[KEY]):
        return web.Response(status=401, text="bad key")
    text = await read_text(request)
    if isinstance(text, web.Response):
        return text

    voice = pick_voice(text, app[VOICES_KEY], app[DEFAULT_LANG_KEY])
    t0 = time.monotonic()
    first = None
    size = 0
    # 最初の音声が届くまで prepare() しない。それまでの失敗は 502 で返せる
    resp: web.StreamResponse | None = None
    try:
        async for chunk in app[SYNTH_KEY](text, voice).stream():
            data = chunk.get("data") if chunk["type"] == "audio" else None
            if not data:
                continue
            if resp is None:
                first = time.monotonic() - t0
                resp = web.StreamResponse(headers={"Content-Type": "audio/mpeg"})
                await resp.prepare(request)
            size += len(data)
            await resp.write(data)
    except Exception:
        if resp is None:
            log.exception("edge-tts failed before any audio (%s)", voice)
            return web.Response(status=502, text="tts failed")
        log.exception("edge-tts failed after %d bytes (%s); dropping connection", size, voice)
        if request.transport is not None:
            request.transport.close()
        return resp
    if resp is None:
        log.warning("edge-tts returned no audio (%s)", voice)
        return web.Response(status=502, text="tts returned no audio")
    await resp.write_eof()
    log.info(
        "%d chars, %s: first audio %.2fs, done %.2fs, %d bytes",
        len(text),
        voice,
        first or -1,
        time.monotonic() - t0,
        size,
    )
    return resp


async def health(_: web.Request) -> web.Response:
    return web.Response(text="ok")


def create_app(
    key: str | None,
    *,
    voices: Mapping[str, str] = VOICES,
    default_lang: str = DEFAULT_LANG,
    synth: SynthFactory = edge_tts.Communicate,
) -> web.Application:
    app = web.Application(client_max_size=16 * 1024)
    app[KEY] = check_key(key)
    app[VOICES_KEY] = voices
    app[DEFAULT_LANG_KEY] = default_lang
    app[SYNTH_KEY] = synth
    app.add_routes([web.post("/tts", tts), web.get("/health", health)])
    return app


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    try:
        app = create_app(os.environ.get("TTS_KEY"))
    except ConfigError as e:
        sys.exit(f"stackchan-tts: {e}")
    web.run_app(app, host="127.0.0.1", port=int(os.environ.get("PORT", "3710")))


if __name__ == "__main__":
    main()
