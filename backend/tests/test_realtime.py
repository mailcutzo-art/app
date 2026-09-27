"""The realtime process: probes and the WebSocket handshake window, over a real server."""

import asyncio
from collections.abc import AsyncIterator

import pytest
import uvicorn
from websockets.asyncio.client import connect
from websockets.exceptions import ConnectionClosed

from app.core.config import Settings
from app.main_rt import create_app
from app.modules.realtime import protocol
from tests.helpers import serve


@pytest.fixture
async def ws_url(settings: Settings) -> AsyncIterator[str]:
    """Serve the rt app with uvicorn on a free local port; yield its WebSocket URL."""
    server = uvicorn.Server(
        uvicorn.Config(create_app(settings), host="127.0.0.1", port=0, log_config=None)
    )
    task = asyncio.create_task(server.serve())
    while not server.started:
        if task.done():
            task.result()  # surface startup errors
        await asyncio.sleep(0.01)
    port = server.servers[0].sockets[0].getsockname()[1]
    yield f"ws://127.0.0.1:{port}/v1/ws"
    server.should_exit = True
    await task


async def close_after(ws_url: str, frame: str | bytes | None) -> tuple[int, str]:
    """Connect, optionally send one frame, and return the server's close code and reason."""
    async with connect(ws_url, proxy=None) as ws:
        if frame is not None:
            await ws.send(frame)
        with pytest.raises(ConnectionClosed) as closed:
            await ws.recv()
    assert closed.value.rcvd is not None
    return closed.value.rcvd.code, closed.value.rcvd.reason


async def test_probes(settings: Settings) -> None:
    async with serve(create_app(settings)) as client:
        health = await client.get("/healthz")
        ready = await client.get("/readyz")

    assert health.json() == {"status": "ok"}
    assert ready.status_code == 200


async def test_hello_is_refused_until_ticket_auth_exists(ws_url: str) -> None:
    hello = '{"v": 1, "t": "hello", "id": "1", "d": {"ticket": "t", "proto": 1}}'

    assert await close_after(ws_url, hello) == (4401, "not implemented")


async def test_no_hello_within_the_window_closes_4408(
    ws_url: str, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(protocol, "HELLO_TIMEOUT_S", 0.2)

    assert await close_after(ws_url, None) == (4408, "hello timeout")


@pytest.mark.parametrize(
    "frame",
    [
        "not json",
        '{"t": "mm.join"}',
        '["hello"]',
        b'{"t": "hello"}',
        '{"t": "hello", "pad": "' + "x" * protocol.MAX_INBOUND_FRAME_BYTES + '"}',
    ],
)
async def test_anything_but_a_hello_frame_closes_4400(ws_url: str, frame: str | bytes) -> None:
    assert await close_after(ws_url, frame) == (4400, "bad message")
