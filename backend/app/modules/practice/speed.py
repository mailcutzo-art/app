"""Speed labels in solo practice: an answer's time against the question's typical time."""

from dataclasses import dataclass

from app.modules.content.models import QuestionStats
from app.modules.practice.models import Outcome
from app.modules.realtime.engine import scoring

TYPICAL = "typical"


@dataclass(frozen=True, slots=True)
class SpeedLabel:
    speed: str | None = None  # fast, slow or even
    basis: str | None = None  # "typical" here; "opponents" in live games
    peer_time_ms: int | None = None  # what the time was compared with


NO_LABEL = SpeedLabel()


def typical_speed(outcome: Outcome, time_ms: int, stats: QuestionStats | None) -> SpeedLabel:
    """Label a correct or wrong answer once the question has a typical time.

    Skips and timeouts have no measured time, so they are never compared.
    """
    if outcome not in {Outcome.CORRECT, Outcome.WRONG} or stats is None:
        return NO_LABEL
    if stats.typical_ms is None:
        return NO_LABEL
    speed = speed_vs_typical(time_ms, stats.typical_ms, stats.timed_correct)
    if speed is None:
        return NO_LABEL
    return SpeedLabel(speed=speed, basis=TYPICAL, peer_time_ms=stats.typical_ms)


def speed_vs_typical(time_ms: int, typical_ms: int, samples: int) -> str | None:
    """The labelling rule: ``app.modules.realtime.engine.scoring.speed_vs_typical``."""
    speed = scoring.speed_vs_typical(time_ms, typical_ms, samples)
    return speed.value if speed is not None else None
