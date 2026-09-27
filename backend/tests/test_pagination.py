import base64
import uuid
from datetime import UTC, datetime

import pytest
from pydantic import BaseModel

from app.core.pagination import InvalidCursor, decode_cursor, encode_cursor


class Position(BaseModel):
    created_at: datetime
    id: uuid.UUID


POSITION = Position(created_at=datetime(2026, 9, 27, 12, 30, tzinfo=UTC), id=uuid.uuid4())


def b64(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def test_round_trip_is_url_safe() -> None:
    cursor = encode_cursor(POSITION)

    assert "=" not in cursor
    assert decode_cursor(cursor, Position) == POSITION


@pytest.mark.parametrize(
    "cursor",
    [
        "",
        "not base64 !",
        "A" * 513,
        b64(b"not json"),
        b64(b"[1, 2]"),
        b64(b'{"created_at": "yesterday", "id": "x"}'),
        b64(b'{"id": "0190c0de-0000-7000-8000-000000000000"}'),
        b64(b"\xff\xfe"),
        encode_cursor(POSITION)[:-3],
    ],
)
def test_invalid_cursors_are_rejected(cursor: str) -> None:
    with pytest.raises(InvalidCursor) as raised:
        decode_cursor(cursor, Position)

    assert raised.value.code == "INVALID_CURSOR"
    assert raised.value.http_status == 422
