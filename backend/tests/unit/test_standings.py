"""Tournament standings: hand-computed scenarios covering every tie-break level."""

import pytest

from app.modules.tournaments.standings import (
    Entrant,
    GameResult,
    RoundRecord,
    Standing,
    compute_standings,
)

WIN = GameResult.WIN
DRAW = GameResult.DRAW
LOSS = GameResult.LOSS
FORFEIT_WIN = GameResult.FORFEIT_WIN
FORFEIT_LOSS = GameResult.FORFEIT_LOSS
DOUBLE_FORFEIT = GameResult.DOUBLE_FORFEIT
BYE = GameResult.BYE


def entrant(
    entrant_id: str,
    order: int,
    *games: tuple[str | None, GameResult],
    withdrawn: bool = False,
    quiz: int = 0,
    correct: int = 0,
    time_ms: int = 0,
) -> Entrant:
    """``games`` are (opponent, result) for rounds 1, 2, ...; later rounds may be missing."""
    records = tuple(
        RoundRecord(number, opponent, result)
        for number, (opponent, result) in enumerate(games, start=1)
    )
    return Entrant(entrant_id, order, withdrawn, records, quiz, correct, time_ms)


def table(standings: list[Standing]) -> list[tuple[int, str, float, float, float, float]]:
    return [
        (s.rank, s.entrant_id, s.points, s.buchholz_cut1, s.buchholz, s.sonneborn_berger)
        for s in standings
    ]


def test_scenario_with_a_withdrawal_byes_a_forfeit_and_draws() -> None:
    # R1: A beat D, B drew E, C beat F; then F withdrew.
    # R2: A beat C, B beat D, E had the bye.
    # R3: A drew B, E didn't show against C (forfeit), D had the bye.
    entrants = [
        entrant("A", 1, ("D", WIN), ("C", WIN), ("B", DRAW)),
        entrant("B", 2, ("E", DRAW), ("D", WIN), ("A", DRAW)),
        entrant("C", 3, ("F", WIN), ("A", LOSS), ("E", FORFEIT_WIN)),
        entrant("D", 4, ("A", LOSS), ("B", LOSS), (None, BYE)),
        entrant("E", 5, ("B", DRAW), (None, BYE), ("C", FORFEIT_LOSS)),
        entrant("F", 6, ("C", LOSS), withdrawn=True),
    ]

    standings = compute_standings(entrants, rounds=3)

    # Final points: A 2.5, B 2, C 2, E 1.5, D 1, F 0. Opponent scores per round, where an
    # unplayed round (bye, forfeit, missing) counts the player's own points:
    #   A: D 1, C 2, B 2        BH 5.0  Cut-1 4.0  SB 1 + 2 + 2*0.5         = 4.0
    #   B: E 1.5, D 1, A 2.5    BH 5.0  Cut-1 4.0  SB 0.75 + 1 + 1.25       = 3.0
    #   C: F 0, A 2.5, own 2    BH 4.5  Cut-1 4.5  SB 0 + 0 + 2             = 2.0
    #   D: A 2.5, B 2, own 1    BH 5.5  Cut-1 4.5  SB 0 + 0 + 1             = 1.0
    #   E: B 2, own 1.5, own 1.5 BH 5.0 Cut-1 3.5  SB 1 + 1.5 + 0           = 2.5
    #   F: C 2, own 0, own 0    BH 2.0  Cut-1 2.0  SB 0
    # C and B tie on points; C's weakest opponent (F, 0) is cut, so C is ahead.
    assert table(standings) == [
        (1, "A", 2.5, 4.0, 5.0, 4.0),
        (2, "C", 2.0, 4.5, 4.5, 2.0),
        (3, "B", 2.0, 4.0, 5.0, 3.0),
        (4, "E", 1.5, 3.5, 5.0, 2.5),
        (5, "D", 1.0, 4.5, 5.5, 1.0),
        (6, "F", 0.0, 2.0, 2.0, 0.0),
    ]
    assert [s.withdrawn for s in standings] == [False] * 5 + [True]


