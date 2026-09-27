"""Tournament prize split.

Tournaments under 32 entrants pay only part of the pool, so filling a big pool with alt accounts
doesn't pay. Shares are basis points per place, chosen by entrant count; amounts are floored and
the rounding remainder goes to 1st place.
"""

from collections.abc import Sequence

MIN_ENTRANTS = 4
MAX_ENTRANTS = 256
FULL_POOL_ENTRANTS = 32
BASIS_POINTS = 10_000

# (minimum entrants, basis points per place), largest tier first.
_SHARES: tuple[tuple[int, tuple[int, ...]], ...] = (
    (128, (2500, 1500, 1000, 700, 500, *(300,) * 5, *(115,) * 20)),
    (32, (3000, 2000, 1200, 800, 600, *(480,) * 5)),
    (16, (4000, 2500, 1500, 1000, 1000)),
    (8, (5000, 3000, 2000)),
    (4, (7000, 3000)),
)


def prize_shares(entrants: int) -> tuple[int, ...]:
    """Basis points for each paid place: 4-7 entrants 70/30, 8-15 50/30/20, 16-31
    40/25/15/10/10, 32-127 30/20/12/8/6 then 4.8 for 6th-10th, 128-256 25/15/10/7/5 then 3 for
    6th-10th and 1.15 for 11th-30th.
    """
    _check_entrants(entrants)
    return next(shares for minimum, shares in _SHARES if entrants >= minimum)


def effective_pool(pool: int, entrants: int) -> int:
    """The part of the pool that is paid out: floor(pool * min(1, entrants / 32))."""
    _check_entrants(entrants)
    if pool < 0:
        raise ValueError("pool must not be negative")
    return pool * min(entrants, FULL_POOL_ENTRANTS) // FULL_POOL_ENTRANTS


def distribute(pool: int, entrants: int, ranked_eligible: Sequence[str]) -> dict[str, int]:
    """Prize per player: place k gets floor(effective * share_k / 10000), 1st also the remainder.

    ``ranked_eligible`` is the final order without banned or withdrawn players, so places shift
    up past them. Places nobody fills are not paid, and places worth nothing are left out.
    """
    effective = effective_pool(pool, entrants)
    if len(set(ranked_eligible)) != len(ranked_eligible):
        raise ValueError("a player can hold only one place")
    if len(ranked_eligible) > entrants:
        raise ValueError("more eligible players than entrants")
    amounts = [effective * share // BASIS_POINTS for share in prize_shares(entrants)]
    amounts[0] += effective - sum(amounts)
    return {
        player: amount
        for player, amount in zip(ranked_eligible, amounts, strict=False)
        if amount > 0
    }


def _check_entrants(entrants: int) -> None:
    if not MIN_ENTRANTS <= entrants <= MAX_ENTRANTS:
        raise ValueError(f"entrants must be within {MIN_ENTRANTS}..{MAX_ENTRANTS}")
