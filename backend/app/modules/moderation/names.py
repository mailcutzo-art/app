"""Names that could impersonate the service or its staff."""

import functools
import json
import re
from dataclasses import dataclass
from importlib import resources

from app.modules.moderation.profanity import normalize, tokenize

_HANDLE_SEPARATORS = re.compile(r"[_\d]+")


@dataclass(frozen=True, slots=True)
class _ReservedNames:
    handles: frozenset[str]
    handle_tokens: frozenset[str]
    display_name_tokens: frozenset[str]


@functools.cache
def _reserved() -> _ReservedNames:
    data = resources.files("app.modules.moderation").joinpath("data/reserved_names.json")
    raw = json.loads(data.read_text("utf-8"))
    return _ReservedNames(
        handles=frozenset(raw["handles"]),
        handle_tokens=frozenset(raw["handle_tokens"]),
        display_name_tokens=frozenset(raw["display_name_tokens"]),
    )


def is_reserved_handle(handle: str) -> bool:
    """Reserved outright ("admin", "support"), or containing a staff word ("official_raj")."""
    reserved = _reserved()
    tokens = _HANDLE_SEPARATORS.split(handle)
    return handle in reserved.handles or any(t in reserved.handle_tokens for t in tokens)


def impersonates_staff(display_name: str) -> bool:
    """Whether a display name contains a staff word as a whole word ("Quiz Admin")."""
    words = _reserved().display_name_tokens
    return any(token in words for token in tokenize(normalize(display_name)))
