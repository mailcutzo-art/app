"""Protocol bots and an in-process ``rt`` server for realtime tests.

The rt app runs under uvicorn on a free local port, with every live timing shortened through
settings. Its database sessions join the test transaction like the REST app's, so they share one
connection: ``LockedSessions`` hands it to one session at a time.
"""

import asyncio
import contextlib
import itertools
import time
from collections.abc import AsyncIterator, Callable
from contextlib import asynccontextmanager
from dataclasses import dataclass
from typing import Any

import orjson
import uvicorn
from fastapi import FastAPI
from httpx import AsyncClient
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker
from websockets.asyncio.client import ClientConnection, connect
from websockets.exceptions import ConnectionClosed

from app.core.config import Settings
from app.main_rt import create_app as create_rt_app
from app.modules.matches.ports import Integrations
from app.modules.realtime.node import RtNode
from tests.helpers import bearer, dev_login, make_settings

# Games of 2 questions with 1.5 s each; searches that widen or time out are simulated by moving
# a ticket's joined_ms back (the rules compare against Redis time).
FAST_TIMINGS: dict[str, Any] = {
    "rt_hb_idle_s": 1,
    "rt_hb_queue_s": 1,
    "rt_hb_match_s": 1,
    "rt_stale_idle_s": 30.0,
    "rt_stale_queue_s": 30.0,
    "rt_stale_match_s": 30.0,
    "rt_lease_ms": 1000,
    "rt_lease_renew_s": 0.2,
    "rt_scan_interval_s": 0.05,
    "rt_overdue_ms": 300,
    "match_questions": 2,
    "match_limit_ms": 1500,
    "match_reveal_ms": 150,
    "match_countdown_ms": 200,
    "match_ready_ms": 1500,
    "match_show_lead_ms": 50,
    "match_answer_grace_ms": 100,
    "match_grace_ms": 1200,
    "match_drain_grace_ms": 3000,
    "match_void_window_ms": 600,
    "match_rematch_window_ms": 2000,
    "match_bot_time_scale": 0.05,
    "mm_tick_s": 0.05,
}


def fast_settings(**overrides: Any) -> Settings:
    return make_settings(**{**FAST_TIMINGS, **overrides})


class LockedSessions:
    """Sessions of the test transaction, one at a time (they share a single connection)."""

    def __init__(self, factory: async_sessionmaker[AsyncSession]) -> None:
        self.factory = factory
        self.lock = asyncio.Lock()

    @asynccontextmanager
    async def __call__(self) -> AsyncIterator[AsyncSession]:
        async with self.lock, self.factory() as session:
            yield session


@dataclass(slots=True)
class RtServer:
    url: str
    app: FastAPI
    server: uvicorn.Server
    api: AsyncClient | None = None

    @property
    def node(self) -> RtNode:
        node: RtNode = self.app.state.rt_node
        return node


@asynccontextmanager
async def run_rt(
    settings: Settings, sessions: LockedSessions, plugins: Integrations | None = None
) -> AsyncIterator[RtServer]:
    """Serve an rt app on a free port."""
    app = create_rt_app(settings, sessionmaker=sessions, plugins=plugins)
    server = uvicorn.Server(
        uvicorn.Config(
            app, host="127.0.0.1", port=0, log_config=None, timeout_graceful_shutdown=5
        )
    )
    task = asyncio.create_task(server.serve())
    while not server.started:
        if task.done():
            task.result()
        await asyncio.sleep(0.01)
    port = server.servers[0].sockets[0].getsockname()[1]
    try:
        yield RtServer(f"ws://127.0.0.1:{port}/v1/ws", app, server)
    finally:
        server.should_exit = True
        await task


