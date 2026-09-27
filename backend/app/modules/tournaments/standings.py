"""Tournament standings and tie-breaks.

Order: points, Buchholz Cut-1, Buchholz, Sonneborn-Berger, quiz points (all descending), then
average time on correct answers (ascending, players without a correct answer last), then
registration order. A round that wasn't played over the board (bye, forfeit, double forfeit or
no record) counts against a virtual opponent with the player's own final points, so a no-show
opponent doesn't distort Buchholz.
"""

from collections.abc import Mapping, Sequence
from dataclasses import dataclass, replace
from enum import StrEnum
from fractions import Fraction


class GameResult(StrEnum):
    """How a round ended for one player."""

    WIN = "win"
    DRAW = "draw"
    LOSS = "loss"
    FORFEIT_WIN = "forfeit_win"
    FORFEIT_LOSS = "forfeit_loss"
    DOUBLE_FORFEIT = "double_forfeit"
    BYE = "bye"


RESULT_POINTS: Mapping[GameResult, float] = {
    GameResult.WIN: 1.0,
    GameResult.DRAW: 0.5,
    GameResult.LOSS: 0.0,
    GameResult.FORFEIT_WIN: 1.0,
    GameResult.FORFEIT_LOSS: 0.0,
    GameResult.DOUBLE_FORFEIT: 0.0,
    GameResult.BYE: 1.0,
}
_PLAYED = frozenset({GameResult.WIN, GameResult.DRAW, GameResult.LOSS})

# points, Cut-1, Buchholz, SB, quiz points (negated), no correct answer, average time, order, id
_SortKey = tuple[float, float, float, float, int, bool, Fraction, int, str]


@dataclass(frozen=True, slots=True)
class RoundRecord:
    """One player's round; ``opponent`` is None for a bye."""

    round: int
    opponent: str | None
    result: GameResult


@dataclass(frozen=True, slots=True)
class Entrant:
    """A registered player; rounds without a record (after withdrawing) count as unplayed."""

    id: str
    registered_order: int
    withdrawn: bool = False
    records: Sequence[RoundRecord] = ()
    quiz_points: int = 0
    correct_count: int = 0
    correct_time_ms: int = 0


@dataclass(frozen=True, slots=True)
class Standing:
    """One row of the standings, with every tie-break value."""

    rank: int
    entrant_id: str
    points: float
    buchholz_cut1: float
    buchholz: float
    sonneborn_berger: float
    quiz_points: int
    avg_correct_time_ms: float | None
    withdrawn: bool


def compute_standings(entrants: Sequence[Entrant], rounds: int) -> list[Standing]:
    """Rank every entrant after ``rounds`` rounds, with unique ranks 1..n.

    Per round the "opponent score" is the opponent's final points for a win, draw or loss, and
    the player's own final points otherwise. Buchholz sums them over rounds 1..``rounds``,
    Cut-1 drops the lowest, and Sonneborn-Berger sums opponent score * points earned. Withdrawn
    players stay in the list, flagged.
    """
    if rounds < 0:
        raise ValueError("rounds must not be negative")
    ids = {e.id for e in entrants}
    if len(ids) != len(entrants):
        raise ValueError("entrant ids must be unique")
    records = {e.id: _records_by_round(e, rounds, ids) for e in entrants}
    points = {
        entrant_id: sum((RESULT_POINTS[r.result] for r in by_round.values()), 0.0)
        for entrant_id, by_round in records.items()
    }

    rows: list[tuple[_SortKey, Standing]] = []
    for e in entrants:
        own = points[e.id]
        opponent_scores: list[float] = []
        sonneborn_berger = 0.0
        for number in range(1, rounds + 1):
            record = records[e.id].get(number)
            if record is not None and record.result in _PLAYED and record.opponent is not None:
                opponent_score = points[record.opponent]
            else:
                opponent_score = own
            earned = RESULT_POINTS[record.result] if record is not None else 0.0
            opponent_scores.append(opponent_score)
            sonneborn_berger += opponent_score * earned
        buchholz = sum(opponent_scores, 0.0)
        cut1 = buchholz - min(opponent_scores) if opponent_scores else 0.0
        average = Fraction(e.correct_time_ms, e.correct_count) if e.correct_count > 0 else None
        standing = Standing(
            rank=0,
            entrant_id=e.id,
            points=own,
            buchholz_cut1=cut1,
            buchholz=buchholz,
            sonneborn_berger=sonneborn_berger,
            quiz_points=e.quiz_points,
            avg_correct_time_ms=float(average) if average is not None else None,
            withdrawn=e.withdrawn,
        )
        key: _SortKey = (
            -own,
            -cut1,
            -buchholz,
            -sonneborn_berger,
            -e.quiz_points,
            average is None,
            average if average is not None else Fraction(0),
            e.registered_order,
            e.id,
        )
        rows.append((key, standing))

    rows.sort(key=lambda row: row[0])
    return [replace(standing, rank=rank) for rank, (_, standing) in enumerate(rows, start=1)]


def _records_by_round(entrant: Entrant, rounds: int, ids: set[str]) -> dict[int, RoundRecord]:
    by_round: dict[int, RoundRecord] = {}
    for record in entrant.records:
        if not 1 <= record.round <= rounds:
            raise ValueError(f"{entrant.id}: round {record.round} is outside 1..{rounds}")
        if record.round in by_round:
            raise ValueError(f"{entrant.id}: two records for round {record.round}")
        if record.result in _PLAYED and (
            record.opponent not in ids or record.opponent == entrant.id
        ):
            raise ValueError(f"{entrant.id}: round {record.round} needs a known opponent")
        by_round[record.round] = record
    return by_round
