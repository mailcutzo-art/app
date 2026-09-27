"""Live-game answers: latency-fair timing, points, match results and speed labels.

Times are milliseconds on the server clock, counted from when the question was shown. Each
player gets a latency allowance of half their median heartbeat round trip (at most 250 ms), and
the client's own elapsed time is trusted only within [raw - allowance, raw].
"""

import math
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from enum import StrEnum
from fractions import Fraction
from itertools import groupby
from typing import Literal

DEFAULT_LATENCY_MS = 100
MAX_LATENCY_MS = 250
BASE_POINTS = 100
SPEED_BONUS = 50
FULL_BONUS_MS = 1000
TIE_BAND_MS = 250
TYPICAL_MIN_SAMPLES = 20

TimingVerdict = Literal["accepted", "late", "too_early"]
MatchWinner = Literal["a", "b", "draw"]


class Speed(StrEnum):
    FAST = "fast"
    SLOW = "slow"
    EVEN = "even"


@dataclass(frozen=True, slots=True)
class Timing:
    """Whether a player answered (right or wrong) and, if so, their effective time."""

    answered: bool
    time_ms: int


@dataclass(frozen=True, slots=True)
class PlayerTotals:
    points: int
    correct: int
    correct_time_ms: int  # total effective time over correct answers


def latency_allowance(p50_rtt_ms: float | None) -> int:
    """Half the median round trip, rounded half up, at most 250 ms; 100 ms when unknown."""
    if p50_rtt_ms is None:
        return DEFAULT_LATENCY_MS
    if not (math.isfinite(p50_rtt_ms) and p50_rtt_ms >= 0):
        raise ValueError("round-trip time must be a non-negative number")
    return min(MAX_LATENCY_MS, _round_half_up(Fraction(p50_rtt_ms) / 2))


def effective_time_ms(el_client_ms: int, raw_ms: int, lat_ms: int) -> int:
    """The client's elapsed time clamped into [raw - lat, raw], and never below 0."""
    if lat_ms < 0:
        raise ValueError("latency allowance must not be negative")
    return max(0, min(raw_ms, max(raw_ms - lat_ms, el_client_ms)))


def judge_timing(*, raw_ms: int, effective_ms: int, limit_ms: int, lat_ms: int) -> TimingVerdict:
    """Too early if received before the question was shown; late if the effective time is over
    the limit or it arrived after limit + allowance; otherwise accepted.
    """
    if raw_ms < 0:
        return "too_early"
    if effective_ms > limit_ms or raw_ms > limit_ms + lat_ms:
        return "late"
    return "accepted"


def question_points(correct: bool, effective_ms: int, limit_ms: int) -> int:
    """0 if wrong, else 100 + round_half_up(50 * (1 - clamp((e - 1000) / (limit - 1000), 0, 1))).

    So a correct answer within the first second scores 150, and one at the limit 100.
    """
    if limit_ms <= FULL_BONUS_MS:
        raise ValueError(f"limit must be over {FULL_BONUS_MS} ms")
    if not correct:
        return 0
    span = limit_ms - FULL_BONUS_MS
    used = min(max(effective_ms - FULL_BONUS_MS, 0), span)
    return BASE_POINTS + _round_half_up(Fraction(SPEED_BONUS * (span - used), span))


def match_result(a: PlayerTotals, b: PlayerTotals) -> MatchWinner:
    """More points wins, then more correct answers, then less time on correct answers."""
    key_a, key_b = _strength(a), _strength(b)
    if key_a > key_b:
        return "a"
    if key_b > key_a:
        return "b"
    return "draw"


def rank_group(totals: Mapping[str, PlayerTotals]) -> list[list[str]]:
    """Players from first to last in tie groups (same rule as ``match_result``), ids sorted."""
    ordered = sorted(totals, key=lambda player: (_negated(_strength(totals[player])), player))
    return [list(group) for _, group in groupby(ordered, key=lambda p: _strength(totals[p]))]


def speed_vs_opponents(
    mine: Timing, peers: Sequence[Timing], tie_band_ms: int = TIE_BAND_MS
) -> tuple[Speed | None, int | None]:
    """Label an answer fast, slow or even against the opponents, with the time compared to.

    ``peers`` are the other human players connected when the question opened. Their time is
    the median over those who answered (the mean of the middle two, rounded half up). More than
    ``tie_band_ms`` sooner is fast, later is slow, otherwise even. If nobody else answered, an
    answer is fast; not answering while someone did is slow; if nobody answered, no label.
    """
    if not peers:
        return None, None
    times = sorted(peer.time_ms for peer in peers if peer.answered)
    if not times:
        return (Speed.FAST, None) if mine.answered else (None, None)
    middle = len(times) // 2
    peer_time = times[middle] if len(times) % 2 else (times[middle - 1] + times[middle] + 1) // 2
    if not mine.answered:
        return Speed.SLOW, peer_time
    if mine.time_ms < peer_time - tie_band_ms:
        return Speed.FAST, peer_time
    if mine.time_ms > peer_time + tie_band_ms:
        return Speed.SLOW, peer_time
    return Speed.EVEN, peer_time


def speed_vs_typical(
    time_ms: int, typical_ms: int | None, samples: int, min_samples: int = TYPICAL_MIN_SAMPLES
) -> Speed | None:
    """Solo practice against the question's typical time: under 0.75x is fast, over 1.25x slow.

    No label until the typical time rests on at least ``min_samples`` correct answers.
    """
    if typical_ms is None or typical_ms <= 0 or samples < min_samples:
        return None
    if 4 * time_ms < 3 * typical_ms:
        return Speed.FAST
    if 4 * time_ms > 5 * typical_ms:
        return Speed.SLOW
    return Speed.EVEN


def _strength(totals: PlayerTotals) -> tuple[int, int, int]:
    return totals.points, totals.correct, -totals.correct_time_ms


def _negated(key: tuple[int, int, int]) -> tuple[int, int, int]:
    return -key[0], -key[1], -key[2]


def _round_half_up(value: Fraction) -> int:
    return math.floor(value + Fraction(1, 2))
