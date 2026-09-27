"""The quiz text markup (``docs/content-format.md``): ``x^2``, ``x^{n+1}``, ``H_2O``, ``*i*``."""

import re

_GROUP = re.compile(r"[\^_]\{([^{}]*)\}")
_SINGLE = re.compile(r"[\^_](\S)")
_EMPHASIS = re.compile(r"\*+")


def plain_text(text: str) -> str:
    """``text`` without markup and with whitespace collapsed: "H_2SO_4 in m s^{-2}" ->
    "H2SO4 in m s-2". Used for search, where the markup would only get in the way."""
    previous = None
    while previous != text:  # innermost groups first, for nested braces
        previous, text = text, _GROUP.sub(r"\1", text)
    text = _SINGLE.sub(r"\1", text)
    text = _EMPHASIS.sub("", text)
    return " ".join(text.split())
