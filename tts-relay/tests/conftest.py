"""テストの共通部品。edge-tts はスタブに差し替え、ネットワークは使わない。"""

import asyncio
import sys
from collections.abc import AsyncIterator, Callable, Iterable, Mapping
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from aiohttp import web
from aiohttp.test_utils import TestClient, TestServer
from edge_tts.typing import TTSChunk

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import server

KEY = "k" * 32


@dataclass
class StubSynth:
    """edge_tts.Communicate の代わり。chunks を順に返し、fail_after 個返したら error を投げる。"""

    chunks: list[TTSChunk] = field(default_factory=list)
    fail_after: int | None = None
    error: Exception = field(default_factory=lambda: ConnectionError("stub failure"))
    calls: list[tuple[str, str]] = field(default_factory=list)

    def __call__(self, text: str, voice: str) -> "StubSynth":
        self.calls.append((text, voice))
        return self

    async def stream(self) -> AsyncIterator[TTSChunk]:
        for i, chunk in enumerate(self.chunks):
            if i == self.fail_after:
                raise self.error
            yield chunk
        if self.fail_after is not None and self.fail_after >= len(self.chunks):
            raise self.error


def audio(*parts: bytes) -> list[TTSChunk]:
    return [{"type": "audio", "data": p} for p in parts]


@dataclass
class Result:
    status: int
    body: bytes
    headers: Mapping[str, str]
    error: BaseException | None = None


def make_app(synth: StubSynth | None = None, **kw: Any) -> web.Application:
    return server.create_app(kw.pop("key", KEY), synth=synth or StubSynth(audio(b"mp3")), **kw)


def request(
    app: web.Application,
    method: str = "POST",
    path: str = "/tts",
    *,
    headers: Mapping[str, str] | Iterable[tuple[str, str]] | None = None,
    **kw: Any,
) -> Result:
    """テストサーバーを立てて1回だけリクエストする(Hypothesis の各例から呼べるよう同期にしている)。"""

    async def go() -> Result:
        async with TestClient(TestServer(app)) as client:
            resp = await client.request(method, path, headers=headers, **kw)
            try:
                body = await resp.read()
            except Exception as e:  # 途中で切られた本文
                return Result(resp.status, b"", resp.headers, e)
            return Result(resp.status, body, resp.headers)

    return asyncio.run(go())


def tts(app: web.Application, text: object = "こんにちは", key: str | None = KEY) -> Result:
    headers = {} if key is None else {"X-TTS-Key": key}
    return request(app, headers=headers, json={"text": text})


Factory = Callable[..., web.Application]
