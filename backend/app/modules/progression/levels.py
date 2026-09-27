"""Levels and XP awards.

Reaching level L takes 25·(L-1)·(L+2) XP in total: level 2 at 100, level 10 at 2,700, capped at
level 100.
"""

import math
from collections.abc import Mapping
from enum import StrEnum

MAX_LEVEL = 100


class GameKind(StrEnum):
    QUICK_RATED = "quick_rated"
    QUICK_CASUAL = "quick_casual"
    TOURNAMENT = "tournament"
    FRIEND = "friend"
    BOT = "bot"
    GROUP = "group"


class GameOutcome(StrEnum):
    """For group games WIN means finishing 1st; anything else counts as taking part."""

    WIN = "win"
    DRAW = "draw"
    LOSS = "loss"


# XP for a win, draw and loss.
_RATED_XP = (30, 20, 10)
_CASUAL_XP = (20, 15, 8)
_HALF_CASUAL_XP = (10, 7, 4)  # casual halved, rounded down
_GAME_XP: Mapping[GameKind, tuple[int, int, int]] = {
    GameKind.QUICK_RATED: _RATED_XP,
    GameKind.TOURNAMENT: _RATED_XP,
    GameKind.QUICK_CASUAL: _CASUAL_XP,
    GameKind.FRIEND: _HALF_CASUAL_XP,
    GameKind.BOT: _HALF_CASUAL_XP,
    GameKind.GROUP: (20, 10, 10),
}
_OUTCOME_INDEX: Mapping[GameOutcome, int] = {
    GameOutcome.WIN: 0,
    GameOutcome.DRAW: 1,
    GameOutcome.LOSS: 2,
}


def xp_for_level(level: int) -> int:
    """Total XP needed to reach ``level``: 25·(L-1)·(L+2)."""
    if not 1 <= level <= MAX_LEVEL:
        raise ValueError(f"level must be within 1..{MAX_LEVEL}")
    return 25 * (level - 1) * (level + 2)


def level_for_xp(xp: int) -> int:
    """The highest level whose total XP is at most ``xp``, capped at MAX_LEVEL."""
    if xp < 0:
        raise ValueError("xp must not be negative")
    # (L-1)(L+2) <= m  <=>  (2L+1)^2 <= 4m + 9, with m = xp // 25.
    level = (math.isqrt(4 * (xp // 25) + 9) - 1) // 2
    return min(level, MAX_LEVEL)


def progress(xp: int) -> tuple[int, int, int]:
    """(level, XP earned inside the level, XP the whole level spans); the span is 0 at the cap."""
    level = level_for_xp(xp)
    start = xp_for_level(level)
    span = xp_for_level(level + 1) - start if level < MAX_LEVEL else 0
    return level, xp - start, span


def game_xp(kind: GameKind, outcome: GameOutcome) -> int:
    """Rated and tournament 30/20/10 for a win/draw/loss, casual 20/15/8, friend and bot half
    of casual (10/7/4), group 20 for 1st place and 10 otherwise.
    """
    return _GAME_XP[kind][_OUTCOME_INDEX[outcome]]


def practice_xp(correct: bool) -> int:
    """1 XP per practice answer, 1 more if it is correct."""
    return 2 if correct else 1


def cap_daily(already_today: int, award: int, cap: int) -> int:
    """How much of ``award`` may still be granted today under a daily ``cap``."""
    if already_today < 0 or award < 0 or cap < 0:
        raise ValueError("XP amounts must not be negative")
    return max(0, min(award, cap - already_today))
