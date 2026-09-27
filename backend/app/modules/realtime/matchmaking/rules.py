"""Quick Battle matchmaking rules: rating windows, compatibility and the question mix.

A ticket's rating window widens the longer it waits and is never narrower than the player's RD,
so provisional players match widely at once. After 15 s, two waiting players may be matched
across chapters of the same subject.
"""

import math
from collections.abc import Mapping
from dataclasses import dataclass
from typing import Literal

CHAPTER_WIDEN_MS = 15_000
# (waited less than this many seconds, base window); past the last step any rating matches.
_RATED_WINDOWS = ((5, 75.0), (10, 150.0), (20, 250.0), (30, 400.0))
_CASUAL_WINDOWS = ((5, 150.0), (10, 300.0))

DifficultyBand = Literal["easy", "medium", "hard"]
DIFFICULTY_BANDS: Mapping[DifficultyBand, tuple[int, ...]] = {
    "easy": (1, 2),
    "medium": (3,),
    "hard": (4, 5),
}
# Percent easy/medium/hard for pairs rated below 1300, 1300-1700 and above 1700.
_MIX_LOW = (50, 40, 10)
_MIX_MID = (25, 50, 25)
_MIX_HIGH = (10, 40, 50)


@dataclass(frozen=True, slots=True)
class Ticket:
    """A queued player; ``chapter`` None means "All chapters"."""

    user_id: str
    rating: float
    rd: float
    subject: str
    chapter: str | None
    joined_ms: int
    device_hash: str


def rating_window(waited_s: float, *, rated: bool, rd: float) -> float | None:
    """Allowed rating difference, max(base, rd); None means any rating.

    Rated bases: ±75 for 0-5 s, ±150 for 5-10 s, ±250 for 10-20 s, ±400 for 20-30 s, then any.
    Casual bases: ±150 for 0-5 s, ±300 for 5-10 s, then any.
    """
    if not (math.isfinite(waited_s) and waited_s >= 0):
        raise ValueError("waited_s must be a non-negative number")
    for until_s, base in _RATED_WINDOWS if rated else _CASUAL_WINDOWS:
        if waited_s < until_s:
            return max(base, rd)
    return None


def compatible(a: Ticket, b: Ticket, now_ms: int, *, rated: bool) -> bool:
    """Same subject, different users and devices, compatible chapters, and each rating within
    the other's window.

    Chapters match if they are equal, either side picked All, or both have waited 15 s.
    """
    if a.subject != b.subject or a.user_id == b.user_id or a.device_hash == b.device_hash:
        return False
    waited_a_ms = max(0, now_ms - a.joined_ms)
    waited_b_ms = max(0, now_ms - b.joined_ms)
    same_chapters = a.chapter is None or b.chapter is None or a.chapter == b.chapter
    if not same_chapters and min(waited_a_ms, waited_b_ms) < CHAPTER_WIDEN_MS:
        return False
    gap = abs(a.rating - b.rating)
    windows = (
        rating_window(waited_a_ms / 1000, rated=rated, rd=a.rd),
        rating_window(waited_b_ms / 1000, rated=rated, rd=b.rd),
    )
    return all(window is None or gap <= window for window in windows)


def question_sources(a: Ticket, b: Ticket, total: int = 7) -> list[tuple[str | None, int]]:
    """Where the questions come from, as (chapter or None for the whole subject, count).

    One chapter if both picked it or the other picked All; the whole subject if both picked
    All; otherwise ceil(total / 2) from the chapter of whoever joined first (then lower user id)
    and the rest from the other.
    """
    if total < 1:
        raise ValueError("total must be at least 1")
    if a.chapter is None or b.chapter is None or a.chapter == b.chapter:
        return [(a.chapter if a.chapter is not None else b.chapter, total)]
    first, second = sorted((a, b), key=lambda t: (t.joined_ms, t.user_id))
    sources = [(first.chapter, (total + 1) // 2), (second.chapter, total // 2)]
    return [(chapter, count) for chapter, count in sources if count > 0]


def difficulty_mix(avg_rating: float, total: int) -> dict[DifficultyBand, int]:
    """Question counts per band: 50/40/10 % below 1300, 25/50/25 up to 1700, 10/40/50 above.

    Largest-remainder rounding, so the counts sum to ``total``; ties favour the easier band.
    """
    if total < 0 or not math.isfinite(avg_rating):
        raise ValueError("need a finite rating and a non-negative total")
    if avg_rating < 1300:
        percents = _MIX_LOW
    elif avg_rating <= 1700:
        percents = _MIX_MID
    else:
        percents = _MIX_HIGH
    counts = [total * percent // 100 for percent in percents]
    by_remainder = sorted(range(3), key=lambda i: -(total * percents[i] % 100))
    for i in by_remainder[: total - sum(counts)]:
        counts[i] += 1
    return dict(zip(DIFFICULTY_BANDS, counts, strict=True))


def difficulty_band(difficulty: int) -> DifficultyBand:
    """Easy is difficulty 1-2, medium 3, hard 4-5."""
    for band, levels in DIFFICULTY_BANDS.items():
        if difficulty in levels:
            return band
    raise ValueError(f"difficulty must be within 1..5, got {difficulty}")
