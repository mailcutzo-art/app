"""WebSocket gateway at ``/v1/ws``.

Skeleton only: it enforces the handshake window (a ``hello`` frame within 5 s) and then refuses
the session, because ticket authentication arrives with the realtime engine.
"""

import asyncio

import orjson
import structlog
from fastapi import APIRouter, WebSocket

from app.modules.realtime import protocol
from app.modules.realtime.protocol import CloseCode

log = structlog.stdlib.get_logger(__name__)

router = APIRouter()


@router.websocket("/ws")
async def gateway(websocket: WebSocket) -> None:
    await websocket.accept()
    try:
        async with asyncio.timeout(protocol.HELLO_TIMEOUT_S):
            message = await websocket.receive()
    except TimeoutError:
        await _close(websocket, CloseCode.HELLO_TIMEOUT, "hello timeout")
        return
    if message["type"] == "websocket.disconnect":
        return
    if not _is_hello(message.get("text")):
        await _close(websocket, CloseCode.BAD_MESSAGE, "bad message")
        return
    await _close(websocket, CloseCode.BAD_TICKET, "not implemented")


def _is_hello(text: str | None) -> bool:
    """A text frame within the size limit holding a JSON envelope of type ``hello``."""
    if text is None or len(text.encode()) > protocol.MAX_INBOUND_FRAME_BYTES:
        return False
    try:
        frame = orjson.loads(text)
    except orjson.JSONDecodeError:
        return False
    return isinstance(frame, dict) and frame.get("t") == "hello"


async def _close(websocket: WebSocket, code: CloseCode, reason: str) -> None:
    log.info("ws.closed", code=int(code), reason=reason)
    await websocket.close(code=code, reason=reason)
