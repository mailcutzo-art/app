"""Profanity detection for display names and handles (English, Hinglish and Devanagari Hindi).

Text is normalized before matching: NFKC, lowercase, zero-width characters and Latin diacritics
removed, and look-alike Cyrillic/Greek letters mapped to Latin. Matching is by whole token, in a
few views of the text (as written, with leetspeak mapped, with in-word punctuation removed) and
with runs of repeated letters collapsed. Whole-token matching keeps ordinary words that merely
contain a bad word ("Scunthorpe", "assassin", "cocktail", "Kshitij") acceptable.

Handles have no spaces, so they are split on ``_`` and digits and are also checked for a short
list of substrings that never occur inside ordinary words or names.
"""

import functools
import json
import re
import unicodedata
from collections.abc import Iterable, Iterator
from dataclasses import dataclass
from importlib import resources

_LATIN_DIACRITICS = re.compile("[\u0300-\u036f]")
_DEVANAGARI_NUKTA = "\u093c"
_REPEATS = re.compile(r"(.)\1+")
_HANDLE_SEPARATORS = re.compile(r"[_\d]+")
# Trailing digits are usually a number ("rahul2008", "Galaxy A55"), not leetspeak.
_TRAILING_DIGITS = re.compile(r"\d+$")
# Punctuation put inside a word to dodge filters: "f.u.c.k", "f*ck", "sh-it".
_IN_WORD_PUNCTUATION = re.compile(r"(?<=\w)[*.\-'_~^]+(?=\w)")
_MIN_SPELLED_OUT = 3


@dataclass(frozen=True, slots=True)
class _Lexicon:
    words: frozenset[str]
    handle_substrings: tuple[str, ...]
    leetspeak: dict[int, str]
    leet_symbols: dict[int, str]
    confusables: dict[int, str]


@functools.cache
def _lexicon() -> _Lexicon:
    data = resources.files("app.modules.moderation").joinpath("data/profanity.json")
    raw = json.loads(data.read_text("utf-8"))
    leet: dict[str, str] = raw["leetspeak"]
    confusables = str.maketrans(raw["confusables"])
    words = {_normalize(word, confusables) for group in raw["words"].values() for word in group}
    return _Lexicon(
        words=frozenset(words),
        handle_substrings=tuple(raw["handle_substrings"]),
        leetspeak=str.maketrans(leet),
        leet_symbols=str.maketrans({k: v for k, v in leet.items() if not k.isdigit()}),
        confusables=confusables,
    )


def normalize(text: str) -> str:
    """Canonical form used for matching (never for display)."""
    return _normalize(text, _lexicon().confusables)


def _normalize(text: str, confusables: dict[int, str]) -> str:
    text = unicodedata.normalize("NFKC", text).casefold()
    text = "".join(ch for ch in text if unicodedata.category(ch) != "Cf")  # zero-width, bidi
    text = _LATIN_DIACRITICS.sub("", unicodedata.normalize("NFD", text))
    text = text.replace(_DEVANAGARI_NUKTA, "")
    return unicodedata.normalize("NFC", text).translate(confusables)


def tokenize(text: str) -> list[str]:
    """Split on anything that is not a letter, combining mark or digit.

    Marks are kept so Devanagari words (whose vowel signs are marks) stay whole.
    """
    tokens: list[str] = []
    current: list[str] = []
    for ch in text:
        if unicodedata.category(ch)[0] in "LMN":
            current.append(ch)
        elif current:
            tokens.append("".join(current))
            current = []
    if current:
        tokens.append("".join(current))
    return tokens


def _deleet(token: str, lexicon: _Lexicon) -> str:
    return _TRAILING_DIGITS.sub("", token).translate(lexicon.leetspeak)


def _variants(token: str) -> set[str]:
    """The token and its repeated-letter collapses ("fuuuck" -> "fuck", "asss" -> "ass")."""
    return {token, _REPEATS.sub(r"\1\1", token), _REPEATS.sub(r"\1", token)}


def _has_bad_token(tokens: Iterable[str], lexicon: _Lexicon) -> bool:
    return any(variant in lexicon.words for token in tokens for variant in _variants(token))


def _spelled_out(tokens: list[str]) -> Iterator[str]:
    """Rejoin words spelled letter by letter: ["f", "u", "c", "k"] -> "fuck"."""
    run: list[str] = []
    for token in [*tokens, ""]:
        if len(token) == 1:
            run.append(token)
            continue
        if len(run) >= _MIN_SPELLED_OUT:
            yield "".join(run)
        run = []


def contains_profanity(text: str) -> bool:
    """Whether free text such as a display name contains a profane word."""
    lexicon = _lexicon()
    normalized = _normalize(text, lexicon.confusables)
    symbols_mapped = normalized.translate(lexicon.leet_symbols)
    views = (
        tokenize(normalized),
        [_deleet(t, lexicon) for t in tokenize(symbols_mapped)],
        [_deleet(t, lexicon) for t in tokenize(_IN_WORD_PUNCTUATION.sub("", symbols_mapped))],
    )
    return any(
        _has_bad_token(tokens, lexicon) or _has_bad_token(_spelled_out(tokens), lexicon)
        for tokens in views
    )


def is_profane_handle(handle: str) -> bool:
    """Whether a handle (``[a-z0-9_]``) is profane, by token or by unambiguous substring."""
    lexicon = _lexicon()
    handle = _normalize(handle, lexicon.confusables)
    plain = [token for token in _HANDLE_SEPARATORS.split(handle) if token]
    leet = [_deleet(chunk, lexicon) for chunk in handle.split("_") if chunk]
    if _has_bad_token(plain, lexicon) or _has_bad_token(leet, lexicon):
        return True
    compact = handle.replace("_", "")
    candidates = _variants(compact) | _variants(_deleet(compact, lexicon))
    return any(bad in candidate for candidate in candidates for bad in lexicon.handle_substrings)
