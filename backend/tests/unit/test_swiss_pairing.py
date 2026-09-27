"""Swiss pairing: round-1 folds, crafted later rounds, simulations and a brute-force oracle."""

import random
import time
from collections.abc import Callable, Iterator, Sequence
from dataclasses import replace

import pytest
from hypothesis import given, settings
from hypothesis import strategies as st

from app.modules.tournaments.swiss_pairing import (
    BASE,
    BYE_POINTS,
    POINTS,
    REMATCH,
    Pairings,
    Relaxation,
    SwissPlayer,
    greedy_pairing,
    pair_first_round,
    pair_round,
)


def p(
    seed: int,
    points: float = 0.0,
    *,
    played: Sequence[int] = (),
    last: int | None = None,
    byes: int = 0,
) -> SwissPlayer:
    """Player ``s<seed>``; ``last`` counts as played too."""
    opponents = {f"s{o}" for o in played} | ({f"s{last}"} if last is not None else set())
    return SwissPlayer(
        id=f"s{seed}",
        seed=seed,
        points=points,
        opponents=frozenset(opponents),
        last_opponent=f"s{last}" if last is not None else None,
        byes=byes,
    )


def standings(players: Sequence[SwissPlayer]) -> list[SwissPlayer]:
    return sorted(players, key=lambda x: (-x.points, x.seed))


def played(a: SwissPlayer, b: SwissPlayer) -> bool:
    return b.id in a.opponents or a.id in b.opponents or just_played(a, b)


def just_played(a: SwissPlayer, b: SwissPlayer) -> bool:
    return a.last_opponent == b.id or b.last_opponent == a.id


def play_round(
    players: Sequence[SwissPlayer], pairing: Pairings, rng: random.Random
) -> list[SwissPlayer]:
    """Apply random results and the bye, as the tournament service would."""
    by_id = {x.id: x for x in players}
    after: dict[str, SwissPlayer] = {}
    for a_id, b_id in pairing.pairs:
        a, b = by_id[a_id], by_id[b_id]
        score = rng.choice((1.0, 0.5, 0.0))
        after[a_id] = replace(
            a, points=a.points + score, opponents=a.opponents | {b_id}, last_opponent=b_id
        )
        after[b_id] = replace(
            b, points=b.points + 1 - score, opponents=b.opponents | {a_id}, last_opponent=a_id
        )
    if pairing.bye is not None:
        bye = by_id[pairing.bye]
        after[bye.id] = replace(bye, points=bye.points + 1, byes=bye.byes + 1, last_opponent=None)
    return [after[x.id] for x in players]


def simulate(
    n: int, rounds: int, seed: int, *, withdrawals: bool = True
) -> Iterator[tuple[list[SwissPlayer], Pairings]]:
    """A random tournament: the active players and their pairing, round by round.

    Seeds have gaps, and with ``withdrawals`` a player sometimes leaves after a round.
    """
    rng = random.Random(seed)  # noqa: S311
    players = [p(s) for s in sorted(rng.sample(range(1, 3 * n), n))]
    for number in range(1, rounds + 1):
        pairing = pair_first_round(players) if number == 1 else pair_round(players)
        yield players, pairing
        players = play_round(players, pairing, rng)
        if withdrawals and len(players) > 2 and rng.random() < 0.2:
            players.remove(rng.choice(players))


def check_invariants(players: Sequence[SwissPlayer], pairing: Pairings) -> None:
    by_id = {x.id: x for x in players}
    placed = {x.id: k for k, x in enumerate(standings(players))}
    seen = [player for pair in pairing.pairs for player in pair]
    if pairing.bye is not None:
        seen.append(pairing.bye)
    assert sorted(seen) == sorted(by_id), "every player exactly once"
    assert (pairing.bye is not None) == (len(players) % 2 == 1), "a bye only for an odd count"

    boards = [placed[a] for a, _ in pairing.pairs]
    assert boards == sorted(boards), "pairs in board order"
    greedy = Relaxation.GREEDY in pairing.relaxations
    used: set[Relaxation] = set()
    for a_id, b_id in pairing.pairs:
        a, b = by_id[a_id], by_id[b_id]
        assert placed[a_id] < placed[b_id], "the higher-placed player first"
        assert greedy or not just_played(a, b), "last round's opponents meet again only via greedy"
        if played(a, b):
            used.add(Relaxation.REMATCH)
        if abs(a.points - b.points) > 1.5:
            used.add(Relaxation.ANY_POINTS)
    if pairing.bye is not None and by_id[pairing.bye].byes:
        used.add(Relaxation.EXTRA_BYE)
    assert set(pairing.relaxations) - {Relaxation.GREEDY} == used, "relaxations describe it"


