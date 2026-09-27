"""The Practice Bot: clamped accuracy and log-normal answer times, checked on seeded samples."""

import math
import random
import statistics

import pytest

from app.modules.realtime.bots.model import bot_accuracy, bot_answer

SAMPLES = 5000


@pytest.mark.parametrize(
    ("expected", "accuracy"),
    [(0.0, 0.45), (0.2, 0.45), (0.45, 0.45), (0.6, 0.6), (0.75, 0.75), (0.9, 0.75), (1.0, 0.75)],
)
def test_bot_accuracy_is_clamped(expected: float, accuracy: float) -> None:
    assert bot_accuracy(expected) == accuracy


def test_bot_accuracy_rejects_nan() -> None:
    with pytest.raises(ValueError, match="number"):
        bot_accuracy(math.nan)


def test_answers_match_the_accuracy_and_time_distribution() -> None:
    rng = random.Random(20260927)  # noqa: S311

    answers = [bot_answer(rng, accuracy=0.6, limit_ms=10**9) for _ in range(SAMPLES)]

    times = [time_ms for _, time_ms in answers if time_ms is not None]
    assert len(times) == SAMPLES
    assert statistics.median(times) == pytest.approx(6000, rel=0.10)
    assert min(times) >= 1500
    assert all(isinstance(time_ms, int) for time_ms in times)
    accuracy = sum(correct for correct, _ in answers) / SAMPLES
    assert accuracy == pytest.approx(0.6, abs=0.03)


def test_answers_at_or_past_the_limit_are_timeouts() -> None:
    rng = random.Random(7)  # noqa: S311

    answers = [bot_answer(rng, accuracy=0.75, limit_ms=15_000) for _ in range(SAMPLES)]

    timeouts = [answer for answer in answers if answer[1] is None]
    assert all(answer == (False, None) for answer in timeouts)
    assert all(time_ms < 15_000 for _, time_ms in answers if time_ms is not None)
    # P(time >= 15 s) = P(Z >= ln(2.5) / 0.5), about 3.3%.
    assert len(timeouts) / SAMPLES == pytest.approx(0.033, abs=0.012)


def test_nothing_beats_the_fastest_time() -> None:
    rng = random.Random(1)  # noqa: S311

    assert {bot_answer(rng, accuracy=1.0, limit_ms=1500) for _ in range(100)} == {(False, None)}


def test_same_seed_same_answers() -> None:
    first = random.Random(42)  # noqa: S311
    second = random.Random(42)  # noqa: S311

    assert [bot_answer(first, accuracy=0.5, limit_ms=15_000) for _ in range(50)] == [
        bot_answer(second, accuracy=0.5, limit_ms=15_000) for _ in range(50)
    ]


@pytest.mark.parametrize("accuracy", [-0.1, 1.1, math.nan])
def test_bot_answer_rejects_impossible_accuracy(accuracy: float) -> None:
    with pytest.raises(ValueError, match="accuracy"):
        bot_answer(random.Random(0), accuracy=accuracy, limit_ms=15_000)  # noqa: S311
