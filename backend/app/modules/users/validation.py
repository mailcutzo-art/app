"""Profile field rules shared by onboarding, profile edits, dev login and the handle check.

Messages are shown to users next to the field, so they are written for people.
"""

import re
import unicodedata
from datetime import datetime
from enum import StrEnum

from app.core.clock import IST
from app.modules.moderation.names import impersonates_staff, is_reserved_handle
from app.modules.moderation.profanity import contains_profanity, is_profane_handle

DISPLAY_NAME_MIN = 2
DISPLAY_NAME_MAX = 30
HANDLE_PATTERN = re.compile(r"[a-z0-9_]{3,20}")
MIN_AGE = 10
MAX_AGE = 100
ADULT_AGE = 18
FALLBACK_DISPLAY_NAME = "Player"

AVATAR_TONES = frozenset({"lime", "sky", "mint", "lemon", "lavender", "peach", "rose"})
AVATAR_SYMBOLS = frozenset(
    {
        "rocket", "atom", "flask", "dna", "pi", "brain", "idea", "star", "crown", "medal",
        "fire", "flash", "leaf", "cube", "globe", "target", "sparkles", "smile", "graduation",
        "book", "sun", "moon", "trophy", "robot",
    }
)  # fmt: skip
DEFAULT_AVATAR_TONE = "lime"
DEFAULT_AVATAR_SYMBOL = "rocket"

GOAL_MESSAGE = "Choose NEET or JEE."
TONE_MESSAGE = "Choose one of the avatar colours."
SYMBOL_MESSAGE = "Choose one of the avatar symbols."


class HandleProblem(StrEnum):
    INVALID = "invalid"
    RESERVED = "reserved"
    TAKEN = "taken"


HANDLE_MESSAGES = {
    HandleProblem.INVALID: "Use 3–20 letters, numbers or _",
    HandleProblem.RESERVED: "That username isn't allowed",
    HandleProblem.TAKEN: "That username is taken",
}

_URL = re.compile(
    r"https?://|www\.|\b[\w-]+\.(?:com|net|org|in|io|co|me|app|gg|tv|ly|xyz|info|site|link|"
    r"online|store|shop|live)\b",
    re.IGNORECASE,
)
_MENTION = re.compile(r"@\w")
_PHONE = re.compile(r"(?:\d[\s().+-]*){7,}")  # 7+ digits, however they are separated
_WHITESPACE = re.compile(r"\s+")
_ZERO_WIDTH_JOINERS = frozenset({"\u200c", "\u200d"})
_DEVANAGARI_VIRAMA = "\u094d"
_VARIATION_SELECTOR = "\ufe0f"


def clean_display_name(raw: str) -> str:
    """Canonical composition, single spaces, no surrounding whitespace."""
    return _WHITESPACE.sub(" ", unicodedata.normalize("NFC", raw)).strip()


def display_name_problem(name: str) -> str | None:
    """What is wrong with a cleaned display name, if anything."""
    if _has_hidden_characters(name):
        return "Remove hidden or special characters."
    if not DISPLAY_NAME_MIN <= len(name) <= DISPLAY_NAME_MAX:
        return "Use 2–30 characters."
    if _URL.search(name):
        return "Names can't include links."
    if _MENTION.search(name):
        return "Names can't include @mentions."
    if _PHONE.search(name):
        return "Names can't include phone numbers."
    if contains_profanity(name) or impersonates_staff(name):
        return "That name isn't allowed. Please choose another."
    return None


def _has_hidden_characters(text: str) -> bool:
    """Control, private-use or invisible format characters (zero-width spaces, bidi overrides).

    Joiners are allowed where they do real work: after a Devanagari virama (conjunct forms) and
    between the parts of an emoji sequence.
    """
    for index, ch in enumerate(text):
        category = unicodedata.category(ch)
        if category in {"Cc", "Co", "Cs", "Cn"}:
            return True
        if category == "Cf" and not _is_meaningful_joiner(text, index):
            return True
    return False


def _is_meaningful_joiner(text: str, index: int) -> bool:
    if text[index] not in _ZERO_WIDTH_JOINERS or not 0 < index < len(text) - 1:
        return False
    before, after = text[index - 1], text[index + 1]
    if before == _DEVANAGARI_VIRAMA:
        return True
    return text[index] == "\u200d" and _is_emoji_part(before) and _is_emoji_part(after)


def _is_emoji_part(ch: str) -> bool:
    return ch == _VARIATION_SELECTOR or unicodedata.category(ch) in {"So", "Sk"}


def suggest_display_name(name: str | None, email: str | None) -> str:
    """An acceptable starting name for a new account: the Google name, else the email's local
    part ("rahul.sharma" -> "Rahul Sharma"); the player edits it during onboarding anyway."""
    candidates = []
    if name:
        candidates.append(name)
    if email:
        local = email.partition("@")[0].partition("+")[0]
        candidates.append(re.sub(r"[._-]+", " ", local).title())
    for candidate in candidates:
        cleaned = clean_display_name(candidate)[:DISPLAY_NAME_MAX].rstrip()
        if display_name_problem(cleaned) is None:
            return cleaned
    return FALLBACK_DISPLAY_NAME


def normalize_handle(raw: str) -> str:
    return raw.strip().lower()


def handle_problem(handle: str) -> HandleProblem | None:
    """Format and policy problems of a normalized handle (availability is checked separately)."""
    if not HANDLE_PATTERN.fullmatch(handle):
        return HandleProblem.INVALID
    if is_reserved_handle(handle) or is_profane_handle(handle):
        return HandleProblem.RESERVED
    return None


def current_year(now: datetime) -> int:
    """The calendar year in India, where the app's days are counted."""
    return now.astimezone(IST).year


def birth_year_problem(birth_year: int, *, this_year: int) -> str | None:
    if this_year - MIN_AGE < birth_year <= this_year:
        return f"You need to be at least {MIN_AGE} to play."
    if not this_year - MAX_AGE <= birth_year <= this_year:
        return "Enter the year you were born."
    return None


def is_minor(birth_year: int, *, this_year: int) -> bool:
    return this_year - birth_year < ADULT_AGE


def minor_now(birth_year: int | None, *, stored: bool, now: datetime) -> bool:
    """Whether the player is a minor today: worked out from the birth year each time it is read
    (players grow up), or the stored flag when there is no birth year."""
    if birth_year is None:
        return stored
    return is_minor(birth_year, this_year=current_year(now))
