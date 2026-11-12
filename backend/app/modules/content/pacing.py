"""Time limits that follow a question's difficulty.

An easy question should be answered quickly; a hard one needs room to work it out. Difficulty
is 1-5 (``docs/content-format.md``): 1-2 easy, 3 medium, 4-5 hard.

* **Battles** scale the base limit (``match_limit_ms``, the easy limit) by
  ``match_medium_scale`` and ``match_hard_scale``: 20 s, 30 s and 45 s by default.
* **Timed practice** "by difficulty" gives 30 s, 60 s and 90 s. A fixed time per question
  (``per_question_s``) is still available.
"""

from typing import Literal

from app.core.config import Settings

Band = Literal["easy", "medium", "hard"]

PRACTICE_LIMIT_S: dict[Band, int] = {"easy": 30, "medium": 60, "hard": 90}


def band(difficulty: int) -> Band:
    """Easy is difficulty 1-2, medium 3, hard 4-5 (out-of-range values clamp)."""
    if difficulty <= 2:
        return "easy"
    if difficulty == 3:
        return "medium"
    return "hard"


def practice_limit_ms(difficulty: int) -> int:
    return PRACTICE_LIMIT_S[band(difficulty)] * 1000


def battle_scale(settings: Settings, difficulty: int) -> float:
    return {
        "easy": 1.0,
        "medium": settings.match_medium_scale,
        "hard": settings.match_hard_scale,
    }[band(difficulty)]


def battle_limit_ms(settings: Settings, difficulty: int, base_ms: int | None = None) -> int:
    """The limit for one battle question: ``base_ms`` (default ``match_limit_ms``) scaled."""
    base = settings.match_limit_ms if base_ms is None else base_ms
    return round(base * battle_scale(settings, difficulty))


def battle_limits_s(settings: Settings) -> dict[Band, int]:
    """Seconds per question for each band, for rules screens."""
    levels: dict[Band, int] = {"easy": 1, "medium": 3, "hard": 5}
    return {name: round(battle_limit_ms(settings, level) / 1000) for name, level in levels.items()}