def test_scenario_decided_by_quiz_points_and_answer_time() -> None:
    # R1: P1 drew P2, P4 didn't show against P3, P6 beat P5; then P4 withdrew.
    # R2: P1 and P6 both didn't show (double forfeit), P2 drew P3, P5 had the bye.
    # R3: P1 beat P5, P3 drew P6, P2 had the bye.
    entrants = [
        entrant(
            "P1",
            1,
            ("P2", DRAW),
            ("P6", DOUBLE_FORFEIT),
            ("P5", WIN),
            quiz=900,
            correct=12,
            time_ms=72_000,
        ),
        entrant(
            "P2",
            2,
            ("P1", DRAW),
            ("P3", DRAW),
            (None, BYE),
            quiz=1100,
            correct=15,
            time_ms=60_000,
        ),
        entrant(
            "P3",
            3,
            ("P4", FORFEIT_WIN),
            ("P2", DRAW),
            ("P6", DRAW),
            quiz=1200,
            correct=14,
            time_ms=84_000,
        ),
        entrant("P4", 4, ("P3", FORFEIT_LOSS), withdrawn=True),
        entrant("P5", 5, ("P6", LOSS), (None, BYE), ("P1", LOSS), quiz=500),
        entrant(
            "P6",
            6,
            ("P5", WIN),
            ("P1", DOUBLE_FORFEIT),
            ("P3", DRAW),
            quiz=900,
            correct=10,
            time_ms=55_000,
        ),
    ]

    standings = compute_standings(entrants, rounds=3)

    # Final points: P2 2, P3 2, P1 1.5, P6 1.5, P5 1, P4 0.
    #   P1: P2 2, own 1.5, P5 1       BH 4.5  Cut-1 3.5  SB 1 + 0 + 1          = 2.0
    #   P2: P1 1.5, P3 2, own 2       BH 5.5  Cut-1 4.0  SB 0.75 + 1 + 2       = 3.75
    #   P3: own 2, P2 2, P6 1.5       BH 5.5  Cut-1 4.0  SB 2 + 1 + 0.75       = 3.75
    #   P4: own 0 (forfeit, missing)  BH 0    Cut-1 0    SB 0
    #   P5: P6 1.5, own 1, P1 1.5     BH 4.0  Cut-1 3.0  SB 0 + 1 + 0          = 1.0
    #   P6: P5 1, own 1.5, P3 2       BH 4.5  Cut-1 3.5  SB 1 + 0 + 1          = 2.0
    # P3 and P2 tie through SB: P3 has more quiz points (1200 > 1100).
    # P6 and P1 tie through quiz points: P6 is faster on correct answers (5500 < 6000 ms).
    assert table(standings) == [
        (1, "P3", 2.0, 4.0, 5.5, 3.75),
        (2, "P2", 2.0, 4.0, 5.5, 3.75),
        (3, "P6", 1.5, 3.5, 4.5, 2.0),
        (4, "P1", 1.5, 3.5, 4.5, 2.0),
        (5, "P5", 1.0, 3.0, 4.0, 1.0),
        (6, "P4", 0.0, 0.0, 0.0, 0.0),
    ]
    assert [s.avg_correct_time_ms for s in standings] == [6000, 4000, 5500, 6000, None, None]
    assert [s.quiz_points for s in standings] == [1200, 1100, 900, 900, 500, 0]


def test_scenario_decided_by_buchholz_and_by_having_correct_answers() -> None:
    # Seven entrants, two rounds.
    # R1: X had the bye, Y beat Q, P beat Z, P2 beat W.
    # R2: P beat X, P2 beat Y, Q drew Z, W had the bye.
    entrants = [
        entrant("W", 1, ("P2", LOSS), (None, BYE), quiz=400),
        entrant("X", 2, (None, BYE), ("P", LOSS), quiz=400, correct=4, time_ms=26_000),
        entrant("Y", 3, ("Q", WIN), ("P2", LOSS), quiz=400),
        entrant("P", 4, ("Z", WIN), ("X", WIN)),
        entrant("P2", 5, ("W", WIN), ("Y", WIN)),
        entrant("Q", 6, ("Y", LOSS), ("Z", DRAW)),
        entrant("Z", 7, ("P", LOSS), ("Q", DRAW)),
    ]

    standings = compute_standings(entrants, rounds=2)

    # Final points: P 2, P2 2, W 1, X 1, Y 1, Q 0.5, Z 0.5.
    #   P:  Z 0.5, X 1         BH 1.5  Cut-1 1.0  SB 0.5 + 1   = 1.5
    #   P2: W 1, Y 1           BH 2.0  Cut-1 1.0  SB 1 + 1     = 2.0
    #   W:  P2 2, own 1        BH 3.0  Cut-1 2.0  SB 0 + 1     = 1.0
    #   X:  own 1, P 2         BH 3.0  Cut-1 2.0  SB 1 + 0     = 1.0
    #   Y:  Q 0.5, P2 2        BH 2.5  Cut-1 2.0  SB 0.5 + 0   = 0.5
    #   Q:  Y 1, Z 0.5         BH 1.5  Cut-1 1.0  SB 0 + 0.25  = 0.25
    #   Z:  P 2, Q 0.5         BH 2.5  Cut-1 2.0  SB 0 + 0.25  = 0.25
    # P2 is ahead of P, and W and X ahead of Y, on Buchholz after equal Cut-1. W and X tie
    # through quiz points; W registered first but has no correct answers, so X is ahead.
    assert table(standings) == [
        (1, "P2", 2.0, 1.0, 2.0, 2.0),
        (2, "P", 2.0, 1.0, 1.5, 1.5),
        (3, "X", 1.0, 2.0, 3.0, 1.0),
        (4, "W", 1.0, 2.0, 3.0, 1.0),
        (5, "Y", 1.0, 2.0, 2.5, 0.5),
        (6, "Z", 0.5, 2.0, 2.5, 0.25),
        (7, "Q", 0.5, 1.0, 1.5, 0.25),
    ]