# Round 1


def test_first_round_folds_eight_players() -> None:
    pairing = pair_first_round([p(seed) for seed in range(1, 9)])

    assert pairing == Pairings((("s1", "s5"), ("s2", "s6"), ("s3", "s7"), ("s4", "s8")), None)


def test_first_round_gives_the_lowest_seed_the_bye_when_odd() -> None:
    pairing = pair_first_round([p(seed) for seed in range(1, 8)])

    assert pairing == Pairings((("s1", "s4"), ("s2", "s5"), ("s3", "s6")), "s7")


def test_first_round_follows_seed_order_not_input_order() -> None:
    players = [p(9), p(2), p(14), p(5)]

    assert pair_first_round(players) == Pairings((("s2", "s9"), ("s5", "s14")), None)
    assert pair_first_round(players[::-1]) == pair_first_round(players)


def test_empty_and_single_player() -> None:
    assert pair_first_round([]) == Pairings((), None)
    assert pair_round([]) == Pairings((), None)
    assert pair_first_round([p(1)]) == Pairings((), "s1")
    assert pair_round([p(1, 2.0)]) == Pairings((), "s1")
    assert pair_round([p(1, 2.0, byes=1)]) == Pairings((), "s1", (Relaxation.EXTRA_BYE,))


@pytest.mark.parametrize("pairer", [pair_first_round, pair_round, greedy_pairing])
@pytest.mark.parametrize(
    "players",
    [
        [p(1), replace(p(2), id="s1")],
        [p(1), p(1)],
        [p(1), replace(p(2), seed=1)],
        [p(1, 0.25), p(2)],
        [p(1, -1.0), p(2)],
        [p(1, float("nan")), p(2)],
        [p(1, byes=-1), p(2)],
    ],
)
def test_rejects_invalid_players(
    pairer: Callable[[Sequence[SwissPlayer]], Pairings], players: list[SwissPlayer]
) -> None:
    with pytest.raises(ValueError, match=r"unique|points|byes"):
        pairer(players)


# Later rounds, crafted


def test_players_stay_in_their_score_group_top_half_against_bottom_half() -> None:
    # Round 1 was 1-5, 2-6, 3-7, 4-8 and the top seeds won.
    players = [p(s, 1.0, last=s + 4) for s in range(1, 5)]
    players += [p(s, 0.0, last=s - 4) for s in range(5, 9)]

    pairing = pair_round(players)

    assert pairing == Pairings((("s1", "s3"), ("s2", "s4"), ("s5", "s7"), ("s6", "s8")), None)


def test_score_groups_follow_points_not_seeds() -> None:
    # Upsets in round 1: 6 and 8 beat 2 and 4.
    winners = [p(1, 1.0, last=5), p(6, 1.0, last=2), p(3, 1.0, last=7), p(8, 1.0, last=4)]
    losers = [p(5, 0.0, last=1), p(2, 0.0, last=6), p(7, 0.0, last=3), p(4, 0.0, last=8)]

    pairing = pair_round(winners + losers)

    assert pairing == Pairings((("s1", "s6"), ("s3", "s8"), ("s2", "s5"), ("s4", "s7")), None)


def test_the_floater_is_the_lowest_of_the_upper_group() -> None:
    players = [p(1, 1.0), p(2, 1.0), p(3, 1.0), p(4, 0.0), p(5, 0.0), p(6, 0.0)]

    pairing = pair_round(players)

    # s3 floats down to the top of the lower group.
    assert pairing == Pairings((("s1", "s2"), ("s3", "s4"), ("s5", "s6")), None)


