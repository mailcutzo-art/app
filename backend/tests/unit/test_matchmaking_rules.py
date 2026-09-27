"""Matchmaking rules: rating windows, compatibility, question sources and difficulty mix."""

import math
from dataclasses import replace
from typing import Any

import pytest
from hypothesis import given
from hypothesis import strategies as st

from app.modules.realtime.matchmaking.rules import (
    DIFFICULTY_BANDS,
    Ticket,
    compatible,
    difficulty_band,
    difficulty_mix,
    question_sources,
    rating_window,
)


@pytest.mark.parametrize(
    ("waited_s", "window"),
    [
        (0, 75),
        (4.999, 75),
        (5, 150),
        (9.999, 150),
        (10, 250),
        (19.999, 250),
        (20, 400),
        (29.999, 400),
        (30, None),
        (600, None),
    ],
)
def test_rated_window_widens_with_waiting(waited_s: float, window: float | None) -> None:
    assert rating_window(waited_s, rated=True, rd=50) == window


@pytest.mark.parametrize(
    ("waited_s", "window"),
    [(0, 150), (4.999, 150), (5, 300), (9.999, 300), (10, None), (45, None)],
)
def test_casual_window_widens_faster(waited_s: float, window: float | None) -> None:
    assert rating_window(waited_s, rated=False, rd=50) == window


def test_window_is_never_narrower_than_rd() -> None:
    assert rating_window(0, rated=True, rd=350) == 350
    assert rating_window(12, rated=True, rd=200) == 250
    assert rating_window(12, rated=True, rd=300) == 300
    assert rating_window(30, rated=True, rd=350) is None


@pytest.mark.parametrize("waited_s", [-0.001, math.nan, math.inf])
def test_window_rejects_bad_waits(waited_s: float) -> None:
    with pytest.raises(ValueError, match="waited_s"):
        rating_window(waited_s, rated=True, rd=50)


def ticket(user: str, **changes: Any) -> Ticket:
    base = Ticket(
        user_id=user,
        rating=1500,
        rd=50,
        subject="physics",
        chapter="kinematics",
        joined_ms=0,
        device_hash=f"device-{user}",
    )
    return replace(base, **changes)


def test_same_chapter_players_with_close_ratings_match() -> None:
    assert compatible(ticket("a"), ticket("b"), 0, rated=True)


@pytest.mark.parametrize(
    "other",
    [
        ticket("b", subject="chemistry"),
        ticket("a", device_hash="device-x"),  # the same user
        ticket("b", device_hash="device-a"),  # the same device
    ],
)
def test_subject_user_and_device_must_differ_as_required(other: Ticket) -> None:
    assert not compatible(ticket("a"), other, 60_000, rated=True)


def test_all_chapters_matches_any_chapter() -> None:
    assert compatible(ticket("a", chapter=None), ticket("b", chapter="optics"), 0, rated=True)
    assert compatible(ticket("a", chapter="optics"), ticket("b", chapter=None), 0, rated=True)
    assert compatible(ticket("a", chapter=None), ticket("b", chapter=None), 0, rated=True)


def test_different_chapters_match_once_both_have_waited_15_seconds() -> None:
    a = ticket("a", chapter="kinematics", joined_ms=0, rd=400)
    b = ticket("b", chapter="optics", joined_ms=1, rd=400)

    assert not compatible(a, b, 15_000, rated=True)  # b has waited 14.999 s
    assert compatible(a, b, 15_001, rated=True)


def test_rating_gap_must_fit_both_windows() -> None:
    settled = ticket("a", rating=1500, rd=50, joined_ms=0)
    provisional = ticket("b", rating=1600, rd=350, joined_ms=0)

    # The provisional player accepts anyone within 350, but the settled one only 75 at first.
    assert not compatible(settled, provisional, 4_999, rated=True)
    assert compatible(settled, provisional, 5_000, rated=True)
    # Casual windows start at 150.
    assert compatible(settled, provisional, 0, rated=False)


