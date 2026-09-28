"""Room codes: 6 characters of Crockford base32 (``K7M2QX``), valid while the room is open.

Crockford's alphabet has no I, L, O or U, so a typed code is forgiving: ``normalize`` upper-
cases it, drops spaces and hyphens, and reads O as 0 and I or L as 1.
"""

import secrets

ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
LENGTH = 6
_READS_AS = str.maketrans({"O": "0", "I": "1", "L": "1"})


def new_code() -> str:
    return "".join(secrets.choice(ALPHABET) for _ in range(LENGTH))


def normalize(raw: str) -> str | None:
    """The canonical code, or None if ``raw`` can't be one."""
    code = raw.strip().upper().replace("-", "").replace(" ", "").translate(_READS_AS)
    if len(code) != LENGTH or any(char not in ALPHABET for char in code):
        return None
    return code
