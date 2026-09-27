"""Opaque cursors for keyset pagination.

A cursor is the base64url-encoded JSON of a small pydantic model describing the position after
the last returned item. Cursors are not signed: decoding validates them strictly, and queries
must still scope results to what the caller may see, so a forged cursor only moves the position.
"""

import base64
import binascii
import re
from typing import TypeVar

from pydantic import BaseModel, ValidationError

from app.core.errors import ValidationFailed

MAX_CURSOR_LENGTH = 512
_CURSOR_PATTERN = re.compile(r"[A-Za-z0-9_-]+")

PositionT = TypeVar("PositionT", bound=BaseModel)


class InvalidCursor(ValidationFailed):
    default_code = "INVALID_CURSOR"
    default_message = "The pagination cursor is invalid or expired."


def encode_cursor(position: BaseModel) -> str:
    raw = position.model_dump_json().encode()
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


def decode_cursor(cursor: str, model: type[PositionT]) -> PositionT:
    """Decode a cursor made by ``encode_cursor``; raises ``InvalidCursor`` (422) otherwise."""
    if len(cursor) > MAX_CURSOR_LENGTH or not _CURSOR_PATTERN.fullmatch(cursor):
        raise InvalidCursor()
    try:
        raw = base64.urlsafe_b64decode(cursor + "=" * (-len(cursor) % 4))
        return model.model_validate_json(raw)
    except (binascii.Error, ValueError, ValidationError) as exc:
        raise InvalidCursor() from exc