def test_the_bye_goes_to_the_lowest_scorer_without_a_bye() -> None:
    # R1: 1-3 (1 won), 2-4 (2 won), bye 5. R2: 1-5 (1 won), 2-3 (3 won), bye 4.
    players = [
        p(1, 2.0, played=[3], last=5),
        p(2, 1.0, played=[4], last=3),
        p(3, 1.0, played=[1], last=2),
        p(4, 1.0, played=[2], byes=1),
        p(5, 1.0, last=1, byes=1),
    ]

    pairing = pair_round(players)

    assert pairing == Pairings((("s1", "s2"), ("s4", "s5")), "s3")


def test_the_bye_skips_a_lower_player_who_had_one_but_stays_in_the_lowest_score() -> None:
    # s5 is last but already had a bye. s4 takes it, and s3 floats down to s5; giving the free
    # point to s3 instead would save that float but hand a bye to a player half a point up.
    players = [p(1, 1.5), p(2, 1.5), p(3, 1.5), p(4, 1.0), p(5, 1.0, byes=1)]

    pairing = pair_round(players)

    assert pairing == Pairings((("s1", "s2"), ("s3", "s5")), "s4")


def test_an_extra_bye_goes_to_the_lowest_placed_player_with_the_fewest_byes() -> None:
    players = [
        p(1, 3.0, byes=1),
        p(2, 2.0, byes=1),
        p(3, 2.0, byes=1),
        p(4, 1.0, byes=1),
        p(5, 1.0, byes=2),
    ]

    pairing = pair_round(players)

    assert pairing == Pairings((("s1", "s2"), ("s3", "s5")), "s4", (Relaxation.EXTRA_BYE,))


def test_a_rematch_is_avoided_when_possible() -> None:
    players = [p(1, 2.0, last=2), p(2, 2.0, last=1), p(3, 1.0, last=4), p(4, 1.0, last=3)]

    pairing = pair_round(players)

    assert pairing == Pairings((("s1", "s3"), ("s2", "s4")), None)


def test_a_rematch_happens_only_when_unavoidable_and_never_with_last_opponent() -> None:
    # A full round robin of four: every pairing is a rematch. Last round was 1-4 and 2-3.
    players = [
        p(1, 3.0, played=[2, 3], last=4),
        p(2, 2.0, played=[1, 4], last=3),
        p(3, 1.0, played=[1, 4], last=2),
        p(4, 0.0, played=[2, 3], last=1),
    ]

    pairing = pair_round(players)

    assert pairing == Pairings((("s1", "s2"), ("s3", "s4")), None, (Relaxation.REMATCH,))


def test_scores_more_than_one_and_a_half_apart_only_when_needed() -> None:
    # s2 and s3 already met, so one of them has to face the leader, two points up.
    players = [p(1, 2.0), p(2, 0.0, played=[3]), p(3, 0.0, played=[2])]

    pairing = pair_round(players)

    assert pairing == Pairings((("s1", "s2"),), "s3", (Relaxation.ANY_POINTS,))


def test_an_extra_bye_beats_repeating_last_round() -> None:
    # s2 and s3 just met and both had a bye. Giving s1 the bye would repeat s2-s3, and s1 has
    # already met s2, so s2 takes a second bye and s3 meets s1.
    players = [
        p(1, 1.0, played=[2]),
        p(2, 1.5, played=[1], last=3, byes=1),
        p(3, 1.5, last=2, byes=1),
    ]

    pairing = pair_round(players)

    assert pairing == Pairings((("s3", "s1"),), "s2", (Relaxation.EXTRA_BYE,))


def test_two_players_who_just_met_are_paired_again_by_the_greedy_fallback() -> None:
    players = [p(1, 1.0, last=2), p(2, 0.0, last=1)]

    pairing = pair_round(players)

    assert pairing == Pairings((("s1", "s2"),), None, (Relaxation.REMATCH, Relaxation.GREEDY))


