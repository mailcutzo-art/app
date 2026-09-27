"""Glicko-2: Glickman's worked example, per-game updates, display rules and properties."""

import math

import pytest
from hypothesis import given
from hypothesis import strategies as st

from app.modules.ratings import glicko2
from app.modules.ratings.glicko2 import (
    RD_MAX,
    RD_MIN,
    SCALE,
    Rating,
    age,
    display_rating,
    is_ranked,
    rate,
    rate_game,
)

REFERENCE_GAMES = [(Rating(1400, 30), 1.0), (Rating(1550, 100), 0.0), (Rating(1700, 300), 0.0)]


def test_glickman_reference_example() -> None:
    updated = rate(Rating(1500, 200, 0.06), REFERENCE_GAMES, tau=0.5)

    assert updated.rating == pytest.approx(1464.06, abs=0.01)
    assert updated.rd == pytest.approx(151.52, abs=0.01)
    assert updated.volatility == pytest.approx(0.05999, abs=1e-5)


def test_volatility_is_kept_when_the_iteration_does_not_converge(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(glicko2, "MAX_ITERATIONS", 0)

    updated = rate(Rating(1500, 200, 0.06), REFERENCE_GAMES)

    assert updated.volatility == 0.06
    assert updated.rating < 1500


def test_no_games_only_grows_rd_by_one_period() -> None:
    updated = rate(Rating(1623.5, 200, 0.06), [])

    assert updated.rating == 1623.5
    assert updated.volatility == 0.06
    assert updated.rd == pytest.approx(math.sqrt(200**2 + (0.06 * SCALE) ** 2))


def test_rd_is_clamped_to_its_bounds() -> None:
    assert rate(Rating(1500, 349.9, 0.5), []).rd == RD_MAX
    settled = Rating(1500, 50, 0.01)
    assert rate(settled, [(Rating(1500, 45, 0.01), 0.5)] * 50).rd == RD_MIN


def test_age_inflates_rd_for_idle_periods_up_to_the_cap() -> None:
    player = Rating(1500, 100, 0.06)

    assert age(player, 0) == player
    assert age(player, 2.5).rd == pytest.approx(math.sqrt(100**2 + 2.5 * (0.06 * SCALE) ** 2))
    assert age(player, 10_000).rd == RD_MAX
    assert age(player, 2.5).rating == 1500
    assert age(player, 2.5).volatility == 0.06


def test_rate_game_ages_both_players_then_rates_against_pre_game_ratings() -> None:
    a, b = Rating(1600, 80, 0.06), Rating(1450, 150, 0.07)

    new_a, new_b = rate_game(a, b, 1.0, idle_periods_a=2, idle_periods_b=0.4)

    aged_a, aged_b = age(a, 2), age(b, 0.4)
    assert new_a == rate(aged_a, [(aged_b, 1.0)])
    assert new_b == rate(aged_b, [(aged_a, 0.0)])
    assert new_a.rating > a.rating
    assert new_b.rating < b.rating


@pytest.mark.parametrize(
    ("call", "match"),
    [
        (lambda: rate(Rating(), [(Rating(), 1.5)]), "score"),
        (lambda: rate(Rating(), [(Rating(), -0.1)]), "score"),
        (lambda: rate(Rating(), [(Rating(), math.nan)]), "score"),
        (lambda: rate(Rating(math.inf), []), "finite"),
        (lambda: rate(Rating(), [(Rating(rd=math.nan), 1.0)]), "finite"),
        (lambda: rate(Rating(volatility=0.0), []), "positive"),
        (lambda: rate(Rating(rd=-1.0), []), "positive"),
        (lambda: rate(Rating(), [], tau=0.0), "tau"),
        (lambda: rate(Rating(), [], tau=math.inf), "tau"),
        (lambda: age(Rating(), -1.0), "periods"),
        (lambda: age(Rating(), math.nan), "periods"),
        (lambda: rate_game(Rating(), Rating(), 2.0), "score"),
        (lambda: rate(Rating(0), [(Rating(10**7, 45), 1.0)]), "too far apart"),
    ],
)
def test_rejects_invalid_input(call: object, match: str) -> None:
    assert callable(call)
    with pytest.raises(ValueError, match=match):
        call()


@pytest.mark.parametrize(
    ("rating", "games", "shown"),
    [
        (Rating(1523.4, 60), 0, "—"),
        (Rating(1500, 350), 1, "1500?"),
        (Rating(1522.5, 110.01), 3, "1523?"),
        (Rating(1522.5, 110), 3, "1523"),
        (Rating(1523.49, 60), 30, "1523"),
        (Rating(1523.5, 60), 30, "1524"),
    ],
)
def test_display_rating(rating: Rating, games: int, shown: str) -> None:
    assert display_rating(rating, games) == shown


@pytest.mark.parametrize(
    ("rd", "games", "ranked"),
    [(110, 10, True), (45, 500, True), (110.01, 10, False), (110, 9, False), (350, 0, False)],
)
def test_is_ranked_needs_a_settled_rd_and_ten_games(rd: float, games: int, ranked: bool) -> None:
    assert is_ranked(Rating(1500, rd), games) is ranked


ratings = st.builds(
    Rating,
    rating=st.floats(100, 3500),
    rd=st.floats(RD_MIN, RD_MAX),
    volatility=st.floats(0.01, 0.2),
)
game_scores = st.sampled_from([0.0, 0.5, 1.0])
idle_periods = st.floats(0, 200)


@given(ratings)
def test_beating_an_equal_opponent_raises_the_rating_and_losing_lowers_it(r: Rating) -> None:
    assert rate(r, [(r, 1.0)]).rating > r.rating
    assert rate(r, [(r, 0.0)]).rating < r.rating
    winner, loser = rate_game(r, r, 1.0)
    assert winner.rating > r.rating > loser.rating


@given(ratings, idle_periods)
def test_identical_players_who_draw_keep_equal_ratings(r: Rating, periods: float) -> None:
    a, b = rate_game(r, r, 0.5, idle_periods_a=periods, idle_periods_b=periods)

    assert a == b
    assert a.rating == r.rating


@given(ratings, ratings, game_scores, idle_periods, idle_periods)
def test_rate_game_is_mirror_symmetric(
    a: Rating, b: Rating, score: float, idle_a: float, idle_b: float
) -> None:
    forward = rate_game(a, b, score, idle_periods_a=idle_a, idle_periods_b=idle_b)
    backward = rate_game(b, a, 1 - score, idle_periods_a=idle_b, idle_periods_b=idle_a)

    assert forward == (backward[1], backward[0])


@given(ratings, st.lists(st.tuples(ratings, st.floats(0, 1)), max_size=12))
def test_rd_stays_in_bounds_and_volatility_positive_and_finite(
    r: Rating, games: list[tuple[Rating, float]]
) -> None:
    updated = rate(r, games)

    assert RD_MIN <= updated.rd <= RD_MAX
    assert math.isfinite(updated.volatility)
    assert updated.volatility > 0
    assert math.isfinite(updated.rating)


@given(ratings, ratings, game_scores, idle_periods, idle_periods)
def test_rate_game_keeps_both_players_in_bounds(
    a: Rating, b: Rating, score: float, idle_a: float, idle_b: float
) -> None:
    for updated in rate_game(a, b, score, idle_periods_a=idle_a, idle_periods_b=idle_b):
        assert RD_MIN <= updated.rd <= RD_MAX
        assert 0 < updated.volatility < math.inf


@given(ratings, st.floats(0, 1e9))
def test_age_never_lowers_rd(r: Rating, periods: float) -> None:
    assert r.rd <= age(r, periods).rd <= RD_MAX
