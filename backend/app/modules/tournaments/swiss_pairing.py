"""Swiss-system pairing.

Round 1 folds the seed list, top half against bottom half. Later rounds take a maximum-weight
perfect matching (networkx) over the active players, plus a BYE vertex when their number is odd.
Integer edge weights rank, from most to least important: no rematch, small score differences,
then the seed pattern inside and between score groups. When no perfect matching exists, the
rules are relaxed one level at a time (see ``pair_round``).

Callers pass only active players. Everything is deterministic: players are put in standings
order (points, then seed) before anything is built, so input order never matters.
"""

import math
from collections.abc import Sequence
from dataclasses import dataclass
from enum import StrEnum
from itertools import groupby

import networkx as nx

# Edge weight = BASE - POINTS * (2 * score gap)^2 - seed term (- REMATCH for a rematch). Each
# scale exceeds the largest term below it for up to 256 players and 10 rounds, and BASE keeps
# every weight positive.
BASE = 10**12
REMATCH = 10**10
POINTS = 10**6
# A bye counts its score above the lowest at twice the pair rate. At the pair rate, a bye one
# step up the standings costs exactly as much as the float it saves, and the seed terms could
# hand the free point to a contender instead of the lowest scorer without a bye.
BYE_POINTS = 2 * POINTS
MAX_GAP = 1.5  # level 0 only pairs players at most this many points apart


class Relaxation(StrEnum):
    """A pairing rule that had to be broken."""

    ANY_POINTS = "any_points"  # a pair more than MAX_GAP points apart
    REMATCH = "rematch"  # two players who already met
    EXTRA_BYE = "extra_bye"  # a second bye for someone
    GREEDY = "greedy"  # the greedy fallback, which may repeat last round's pairing


@dataclass(frozen=True, slots=True)
class SwissPlayer:
    """An active player: seed 1 is strongest, points are multiples of 0.5.

    ``opponents`` holds everyone the player was already paired with; ``last_opponent`` is the
    previous round's opponent (None after a bye or a missed round).
    """

    id: str
    seed: int
    points: float
    opponents: frozenset[str] = frozenset()
    last_opponent: str | None = None
    byes: int = 0


@dataclass(frozen=True, slots=True)
class Pairings:
    """Pairs in board order with the higher-placed player first, the bye, and broken rules."""

    pairs: tuple[tuple[str, str], ...]
    bye: str | None
    relaxations: tuple[Relaxation, ...] = ()


@dataclass(frozen=True, slots=True)
class _Level:
    max_gap: int | None  # largest score difference in half-points, None for any
    rematches: bool  # players may meet again, except last round's opponents
    extra_byes: bool  # players who already had a bye may get another


_LEVELS = (
    _Level(max_gap=round(2 * MAX_GAP), rematches=False, extra_byes=False),
    _Level(max_gap=None, rematches=False, extra_byes=False),
    _Level(max_gap=None, rematches=True, extra_byes=False),
    _Level(max_gap=None, rematches=True, extra_byes=True),
)


def pair_first_round(players: Sequence[SwissPlayer]) -> Pairings:
    """Fold pairing by seed: with n even, the i-th seed meets the (i + n/2)-th.

    With an odd count the lowest seed (highest seed number) gets the bye.
    """
    ordered = sorted(_validated(players), key=lambda p: p.seed)
    bye = ordered.pop().id if len(ordered) % 2 else None
    half = len(ordered) // 2
    pairs = tuple((ordered[i].id, ordered[i + half].id) for i in range(half))
    return Pairings(pairs, bye)


def pair_round(players: Sequence[SwissPlayer]) -> Pairings:
    """Pair round 2 onwards with the first level that pairs everyone.

    - L0: no rematches, scores at most 1.5 apart, the bye only to players without one.
    - L1: any score difference.
    - L2: rematches at a REMATCH penalty, but never against last round's opponent.
    - L3: extra byes, at a REMATCH penalty per bye the player already had, so the bye goes to
      the players with the fewest byes that the pairing allows.
    - Otherwise ``greedy_pairing`` (for example, only two players left and they just met).

    Within a level the matching maximises the weights described in the module docstring:
    score groups stay together, the top half of a group meets the bottom half, floaters are
    the players nearest the group boundary, and the bye goes to the lowest-placed player of
    the lowest score that can take it.
    """
    standings = _standings(players)
    for level in _LEVELS:
        if level.extra_byes and len(standings) % 2 == 0:
            continue  # without a bye, this level is the previous one again
        matched = _match(standings, level)
        if matched is not None:
            pairs, bye = matched
            return Pairings(pairs, bye, _relaxations(standings, pairs, bye))
    return greedy_pairing(standings)


