"""Helpers for the room tests: onboarded players with sockets, rooms made over REST, and
games played to the end."""

import asyncio
import uuid
from typing import Any

from httpx import AsyncClient
from redis.asyncio import Redis

from app.core.config import Settings
from app.modules.realtime import keys
from tests.rt_helpers import Bot, RtServer, connect_bot, correct_option, fast_settings, until_shown
from tests.social_helpers import Player, player

# Rooms in tests: every live timing short, seconds per question scaled to about 1.5 s.
ROOM_TIMINGS: dict[str, Any] = {
    "room_time_scale": 0.1,
    "room_autostart_ms": 200,
    "room_group_reveal_ms": 150,
    "room_group_short_ms": 600,
    "room_friend_grace_ms": 1500,
}


def room_settings(**overrides: Any) -> Settings:
    return fast_settings(**{**ROOM_TIMINGS, **overrides})


async def online(rt: RtServer, api: AsyncClient, name: str) -> tuple[Player, Bot]:
    """An onboarded player with an open socket."""
    who = await player(api, name)
    return who, await connect_bot(rt.url, api, who.login, name=name)


async def make_room(
    api: AsyncClient, host: Player, kind: str = "friend", **settings: Any
) -> dict[str, Any]:
    response = await api.post(
        "/v1/rooms",
        json={"kind": kind, "settings": {"subject": "physics", "questions": 5, **settings}},
        headers={**host.headers, "Idempotency-Key": uuid.uuid4().hex},
    )
    assert response.status_code == 201, response.text
    body: dict[str, Any] = response.json()
    return body


async def join(bot: Bot, **where: Any) -> dict[str, Any]:
    reply = await bot.request("room.join", where)
    assert reply["t"] == "ack", reply
    return reply


async def seen_or_next(
    bot: Bot, event_type: str, where: Any = None, *, wait_s: float = 5.0
) -> dict[str, Any]:
    """A frame of this type matching ``where``, already received or still to come (order
    between channels isn't fixed)."""
    async with asyncio.timeout(wait_s):
        while True:
            for frame in bot.frames:
                if frame["t"] == event_type and (where is None or where(frame)):
                    return frame
            await asyncio.sleep(0.02)


async def shorten(redis: Redis, rid: str, **fields: int) -> None:
    """Make a room's own timings (set at creation from the api's settings) shorter."""
    await redis.hset(keys.room(rid), mapping=fields)
    await redis.zadd(keys.ROOM_TIMERS, {rid: 0})


async def play_out(redis: Redis, mid: str, bots: list[Bot], *, total: int) -> dict[str, Any]:
    """Everyone answers every question (the first bot right, the rest wrong); returns the
    first bot's ``match.end``."""
    for _ in range(total):
        shows = [await bot.expect("q.show") for bot in bots]
        await until_shown(shows[0])
        right = await correct_option(redis, mid, shows[0]["d"]["q"])
        for index, (bot, show) in enumerate(zip(bots, shows, strict=True)):
            wrong = next(o["id"] for o in show["d"]["options"] if o["id"] != right)
            await bot.request(
                "ans.submit",
                {
                    "match_id": mid,
                    "q": show["d"]["q"],
                    "opt": right if index == 0 else wrong,
                    "el_ms": 100 + index,
                },
            )
        for bot in bots:
            await bot.expect("q.reveal")
    return await bots[0].expect("match.end", wait_s=8)
