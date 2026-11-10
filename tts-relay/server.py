"""StackChan TTS 중계 — Muse 의 글자 답을 MP3 로 바꿔 돌려준다.

POST /tts  {"text": "..."}  헤더 X-TTS-Key  →  audio/mpeg (24kHz 48kbps mono, 청크로 흘려보낸다)
GET  /health                                  →  ok

127.0.0.1 에만 열고 nginx 를 거쳐 공개한다. 음성은 edge-tts(Microsoft Edge 의 온라인 음성)를 쓴다.
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
VOICE_KO = os.environ.get("TTS_VOICE_KO", "ko-KR-SunHiNeural")
VOICE_EN = os.environ.get("TTS_VOICE_EN", "en-US-AriaNeural")
HANGUL = re.compile(r"[㄰-㆏가-힣]")
MARKDOWN = re.compile(r"[*_`#>\[\]]|https?://\S+")
log = logging.getLogger("stackchan-tts")


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

    voice = VOICE_KO if HANGUL.search(text) else VOICE_EN
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
