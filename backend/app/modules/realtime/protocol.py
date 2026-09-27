"""Realtime protocol v1 constants shared by the gateway and the engine."""

from enum import IntEnum

PROTOCOL_VERSION = 1
HELLO_TIMEOUT_S = 5.0
MAX_INBOUND_FRAME_BYTES = 4096


class CloseCode(IntEnum):
    """WebSocket close codes the server uses (docs/plan.md, "Envelope and limits")."""

    SERVER_RESTART = 1012
    TRY_AGAIN_LATER = 1013
    BAD_MESSAGE = 4400
    BAD_TICKET = 4401
    REVOKED = 4403
    HELLO_TIMEOUT = 4408
    SUPERSEDED = 4409
    UPDATE_REQUIRED = 4426
    RATE_LIMITED = 4429
