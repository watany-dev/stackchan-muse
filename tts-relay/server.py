"""スタックチャン TTS 中継 — Muse の文字の返答を MP3 にして返す。

POST /tts  {"text": "..."}  ヘッダー X-TTS-Key  →  audio/mpeg (24kHz 48kbps モノラル、チャンクで流す)
GET  /health                                    →  ok

127.0.0.1 だけで待ち受け、nginx 経由で公開する。音声は edge-tts(Microsoft Edge のオンライン読み上げ)を使う。

声は文字種で選ぶ: かなを含めば日本語、ハングルを含めば韓国語、漢字だけなら TTS_DEFAULT_LANG、
それ以外は英語。
"""

import hmac
import logging
import os
import re
import time

import edge_tts
from aiohttp import web

KEY = os.environ["TTS_KEY"]
MAX_CHARS = 1000
VOICES = {
    "ja": os.environ.get("TTS_VOICE_JA", "ja-JP-NanamiNeural"),
    "ko": os.environ.get("TTS_VOICE_KO", "ko-KR-SunHiNeural"),
    "en": os.environ.get("TTS_VOICE_EN", "en-US-AriaNeural"),
}
# 漢字だけの返答(「了解」など)は中国語と区別できないので、この言語で読む
DEFAULT_LANG = os.environ.get("TTS_DEFAULT_LANG", "ja")
KANA = re.compile(r"[\u3040-\u30ff\u31f0-\u31ff\uff66-\uff9f]")
HANGUL = re.compile(r"[\u3130-\u318f\uac00-\ud7a3]")
KANJI = re.compile(r"[\u3400-\u4dbf\u4e00-\u9fff]")
MARKDOWN = re.compile(r"[*_`#>\[\]]|https?://\S+")
log = logging.getLogger("stackchan-tts")


def pick_voice(text: str) -> str:
    if KANA.search(text):
        lang = "ja"
    elif HANGUL.search(text):
        lang = "ko"
    elif KANJI.search(text):
        lang = DEFAULT_LANG
    else:
        lang = "en"
    return VOICES.get(lang, VOICES["en"])


async def tts(request: web.Request) -> web.StreamResponse:
    if not hmac.compare_digest(request.headers.get("X-TTS-Key", ""), KEY):
        return web.Response(status=401, text="bad key")
    try:
        body = await request.json()
        text = str(body["text"])
    except Exception:
        return web.Response(status=400, text='need JSON {"text": ...}')
    text = MARKDOWN.sub(" ", text).strip()[:MAX_CHARS]
    if not text:
        return web.Response(status=400, text="empty text")

    voice = pick_voice(text)
    t0 = time.monotonic()
    first = None
    size = 0
    resp = web.StreamResponse(headers={"Content-Type": "audio/mpeg"})
    await resp.prepare(request)
    async for chunk in edge_tts.Communicate(text, voice).stream():
        if chunk["type"] == "audio":
            if first is None:
                first = time.monotonic() - t0
            size += len(chunk["data"])
            await resp.write(chunk["data"])
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


app = web.Application(client_max_size=16 * 1024)
app.add_routes([web.post("/tts", tts), web.get("/health", health)])

if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    web.run_app(app, host="127.0.0.1", port=int(os.environ.get("PORT", "3710")))
