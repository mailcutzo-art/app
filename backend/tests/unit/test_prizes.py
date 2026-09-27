"""Tournament prizes: share tables, pool scaling, the rounding remainder and eligibility."""

import pytest
from hypothesis import given
from hypothesis import strategies as st

from app.modules.tournaments.prizes import distribute, effective_pool, prize_shares


def test_every_table_sums_to_100_percent() -> None:
    for entrants in range(4, 257):
        assert sum(prize_shares(entrants)) == 10_000, entrants


@pytest.mark.parametrize(
    ("entrants", "shares"),
    [
        (4, (7000, 3000)),
        (7, (7000, 3000)),
        (8, (5000, 3000, 2000)),
        (15, (5000, 3000, 2000)),
        (16, (4000, 2500, 1500, 1000, 1000)),
        (31, (4000, 2500, 1500, 1000, 1000)),
        (32, (3000, 2000, 1200, 800, 600, 480, 480, 480, 480, 480)),
        (127, (3000, 2000, 1200, 800, 600, 480, 480, 480, 480, 480)),
        (128, (2500, 1500, 1000, 700, 500, 300, 300, 300, 300, 300, *[115] * 20)),
        (256, (2500, 1500, 1000, 700, 500, 300, 300, 300, 300, 300, *[115] * 20)),
    ],
)
def test_tier_boundaries(entrants: int, shares: tuple[int, ...]) -> None:
    assert prize_shares(entrants) == shares


@pytest.mark.parametrize(
    ("pool", "entrants", "effective"),
    [(1000, 4, 125), (1000, 16, 500), (1000, 31, 968), (1000, 32, 1000), (1000, 256, 1000)],
)
def test_pools_scale_down_below_32_entrants(pool: int, entrants: int, effective: int) -> None:
    assert effective_pool(pool, entrants) == effective


def test_small_tournament_pays_its_scaled_pool() -> None:
    # 16 entrants pay half of 1000: 40/25/15/10/10 of 500.
    ranked = [f"p{i}" for i in range(1, 17)]

    assert distribute(1000, 16, ranked) == {"p1": 200, "p2": 125, "p3": 75, "p4": 50, "p5": 50}


def test_rounding_remainder_goes_to_first_place() -> None:
    ranked = [f"p{i}" for i in range(1, 41)]

    prizes = distribute(999, 40, ranked)

    # Floors of 999 * share: 299, 199, 119, 79, 59 and 47 five times (990); 9 left over.
    assert prizes == {
        "p1": 308,
        "p2": 199,
        "p3": 119,
        "p4": 79,
        "p5": 59,
        **{f"p{i}": 47 for i in range(6, 11)},
    }
    assert sum(prizes.values()) == 999


def test_places_shift_up_past_ineligible_players() -> None:
    # 8 entrants pay a quarter of 400. The caller has already dropped banned and withdrawn
    # players from the ranking.
    assert distribute(400, 8, ["a", "c", "f"]) == {"a": 50, "c": 30, "f": 20}


def test_unfilled_places_are_not_paid() -> None:
    assert distribute(400, 8, ["a", "b"]) == {"a": 50, "b": 30}
    assert distribute(400, 8, []) == {}


def test_places_worth_nothing_are_left_out() -> None:
    assert distribute(0, 64, ["a", "b"]) == {}
    # 3 coins over 16 entrants: 1 effective coin, all of it to 1st.
    assert distribute(3, 16, ["a", "b", "c"]) == {"a": 1}


@pytest.mark.parametrize(
    ("pool", "entrants", "ranked", "match"),
    [
        (100, 3, [], "entrants"),
        (100, 257, [], "entrants"),
        (-1, 8, [], "pool"),
        (100, 8, ["a", "a"], "one place"),
        (100, 4, ["a", "b", "c", "d", "e"], "more eligible"),
    ],
)
def test_rejects_invalid_input(pool: int, entrants: int, ranked: list[str], match: str) -> None:
    with pytest.raises(ValueError, match=match):
        distribute(pool, entrants, ranked)


@given(
    pool=st.integers(0, 10**9),
    entrants=st.integers(4, 256),
    eligible_share=st.floats(0, 1),
)
def test_never_pays_more_than_the_effective_pool(
    pool: int, entrants: int, eligible_share: float
) -> None:
    ranked = [f"p{i}" for i in range(int(entrants * eligible_share))]
    effective = effective_pool(pool, entrants)

    prizes = distribute(pool, entrants, ranked)

    assert sum(prizes.values()) <= effective
    if len(ranked) >= len(prize_shares(entrants)):
        assert sum(prizes.values()) == effective
    amounts = list(prizes.values())
    assert amounts == sorted(amounts, reverse=True)
    assert list(prizes) == ranked[: len(prizes)]