def test_edges_of_the_window_are_inclusive_and_any_rating_matches_late() -> None:
    a, b = ticket("a", rating=1500), ticket("b", rating=1575)
    far = ticket("b", rating=2600, joined_ms=0)

    assert compatible(a, b, 0, rated=True)
    assert not compatible(a, replace(b, rating=1575.5), 0, rated=True)
    assert not compatible(a, far, 29_999, rated=True)
    assert compatible(a, far, 30_000, rated=True)


def test_a_ticket_from_the_future_counts_as_just_joined() -> None:
    a, b = ticket("a", joined_ms=10_000), ticket("b", joined_ms=0, rating=1600)

    assert not compatible(a, b, 9_000, rated=True)


@pytest.mark.parametrize(
    ("a", "b", "sources"),
    [
        (ticket("a"), ticket("b"), [("kinematics", 7)]),
        (ticket("a", chapter=None), ticket("b"), [("kinematics", 7)]),
        (ticket("a"), ticket("b", chapter=None), [("kinematics", 7)]),
        (ticket("a", chapter=None), ticket("b", chapter=None), [(None, 7)]),
        (
            ticket("a", chapter="optics", joined_ms=500),
            ticket("b", joined_ms=900),
            [("optics", 4), ("kinematics", 3)],
        ),
        (
            ticket("a", chapter="optics", joined_ms=900),
            ticket("b", joined_ms=500),
            [("kinematics", 4), ("optics", 3)],
        ),
        (
            ticket("b", chapter="optics", joined_ms=500),
            ticket("a", joined_ms=500),  # joined together: lower user id first
            [("kinematics", 4), ("optics", 3)],
        ),
    ],
)
def test_question_sources(a: Ticket, b: Ticket, sources: list[tuple[str | None, int]]) -> None:
    assert question_sources(a, b) == sources


def test_question_sources_split_other_totals() -> None:
    a, b = ticket("a", chapter="optics"), ticket("b", joined_ms=1)

    assert question_sources(a, b, total=10) == [("optics", 5), ("kinematics", 5)]
    assert question_sources(a, b, total=1) == [("optics", 1)]
    with pytest.raises(ValueError, match="total"):
        question_sources(a, b, total=0)


@pytest.mark.parametrize(
    ("avg_rating", "total", "mix"),
    [
        (1299.9, 7, {"easy": 3, "medium": 3, "hard": 1}),  # 3.5 / 2.8 / 0.7
        (1300, 7, {"easy": 2, "medium": 3, "hard": 2}),  # 1.75 / 3.5 / 1.75
        (1700, 7, {"easy": 2, "medium": 3, "hard": 2}),
        (1700.1, 7, {"easy": 1, "medium": 3, "hard": 3}),  # 0.7 / 2.8 / 3.5
        (1000, 10, {"easy": 5, "medium": 4, "hard": 1}),
        (1500, 10, {"easy": 3, "medium": 5, "hard": 2}),  # 2.5 / 5 / 2.5: tie to easy
        (2000, 10, {"easy": 1, "medium": 4, "hard": 5}),
        (1500, 0, {"easy": 0, "medium": 0, "hard": 0}),
    ],
)
def test_difficulty_mix(avg_rating: float, total: int, mix: dict[str, int]) -> None:
    assert difficulty_mix(avg_rating, total) == mix


@given(avg_rating=st.floats(0, 3500), total=st.integers(0, 100))
def test_difficulty_mix_always_sums_to_the_total(avg_rating: float, total: int) -> None:
    mix = difficulty_mix(avg_rating, total)

    assert sum(mix.values()) == total
    assert list(mix) == ["easy", "medium", "hard"]


def test_difficulty_mix_rejects_bad_input() -> None:
    with pytest.raises(ValueError, match="total"):
        difficulty_mix(1500, -1)
    with pytest.raises(ValueError, match="finite"):
        difficulty_mix(math.nan, 7)


def test_difficulty_bands() -> None:
    assert DIFFICULTY_BANDS == {"easy": (1, 2), "medium": (3,), "hard": (4, 5)}
    assert [difficulty_band(d) for d in range(1, 6)] == ["easy", "easy", "medium", "hard", "hard"]
    for invalid in (0, 6):
        with pytest.raises(ValueError, match="difficulty"):
            difficulty_band(invalid)