def greedy_pairing(players: Sequence[SwissPlayer]) -> Pairings:
    """Deterministic fallback, also for when the matching runs out of time.

    With an odd count the bye goes to the lowest-placed player with the fewest byes. Then, in
    standings order, each unpaired player takes the nearest unpaired player below them,
    preferring someone not yet played, then someone other than last round's opponent, then
    anyone.
    """
    standings = _standings(players)
    bye: SwissPlayer | None = None
    if len(standings) % 2:
        fewest = min(p.byes for p in standings)
        bye = next(p for p in reversed(standings) if p.byes == fewest)
    unpaired = [p for p in standings if p is not bye]
    pairs: list[tuple[str, str]] = []
    while unpaired:
        top = unpaired.pop(0)
        partner = (
            next((p for p in unpaired if not _played(top, p)), None)
            or next((p for p in unpaired if not _just_played(top, p)), None)
            or unpaired[0]
        )
        unpaired.remove(partner)
        pairs.append((top.id, partner.id))
    bye_id = bye.id if bye is not None else None
    used = _relaxations(standings, tuple(pairs), bye_id)
    return Pairings(tuple(pairs), bye_id, (*used, Relaxation.GREEDY))


def _validated(players: Sequence[SwissPlayer]) -> Sequence[SwissPlayer]:
    if len({p.id for p in players}) != len(players):
        raise ValueError("player ids must be unique")
    if len({p.seed for p in players}) != len(players):
        raise ValueError("seeds must be unique")
    for p in players:
        if not (math.isfinite(p.points) and p.points >= 0 and float(2 * p.points).is_integer()):
            raise ValueError(f"points must be a non-negative multiple of 0.5: {p.id}")
        if p.byes < 0:
            raise ValueError(f"byes must not be negative: {p.id}")
    return players


def _standings(players: Sequence[SwissPlayer]) -> list[SwissPlayer]:
    return sorted(_validated(players), key=lambda p: (-p.points, p.seed))


def _played(a: SwissPlayer, b: SwissPlayer) -> bool:
    return b.id in a.opponents or a.id in b.opponents or _just_played(a, b)


def _just_played(a: SwissPlayer, b: SwissPlayer) -> bool:
    return a.last_opponent == b.id or b.last_opponent == a.id


def _match(
    standings: list[SwissPlayer], level: _Level
) -> tuple[tuple[tuple[str, str], ...], str | None] | None:
    """The best pairing at ``level``, or None if it can't pair everyone."""
    n = len(standings)
    half_points = [round(2 * p.points) for p in standings]
    group_size = [size for size in _run_lengths(half_points) for _ in range(size)]
    graph: nx.Graph[int] = nx.Graph()
    graph.add_nodes_from(range(n))
    # Standings indices: i < j means i is placed higher. Within a score group the positions
    # are consecutive, so |pos_i - pos_j| = j - i.
    for i in range(n):
        for j in range(i + 1, n):
            gap = abs(half_points[i] - half_points[j])
            if level.max_gap is not None and gap > level.max_gap:
                continue
            rematch = _played(standings[i], standings[j])
            if rematch and (not level.rematches or _just_played(standings[i], standings[j])):
                continue
            # Same group: top half against bottom half. Across groups: the players nearest the
            # boundary float.
            seed_term = (2 * (j - i) - group_size[i]) ** 2 if gap == 0 else 4 * (j - i) ** 2
            weight = BASE - POINTS * gap**2 - seed_term - (REMATCH if rematch else 0)
            graph.add_edge(i, j, weight=weight)
    bye_node = n
    if n % 2:
        # The bye goes to the lowest-placed low scorer; each earlier bye costs a REMATCH.
        graph.add_node(bye_node)
        lowest = min(half_points)
        for i, player in enumerate(standings):
            if player.byes and not level.extra_byes:
                continue
            weight = (
                BASE
                - BYE_POINTS * (half_points[i] - lowest) ** 2
                - 4 * (n - 1 - i) ** 2
                - REMATCH * player.byes
            )
            graph.add_edge(i, bye_node, weight=weight)

    matching = nx.max_weight_matching(graph, maxcardinality=True)
    if 2 * len(matching) != graph.number_of_nodes():
        return None
    pairs: list[tuple[int, int]] = []
    bye: str | None = None
    for u, v in matching:
        first, second = sorted((int(u), int(v)))
        if second == bye_node:
            bye = standings[first].id
        else:
            pairs.append((first, second))
    pairs.sort()
    return tuple((standings[i].id, standings[j].id) for i, j in pairs), bye


def _run_lengths(values: list[int]) -> list[int]:
    return [len(list(run)) for _, run in groupby(values)]


def _relaxations(
    standings: list[SwissPlayer], pairs: tuple[tuple[str, str], ...], bye: str | None
) -> tuple[Relaxation, ...]:
    """The rules this pairing breaks, in the order of the levels that allow them."""
    by_id = {p.id: p for p in standings}
    used: set[Relaxation] = set()
    for a_id, b_id in pairs:
        a, b = by_id[a_id], by_id[b_id]
        if abs(a.points - b.points) > MAX_GAP:
            used.add(Relaxation.ANY_POINTS)
        if _played(a, b):
            used.add(Relaxation.REMATCH)
    if bye is not None and by_id[bye].byes:
        used.add(Relaxation.EXTRA_BYE)
    return tuple(r for r in Relaxation if r in used)
