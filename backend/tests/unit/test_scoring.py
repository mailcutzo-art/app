"""Live-game scoring: latency allowance, timing verdicts, points, results and speed labels."""

import math

import pytest

from app.modules.realtime.engine.scoring import (
    PlayerTotals,
    Speed,
    Timing,
    effective_time_ms,
    judge_timing,
    latency_allowance,
    match_result,
    question_points,
    rank_group,
    speed_vs_opponents,
    speed_vs_typical,
)


@pytest.mark.parametrize(
    ("p50", "allowance"),
    [
        (None, 100),
        (0, 0),
        (99.4, 50),
        (100, 50),
        (101, 51),  # 50.5 rounds half up
        (103, 52),  # 51.5 rounds half up too (not to even)
        (499, 250),
        (500, 250),
        (2000, 250),
    ],
)
def test_latency_allowance(p50: float | None, allowance: int) -> None:
    assert latency_allowance(p50) == allowance


@pytest.mark.parametrize("p50", [-1.0, math.nan, math.inf])
def test_latency_allowance_rejects_bad_round_trips(p50: float) -> None:
    with pytest.raises(ValueError, match="round-trip"):
        latency_allowance(p50)


@pytest.mark.parametrize(
    ("el_client", "raw", "lat", "effective"),
    [
        (5000, 5100, 200, 5000),  # within [raw - lat, raw]: trusted
        (4900, 5100, 200, 4900),  # lower edge
        (4899, 5100, 200, 4900),  # claims to be faster than the allowance: clamped up
        (5100, 5100, 200, 5100),  # upper edge
        (6000, 5100, 200, 5100),  # slower than the server saw: clamped down
        (-50, 100, 200, 0),  # never below 0
        (10, 100, 200, 10),
        (700, 800, 0, 800),  # no allowance: the server time
    ],
)
def test_effective_time_is_the_client_time_clamped(
    el_client: int, raw: int, lat: int, effective: int
) -> None:
    assert effective_time_ms(el_client, raw, lat) == effective


def test_effective_time_rejects_a_negative_allowance() -> None:
    with pytest.raises(ValueError, match="latency"):
        effective_time_ms(100, 100, -1)


@pytest.mark.parametrize(
    ("raw", "effective", "verdict"),
    [
        (-1, 0, "too_early"),
        (0, 0, "accepted"),
        (15_000, 15_000, "accepted"),
        (15_200, 15_000, "accepted"),  # received at limit + allowance
        (15_000, 15_001, "late"),  # effective time over the limit
        (15_201, 15_000, "late"),  # received after limit + allowance
    ],
)
def test_judge_timing(raw: int, effective: int, verdict: str) -> None:
    assert judge_timing(raw_ms=raw, effective_ms=effective, limit_ms=15_000, lat_ms=200) == verdict


@pytest.mark.parametrize(
    ("effective", "points"),
    [
        (0, 150),
        (1000, 150),
        (1140, 150),  # bonus 49.5 rounds half up
        (1141, 149),
        (8000, 125),  # halfway through the scoring window
        (14_999, 100),  # bonus 0.0036 rounds down
        (15_000, 100),
        (20_000, 100),
    ],
)
def test_question_points_for_correct_answers(effective: int, points: int) -> None:
    assert question_points(True, effective, 15_000) == points


def test_wrong_answers_score_nothing() -> None:
    assert question_points(False, 500, 15_000) == 0
    assert question_points(False, 15_000, 15_000) == 0


def test_question_points_needs_a_limit_over_one_second() -> None:
    assert question_points(True, 1000, 1001) == 150
    assert question_points(True, 1001, 1001) == 100
    with pytest.raises(ValueError, match="limit"):
        question_points(True, 500, 1000)


@pytest.mark.parametrize(
    ("a", "b", "result"),
    [
        (PlayerTotals(700, 5, 40_000), PlayerTotals(650, 6, 10_000), "a"),  # points first
        (PlayerTotals(650, 5, 40_000), PlayerTotals(650, 6, 50_000), "b"),  # then correct
        (PlayerTotals(650, 5, 30_000), PlayerTotals(650, 5, 30_001), "a"),  # then less time
        (PlayerTotals(650, 5, 30_000), PlayerTotals(650, 5, 30_000), "draw"),
        (PlayerTotals(0, 0, 0), PlayerTotals(0, 0, 0), "draw"),
    ],
)
def test_match_result(a: PlayerTotals, b: PlayerTotals, result: str) -> None:
    assert match_result(a, b) == result
    mirrored = {"a": "b", "b": "a", "draw": "draw"}[result]
    assert match_result(b, a) == mirrored


