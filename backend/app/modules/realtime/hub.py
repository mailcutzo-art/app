"""Node-local pub/sub fan-out.

One Redis pub/sub connection per node. Local listeners (sockets) register for channels; the
node subscribes to a channel while at least one local listener wants it and unsubscribes when
the last one leaves (``ev:u:{uid}`` and ``ctl:u:{uid}`` per connected user, ``ev:m:{mid}`` while
a local member plays that match).
"""

import asyncio
import contextlib
from collections.abc import Callable

import structlog
from redis.asyncio import Redis
from redis.asyncio.client import PubSub
from redis.exceptions import RedisError

log = structlog.stdlib.get_logger(__name__)

Listener = Callable[[str, str], None]  # (channel, message)


class Hub:
    def __init__(self, redis: Redis) -> None:
        self._redis = redis
        self._pubsub: PubSub | None = None
        self._listeners: dict[str, set[Listener]] = {}
        self._reader: asyncio.Task[None] | None = None
        self._lock = asyncio.Lock()

    async def start(self) -> None:
        self._pubsub = self._redis.pubsub(ignore_subscribe_messages=True)
        # A placeholder subscription keeps the connection open before any socket arrives.
        await self._pubsub.subscribe("rt:hub")
        self._reader = asyncio.create_task(self._read(), name="rt:hub")

    async def stop(self) -> None:
        if self._reader is not None:
            self._reader.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await self._reader
        if self._pubsub is not None:
            with contextlib.suppress(RedisError):
                await self._pubsub.aclose()  # type: ignore[no-untyped-call]
        self._listeners.clear()

    async def subscribe(self, channel: str, listener: Listener) -> None:
        async with self._lock:
            listeners = self._listeners.setdefault(channel, set())
            first = not listeners
            listeners.add(listener)
            if first and self._pubsub is not None:
                await self._pubsub.subscribe(channel)

    async def unsubscribe(self, channel: str, listener: Listener) -> None:
        async with self._lock:
            listeners = self._listeners.get(channel)
            if listeners is None:
                return
            listeners.discard(listener)
            if not listeners:
                del self._listeners[channel]
                if self._pubsub is not None:
                    with contextlib.suppress(RedisError):
                        await self._pubsub.unsubscribe(channel)

    def listening(self, channel: str) -> bool:
        return bool(self._listeners.get(channel))

    async def _read(self) -> None:
        assert self._pubsub is not None  # noqa: S101 - set by start()
        while True:
            try:
                message = await self._pubsub.get_message(timeout=1.0)
            except RedisError:
                log.warning("rt.hub_read_failed", exc_info=True)
                await asyncio.sleep(0.5)
                continue
            if message is None or message.get("type") != "message":
                continue
            channel, data = message["channel"], message["data"]
            for listener in list(self._listeners.get(channel, ())):
                try:
                    listener(channel, data)
                except Exception:
                    log.exception("rt.hub_listener_failed", channel=channel)
