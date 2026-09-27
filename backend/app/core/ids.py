"""Identifier generation."""

from uuid import UUID

from uuid_utils.compat import uuid7


def new_id() -> UUID:
    """Return a new UUIDv7 (time-ordered, so primary-key inserts stay index-friendly)."""
    return uuid7()
