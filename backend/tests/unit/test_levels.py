"""Levels and XP: the level curve, progress, game and practice XP, and daily caps."""

import pytest

from app.modules.progression.levels import (
    MAX_LEVEL,
    GameKind,
    GameOutcome,
    cap_daily,
    game_xp,
    level_for_xp,
    practice_xp,
    progress,
    xp_for_level,
)


@pytest.mark.parametrize(("level", "xp"), [(1, 0), (2, 100), (3, 250), (10, 2700), (100, 252_450)])
def test_level_curve(level: int, xp: int) -> None:
    assert xp_for_level(level) == xp


@pytest.mark.parametrize(
    ("xp", "level"),
    [(0, 1), (99, 1), (100, 2), (249, 2), (250, 3), (2699, 9), (2700, 10), (252_449, 99)],
)
def test_level_for_xp(xp: int, level: int) -> None:
    assert level_for_xp(xp) == level


def test_level_for_xp_matches_the_curve_everywhere() -> None:
    for level in range(1, MAX_LEVEL):
        assert level_for_xp(xp_for_level(level)) == level
        assert level_for_xp(xp_for_level(level + 1) - 1) == level


def test_levels_are_capped_at_100() -> None:
    assert level_for_xp(252_450) == MAX_LEVEL
    assert level_for_xp(10**9) == MAX_LEVEL


@pytest.mark.parametrize(
    ("xp", "expected"),
    [
        (0, (1, 0, 100)),
        (40, (1, 40, 100)),
        (100, (2, 0, 150)),
        (2750, (10, 50, 550)),  # level 10 spans 2,700 to 3,250
        (252_450, (100, 0, 0)),
        (260_000, (100, 7550, 0)),
    ],
)
def test_progress(xp: int, expected: tuple[int, int, int]) -> None:
    assert progress(xp) == expected


def test_curve_rejects_out_of_range_input() -> None:
    for level in (0, MAX_LEVEL + 1):
        with pytest.raises(ValueError, match="level"):
            xp_for_level(level)
    with pytest.raises(ValueError, match="xp"):
        level_for_xp(-1)


@pytest.mark.parametrize(
    ("kind", "xp"),
    [
        (GameKind.QUICK_RATED, (30, 20, 10)),
        (GameKind.TOURNAMENT, (30, 20, 10)),
        (GameKind.QUICK_CASUAL, (20, 15, 8)),
        (GameKind.FRIEND, (10, 7, 4)),
        (GameKind.BOT, (10, 7, 4)),
        (GameKind.GROUP, (20, 10, 10)),  # 20 for 1st place, 10 for taking part
    ],
)
def test_game_xp(kind: GameKind, xp: tuple[int, int, int]) -> None:
    outcomes = (GameOutcome.WIN, GameOutcome.DRAW, GameOutcome.LOSS)

    assert tuple(game_xp(kind, outcome) for outcome in outcomes) == xp


def test_friend_and_bot_games_earn_half_of_casual_rounded_down() -> None:
    for outcome in GameOutcome:
        half = game_xp(GameKind.QUICK_CASUAL, outcome) // 2
        assert game_xp(GameKind.FRIEND, outcome) == half
        assert game_xp(GameKind.BOT, outcome) == half


def test_practice_xp() -> None:
    assert practice_xp(True) == 2
    assert practice_xp(False) == 1


@pytest.mark.parametrize(
    ("already", "award", "cap", "granted"),
    [(0, 30, 300, 30), (290, 30, 300, 10), (300, 30, 300, 0), (350, 30, 300, 0), (0, 0, 300, 0)],
)
def test_cap_daily(already: int, award: int, cap: int, granted: int) -> None:
    assert cap_daily(already, award, cap) == granted


def test_cap_daily_rejects_negative_amounts() -> None:
    with pytest.raises(ValueError, match="negative"):
        cap_daily(0, -1, 300)
