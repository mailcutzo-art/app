"""Question references: the opaque ``ref`` strings clients use for questions."""

import re
import uuid

_REF = re.compile(r"q_([0-9a-f]{32})")


def question_ref(question_id: uuid.UUID) -> str:
    return f"q_{question_id.hex}"


def parse_ref(ref: str) -> uuid.UUID | None:
    """The question id in ``ref``, or ``None`` if it isn't a question reference."""
    match = _REF.fullmatch(ref)
    return uuid.UUID(hex=match.group(1)) if match else None
