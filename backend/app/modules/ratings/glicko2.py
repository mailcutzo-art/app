"""Glicko-2 ratings (Glickman, "Example of the Glicko-2 system", steps 1-8).

The app rates after every game: each player is first aged for the idle time since their last
rated game (fractional 5-day periods), then rated against the other's pre-game rating as a
one-game rating period.
"""

import math
from collections.abc import Sequence
from dataclasses import dataclass, replace
from fractions import Fraction

SCALE = 173.7178
TAU = 0.5
RD_MIN = 45.0
RD_MAX = 350.0
PROVISIONAL_RD = 110.0
EPSILON = 1e-6
MAX_ITERATIONS = 100
PERIOD_DAYS = 5
RANKED_MIN_GAMES = 10
_CENTER = 1500.0


@dataclass(frozen=True, slots=True)
class Rating:
    """A rating on the familiar scale, its deviation (RD) and volatility; defaults for newcomers."""

    rating: float = 1500.0
    rd: float = 350.0
    volatility: float = 0.06


def rate(player: Rating, games: Sequence[tuple[Rating, float]], tau: float = TAU) -> Rating:
    """One rating period for ``player``; ``games`` pairs each opponent with the score (1/0.5/0).

    Volatility uses the Illinois method and keeps the old value if it doesn't converge within
    100 iterations. With no games only RD grows, as for one idle period. The new RD is clamped
    to [RD_MIN, RD_MAX]. Scores outside [0, 1] and non-finite values raise ValueError.
    """
    _check_rating(player)
    if not (math.isfinite(tau) and tau > 0):
        raise ValueError("tau must be a positive number")
    for opponent, score in games:
        _check_rating(opponent)
        if not (math.isfinite(score) and 0 <= score <= 1):
            raise ValueError(f"score must be within [0, 1], got {score}")
    if not games:
        return replace(player, rd=_clamp_rd(age(player, 1).rd))

    mu = (player.rating - _CENTER) / SCALE
    phi = player.rd / SCALE
    information = 0.0  # 1/v
    surprise = 0.0  # sum of g(phi_j) * (s_j - E_j)
    for opponent, score in games:
        g = _g(opponent.rd / SCALE)
        expected = _logistic(g * (mu - (opponent.rating - _CENTER) / SCALE))
        information += g * g * expected * (1 - expected)
        surprise += g * (score - expected)
    if not (information > 0 and math.isfinite(1 / information)):
        raise ValueError("ratings are too far apart to compare")
    variance = 1 / information
    volatility = _new_volatility(phi, player.volatility, variance, variance * surprise, tau)
    phi_star_sq = phi * phi + volatility * volatility
    new_phi = 1 / math.sqrt(1 / phi_star_sq + information)
    # r' = 1500 + SCALE * mu' written as a delta, so a zero update keeps the rating exactly.
    new_rating = player.rating + SCALE * new_phi * new_phi * surprise
    return Rating(new_rating, _clamp_rd(SCALE * new_phi), volatility)


def age(player: Rating, periods: float) -> Rating:
    """Inflate RD for ``periods`` idle rating periods: φ* = sqrt(φ² + periods·σ²), capped."""
    _check_rating(player)
    if not (math.isfinite(periods) and periods >= 0):
        raise ValueError("periods must be a non-negative number")
    # Computed on the rating scale so that zero periods return the RD unchanged.
    grown = math.sqrt(player.rd * player.rd + periods * (player.volatility * SCALE) ** 2)
    return replace(player, rd=min(RD_MAX, grown))


def rate_game(
    a: Rating,
    b: Rating,
    score_a: float,
    *,
    idle_periods_a: float = 0.0,
    idle_periods_b: float = 0.0,
) -> tuple[Rating, Rating]:
    """Rate one game: age both players, then rate each against the other's aged pre-game rating.

    Idle periods are the days since the player's last rated game divided by ``PERIOD_DAYS``.
    """
    aged_a = age(a, idle_periods_a)
    aged_b = age(b, idle_periods_b)
    return rate(aged_a, [(aged_b, score_a)]), rate(aged_b, [(aged_a, 1 - score_a)])


def display_rating(r: Rating, games_played: int) -> str:
    """Show "—" before any games, "1523?" while RD > PROVISIONAL_RD, else "1523" (half up)."""
    if games_played <= 0:
        return "—"
    shown = math.floor(Fraction(r.rating) + Fraction(1, 2))
    return f"{shown}?" if r.rd > PROVISIONAL_RD else str(shown)


def is_ranked(r: Rating, games_played: int) -> bool:
    """Leaderboards list a player once RD ≤ PROVISIONAL_RD after at least 10 games."""
    return r.rd <= PROVISIONAL_RD and games_played >= RANKED_MIN_GAMES


def _check_rating(r: Rating) -> None:
    if not all(math.isfinite(value) for value in (r.rating, r.rd, r.volatility)):
        raise ValueError(f"rating values must be finite: {r}")
    if r.rd <= 0 or r.volatility <= 0:
        raise ValueError(f"RD and volatility must be positive: {r}")


def _g(phi: float) -> float:
    return 1 / math.sqrt(1 + 3 * phi * phi / (math.pi * math.pi))


def _logistic(z: float) -> float:
    """1 / (1 + e^-z) without overflowing for large |z|."""
    if z >= 0:
        return 1 / (1 + math.exp(-z))
    ez = math.exp(z)
    return ez / (1 + ez)


def _clamp_rd(rd: float) -> float:
    return min(RD_MAX, max(RD_MIN, rd))


def _new_volatility(phi: float, sigma: float, variance: float, delta: float, tau: float) -> float:
    """Step 5: solve f(x) = 0 for x = ln(sigma'^2) by the Illinois method, else keep sigma."""
    a = math.log(sigma * sigma)
    excess = delta * delta - phi * phi - variance

    def f(x: float) -> float:
        ex = math.exp(x)
        denominator = phi * phi + variance + ex
        return ex * (excess - ex) / (2 * denominator * denominator) - (x - a) / (tau * tau)

    x_a = a
    if excess > 0:
        x_b = math.log(excess)
    else:
        k = 1
        while f(a - k * tau) < 0:
            k += 1
            if k > MAX_ITERATIONS:
                return sigma
        x_b = a - k * tau
    f_a, f_b = f(x_a), f(x_b)
    iterations = 0
    while abs(x_b - x_a) > EPSILON:
        if iterations == MAX_ITERATIONS:
            return sigma
        iterations += 1
        x_c = x_a + (x_a - x_b) * f_a / (f_b - f_a)
        f_c = f(x_c)
        if f_c * f_b <= 0:
            x_a, f_a = x_b, f_b
        else:
            f_a /= 2
        x_b, f_b = x_c, f_c
    return math.exp(x_a / 2)