def test_greedy_bye_goes_to_the_lowest_placed_player_with_the_fewest_byes() -> None:
    players = [p(1), p(2), p(3), p(4), p(5, byes=1)]

    pairing = greedy_pairing(players)

    assert pairing == Pairings((("s1", "s2"), ("s3", "s5")), "s4", (Relaxation.GREEDY,))


def test_greedy_prefers_the_nearest_new_opponent() -> None:
    players = [p(1, played=[2]), p(2, played=[1]), p(3), p(4)]

    pairing = greedy_pairing(players)

    assert pairing == Pairings((("s1", "s3"), ("s2", "s4")), None, (Relaxation.GREEDY,))


def test_greedy_prefers_an_old_opponent_to_last_rounds() -> None:
    # s1 has met everyone; s2 is last round's opponent, so s3 is next in line.
    players = [
        p(1, played=[3, 4], last=2),
        p(2, played=[4], last=1),
        p(3, played=[1]),
        p(4, played=[1, 2]),
    ]

    pairing = greedy_pairing(players)

    assert pairing == Pairings(
        (("s1", "s3"), ("s2", "s4")), None, (Relaxation.REMATCH, Relaxation.GREEDY)
    )


def test_greedy_repeats_last_round_when_nothing_else_is_left() -> None:
    players = [p(1, 1.0, played=[3], last=2), p(2, 1.0, played=[3], last=1), p(3, 0.0)]

    pairing = greedy_pairing(players)

    assert pairing == Pairings((("s1", "s2"),), "s3", (Relaxation.REMATCH, Relaxation.GREEDY))


def test_output_does_not_depend_on_input_order() -> None:
    rounds = list(simulate(11, 3, seed=3))
    players, pairing = rounds[-1]
    shuffler = random.Random(4)  # noqa: S311

    for _ in range(5):
        shuffled = shuffler.sample(players, len(players))
        assert pair_round(shuffled) == pairing
        assert greedy_pairing(shuffled) == greedy_pairing(players)


def test_weight_scales_dominate_everything_below_them() -> None:
    """Checked for the largest tournament (256 players) and 10 rounds."""
    players, rounds = 256, 10
    # Same score group of size g: (2|pos_a - pos_b| - g)^2 < g^2 <= players^2.
    # Across groups and for the bye: 4 * (standings distance)^2 <= 4 * (players - 1)^2.
    max_seed_term = max(players**2, 4 * (players - 1) ** 2)
    # Scores differ by at most one point per round played.
    max_points_penalty = POINTS * (2 * rounds) ** 2
    max_bye_points_penalty = BYE_POINTS * (2 * rounds) ** 2
    # A bye edge loses REMATCH for each bye already had, at most one per round.
    max_rematch_penalty = REMATCH * rounds

    assert max_seed_term < POINTS
    assert max_points_penalty < REMATCH
    assert max_bye_points_penalty < REMATCH
    assert max_rematch_penalty + max_bye_points_penalty + max_seed_term < BASE


# Simulations


@settings(max_examples=100, deadline=None)
@given(n=st.integers(2, 64), rounds=st.integers(1, 6), seed=st.integers(0, 2**32 - 1))
def test_simulated_tournaments_keep_the_invariants(n: int, rounds: int, seed: int) -> None:
    for players, pairing in simulate(n, rounds, seed):
        check_invariants(players, pairing)


# A brute-force oracle for small tournaments, written from the spec rather than the code.

BYE = -1
_LEVEL_RELAXATION = (None, Relaxation.ANY_POINTS, Relaxation.REMATCH, Relaxation.EXTRA_BYE)