class Bot:
    """A protocol client: answers pings, records every frame, and waits for the ones asked for."""

    def __init__(self, ws: ClientConnection, user_id: str, name: str) -> None:
        self.ws = ws
        self.user_id = user_id
        self.name = name
        self.frames: list[dict[str, Any]] = []
        self._cursor = 0
        self._new = asyncio.Event()
        self._ids = itertools.count(1)
        self.closed: tuple[int, str] | None = None
        self.answer_pings = True
        self._reader = asyncio.create_task(self._read())

    async def _read(self) -> None:
        try:
            async for message in self.ws:
                frame = orjson.loads(message)
                if frame.get("t") == "ping" and self.answer_pings:
                    await self.send("pong", {"n": frame["d"]["n"]})
                self.frames.append(frame)
                self._new.set()
        except ConnectionClosed:
            pass
        finally:
            rcvd = self.ws.close_code, self.ws.close_reason
            self.closed = (rcvd[0] or 0, rcvd[1] or "")
            self._new.set()

    async def send(self, event_type: str, data: dict[str, Any], *, message_id: str | None = None) -> str:
        message_id = message_id or f"c{next(self._ids)}"
        await self.ws.send(orjson.dumps({"v": 1, "t": event_type, "id": message_id, "d": data}).decode())
        return message_id

    async def expect(
        self,
        event_type: str,
        where: Callable[[dict[str, Any]], bool] | None = None,
        *,
        timeout: float = 5.0,
    ) -> dict[str, Any]:
        """The next frame of this type (after those already returned) matching ``where``."""
        async with asyncio.timeout(timeout):
            while True:
                while self._cursor < len(self.frames):
                    frame = self.frames[self._cursor]
                    self._cursor += 1
                    if frame["t"] == event_type and (where is None or where(frame)):
                        return frame
                if self.closed is not None:
                    raise AssertionError(
                        f"{self.name}: closed {self.closed} while waiting for {event_type}; "
                        f"got {[f['t'] for f in self.frames[-10:]]}"
                    )
                self._new.clear()
                await self._new.wait()

    def seen(self, event_type: str) -> list[dict[str, Any]]:
        return [frame for frame in self.frames if frame["t"] == event_type]

    async def request(self, event_type: str, data: dict[str, Any], *, timeout: float = 5.0) -> dict[str, Any]:
        """Send and return the ack or error that answers it."""
        ref = await self.send(event_type, data)
        return await self.expect_reply(ref, timeout=timeout)

    async def expect_reply(self, ref: str, *, timeout: float = 5.0) -> dict[str, Any]:
        async with asyncio.timeout(timeout):
            while True:
                for frame in self.frames:
                    if frame["t"] in {"ack", "error", "ans.ack"} and frame["d"].get("ref") == ref:
                        return frame
                if self.closed is not None:
                    raise AssertionError(f"{self.name}: closed {self.closed} awaiting {ref}")
                self._new.clear()
                await self._new.wait()

    async def wait_closed(self, timeout: float = 5.0) -> tuple[int, str]:
        async with asyncio.timeout(timeout):
            while self.closed is None:
                self._new.clear()
                await self._new.wait()
        return self.closed

    async def close(self) -> None:
        await self.ws.close()
        with contextlib.suppress(asyncio.CancelledError):
            await self._reader


async def until_shown(show: dict[str, Any], *, after_ms: int = 30) -> None:
    """Wait until a ``q.show`` question is live (the server clock is this machine's)."""
    delay = (show["d"]["shown_at"] + after_ms) / 1000 - time.time()
    if delay > 0:
        await asyncio.sleep(delay)


async def ticket(api: AsyncClient, token: str) -> str:
    response = await api.post("/v1/rt/tickets", headers=bearer(token))
    assert response.status_code == 200, response.text
    value: str = response.json()["ticket"]
    return value


async def sign_in(api: AsyncClient, email: str, *, install_id: str | None = None) -> dict[str, Any]:
    default = "install-" + email.split("@")[0]
    return await dev_login(api, email, install_id=install_id or default)


async def connect_bot(
    url: str,
    api: AsyncClient,
    login: dict[str, Any],
    *,
    name: str = "bot",
    resume: list[dict[str, Any]] | None = None,
    takeover: bool = False,
    build: int = 7,
    welcome: bool = True,
) -> Bot:
    """Open a socket, say hello with a fresh ticket and (by default) wait for the welcome."""
    ws = await connect(url, proxy=None)
    user_id = login["user"]["id"]
    bot = Bot(ws, user_id, name)
    await bot.send(
        "hello",
        {
            "ticket": await ticket(api, login["access_token"]),
            "proto": 1,
            "build": build,
            "platform": "android",
            "resume": resume or [],
            "takeover": takeover,
        },
    )
    if welcome:
        await bot.expect("welcome")
    return bot