def test_rank_group_orders_players_into_tie_groups() -> None:
    totals = {
        "zed": PlayerTotals(300, 2, 5000),
        "amy": PlayerTotals(300, 2, 5000),
        "top": PlayerTotals(400, 3, 9000),
        "quick": PlayerTotals(300, 2, 4000),
        "none": PlayerTotals(0, 0, 0),
        "more": PlayerTotals(300, 3, 9000),
    }

    assert rank_group(totals) == [["top"], ["more"], ["quick"], ["amy", "zed"], ["none"]]
    assert rank_group({}) == []


ANSWERED_5S = Timing(answered=True, time_ms=5000)
NO_ANSWER = Timing(answered=False, time_ms=0)


@pytest.mark.parametrize(
    ("mine", "label"),
    [
        (Timing(True, 4749), Speed.FAST),
        (Timing(True, 4750), Speed.EVEN),  # exactly 250 ms sooner
        (Timing(True, 5000), Speed.EVEN),
        (Timing(True, 5250), Speed.EVEN),  # exactly 250 ms later
        (Timing(True, 5251), Speed.SLOW),
        (NO_ANSWER, Speed.SLOW),
    ],
)
def test_speed_against_one_opponent(mine: Timing, label: Speed) -> None:
    assert speed_vs_opponents(mine, [ANSWERED_5S]) == (label, 5000)


def test_speed_when_nobody_else_answered_or_there_is_nobody() -> None:
    assert speed_vs_opponents(Timing(True, 14_000), [NO_ANSWER]) == (Speed.FAST, None)
    assert speed_vs_opponents(NO_ANSWER, [NO_ANSWER, NO_ANSWER]) == (None, None)
    assert speed_vs_opponents(Timing(True, 3000), []) == (None, None)
    assert speed_vs_opponents(NO_ANSWER, []) == (None, None)


@pytest.mark.parametrize(
    ("peers", "peer_time"),
    [
        ([Timing(True, 9000), Timing(True, 3000), Timing(True, 5000)], 5000),  # odd: middle
        ([Timing(True, 4000), Timing(True, 3000)], 3500),  # even: mean of the middle two
        ([Timing(True, 4001), Timing(True, 3000)], 3501),  # 3500.5 rounds half up
        ([Timing(True, 4001), NO_ANSWER, Timing(True, 3000), NO_ANSWER], 3501),
        (
            [Timing(True, t) for t in (1000, 2000, 7000, 8000, 9000, 9500)],
            7500,
        ),
    ],
)
def test_group_peer_time_is_the_median_of_those_who_answered(
    peers: list[Timing], peer_time: int
) -> None:
    assert speed_vs_opponents(Timing(True, peer_time), peers) == (Speed.EVEN, peer_time)


def test_speed_tie_band_is_adjustable() -> None:
    assert speed_vs_opponents(Timing(True, 4899), [ANSWERED_5S], tie_band_ms=100) == (
        Speed.FAST,
        5000,
    )
    assert speed_vs_opponents(Timing(True, 4900), [ANSWERED_5S], tie_band_ms=100) == (
        Speed.EVEN,
        5000,
    )


@pytest.mark.parametrize(
    ("time_ms", "typical_ms", "samples", "label"),
    [
        (5999, 8000, 20, Speed.FAST),
        (6000, 8000, 20, Speed.EVEN),  # exactly 0.75x
        (8000, 8000, 20, Speed.EVEN),
        (10_000, 8000, 20, Speed.EVEN),  # exactly 1.25x
        (10_001, 8000, 20, Speed.SLOW),
        (1000, 8000, 19, None),  # not enough correct answers behind the typical time
        (1000, None, 500, None),
        (1000, 0, 500, None),
        (1000, 8000, 5, Speed.FAST),  # a lower bar can be passed in
    ],
)
def test_speed_against_the_typical_time(
    time_ms: int, typical_ms: int | None, samples: int, label: Speed | None
) -> None:
    min_samples = 5 if samples == 5 else 20
    assert speed_vs_typical(time_ms, typical_ms, samples, min_samples) is label