def test_scenario_decided_by_sonneborn_berger() -> None:
    # R1: A beat D, B beat E, C drew F. R2: A drew B, C beat E, D beat F.
    # R3: A drew C, B beat F, D beat E.
    entrants = [
        entrant("A", 1, ("D", WIN), ("B", DRAW), ("C", DRAW)),
        entrant("B", 2, ("E", WIN), ("A", DRAW), ("F", WIN)),
        entrant("C", 3, ("F", DRAW), ("E", WIN), ("A", DRAW)),
        entrant("D", 4, ("A", LOSS), ("F", WIN), ("E", WIN)),
        entrant("E", 5, ("B", LOSS), ("C", LOSS), ("D", LOSS)),
        entrant("F", 6, ("C", DRAW), ("D", LOSS), ("B", LOSS)),
    ]

    standings = compute_standings(entrants, rounds=3)

    # Final points: B 2.5, A 2, C 2, D 2, F 0.5, E 0.
    #   A: D 2, B 2.5, C 2     BH 6.5  Cut-1 4.5  SB 2 + 1.25 + 1  = 4.25
    #   C: F 0.5, E 0, A 2     BH 2.5  Cut-1 2.5  SB 0.25 + 0 + 1  = 1.25
    #   D: A 2, F 0.5, E 0     BH 2.5  Cut-1 2.5  SB 0 + 0.5 + 0   = 0.5
    # C and D tie on points, Cut-1 and Buchholz; C drew the strong A where D lost to it.
    assert table(standings) == [
        (1, "B", 2.5, 2.5, 2.5, 1.5),
        (2, "A", 2.0, 4.5, 6.5, 4.25),
        (3, "C", 2.0, 2.5, 2.5, 1.25),
        (4, "D", 2.0, 2.5, 2.5, 0.5),
        (5, "F", 0.5, 4.5, 6.5, 1.0),
        (6, "E", 0.0, 4.5, 6.5, 0.0),
    ]


def test_before_any_round_quiz_points_time_then_registration_decide() -> None:
    entrants = [
        entrant("late", 5),
        entrant("slow", 3, quiz=100, correct=2, time_ms=9_000),
        entrant("fast", 4, quiz=100, correct=3, time_ms=9_000),
        entrant("early", 1),
        entrant("best", 9, quiz=300),
    ]

    standings = compute_standings(entrants, rounds=0)

    assert [s.entrant_id for s in standings] == ["best", "fast", "slow", "early", "late"]
    assert [s.rank for s in standings] == [1, 2, 3, 4, 5]
    assert {s.buchholz_cut1 for s in standings} == {0.0}


def test_a_player_without_records_counts_every_round_as_unplayed() -> None:
    standings = compute_standings([entrant("A", 1), entrant("B", 2, (None, BYE))], rounds=2)

    by_id = {s.entrant_id: s for s in standings}
    assert (by_id["A"].points, by_id["A"].buchholz, by_id["A"].sonneborn_berger) == (0, 0, 0)
    # B: a bye (own 1 point, 1 earned) and a missing round (own 1 point, 0 earned).
    assert (by_id["B"].buchholz, by_id["B"].buchholz_cut1, by_id["B"].sonneborn_berger) == (
        2.0,
        1.0,
        1.0,
    )


@pytest.mark.parametrize(
    ("entrants", "rounds", "match"),
    [
        ([entrant("A", 1), entrant("A", 2)], 1, "unique"),
        ([entrant("A", 1, (None, BYE))], 0, "outside"),
        ([entrant("A", 1)], -1, "negative"),
        ([Entrant("A", 1, records=(RoundRecord(1, None, BYE),) * 2)], 1, "two records"),
        ([entrant("A", 1, ("Z", WIN))], 1, "opponent"),
        ([entrant("A", 1, (None, DRAW))], 1, "opponent"),
        ([entrant("A", 1, ("A", LOSS))], 1, "opponent"),
    ],
)
def test_rejects_inconsistent_input(entrants: list[Entrant], rounds: int, match: str) -> None:
    with pytest.raises(ValueError, match=match):
        compute_standings(entrants, rounds)