def oracle_weights(players: list[SwissPlayer], level: int) -> dict[tuple[int, int], int]:
    """Allowed edges at relaxation level 0-3 and their weights; ``players`` in standings order.

    A pair is (i, j) with i < j; a bye edge is (i, BYE).
    """
    n = len(players)
    lowest = min(x.points for x in players)
    weights: dict[tuple[int, int], int] = {}
    for i, a in enumerate(players):
        if n % 2 and (a.byes == 0 or level == 3):
            weights[i, BYE] = (
                BASE
                - BYE_POINTS * round(2 * (a.points - lowest)) ** 2
                - 4 * (n - 1 - i) ** 2
                - REMATCH * a.byes
            )
        for j in range(i + 1, n):
            b = players[j]
            gap = abs(a.points - b.points)
            rematch = played(a, b)
            if (level == 0 and gap > 1.5) or (rematch and (level < 2 or just_played(a, b))):
                continue
            if gap == 0:
                group = [x.id for x in players if x.points == a.points]
                pos_a, pos_b = group.index(a.id), group.index(b.id)
                seed_term = (2 * abs(pos_a - pos_b) - len(group)) ** 2
            else:
                seed_term = 4 * (i - j) ** 2
            rematch_term = REMATCH if rematch else 0
            weights[i, j] = BASE - POINTS * round(2 * gap) ** 2 - seed_term - rematch_term
    return weights


def perfect_matchings(nodes: list[int]) -> Iterator[list[tuple[int, int]]]:
    if not nodes:
        yield []
        return
    first, rest = nodes[0], nodes[1:]
    for index, other in enumerate(rest):
        for matching in perfect_matchings(rest[:index] + rest[index + 1 :]):
            yield [(first, other), *matching]


def best_total(n: int, weights: dict[tuple[int, int], int]) -> int | None:
    """The best total weight of a perfect matching, or None if there is none."""
    nodes = list(range(n)) + ([BYE] if n % 2 else [])
    totals = [
        sum(weights[edge] for edge in matching)
        for matching in perfect_matchings(nodes)
        if all(edge in weights for edge in matching)
    ]
    return max(totals, default=None)


def pairing_total(
    players: list[SwissPlayer], pairing: Pairings, weights: dict[tuple[int, int], int]
) -> int:
    index = {x.id: k for k, x in enumerate(players)}
    edges = [(index[a], index[b]) for a, b in pairing.pairs]
    if pairing.bye is not None:
        edges.append((index[pairing.bye], BYE))
    return sum(weights[edge] for edge in edges)


@settings(max_examples=300, deadline=None)
@given(n=st.integers(2, 10), rounds=st.integers(2, 7), seed=st.integers(0, 2**32 - 1))
def test_small_tournaments_match_a_brute_force_oracle(n: int, rounds: int, seed: int) -> None:
    for number, (players, pairing) in enumerate(simulate(n, rounds, seed), start=1):
        check_invariants(players, pairing)
        if number == 1:
            continue
        ordered = standings(players)
        weights = [oracle_weights(ordered, level) for level in range(4)]
        best = [best_total(len(ordered), level_weights) for level_weights in weights]

        # A rematch-free pairing (with the bye to someone without one) exists: no rematch.
        if best[1] is not None:
            assert Relaxation.REMATCH not in pairing.relaxations

        feasible = [level for level in range(4) if best[level] is not None]
        if not feasible:
            assert Relaxation.GREEDY in pairing.relaxations
            continue
        level = feasible[0]
        # The highest relaxation in the (ordered) list names the level that was used.
        top = pairing.relaxations[-1] if pairing.relaxations else None
        assert top == _LEVEL_RELAXATION[level], "the first level that pairs everyone"
        assert pairing_total(ordered, pairing, weights[level]) == best[level], "the best pairing"


def test_performance_256_players_after_three_rounds() -> None:
    rng = random.Random(256)  # noqa: S311
    players = [p(seed) for seed in range(1, 257)]
    players = play_round(players, pair_first_round(players), rng)
    for _ in range(2):  # quick setup rounds; only the call below is timed
        players = play_round(players, greedy_pairing(players), rng)

    started = time.perf_counter()
    pairing = pair_round(players)
    elapsed = time.perf_counter() - started

    check_invariants(players, pairing)
    assert pairing.relaxations == ()
    assert elapsed < 10, f"pairing {len(players)} players took {elapsed:.1f} s"
