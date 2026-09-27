"""The Practice Bot, a virtual opponent for unrated practice battles.

Its accuracy follows the user's expected score in the chapter, clamped to [0.45, 0.75], and its
answer times are log-normal around a 6 s median, never under 1.5 s.
"""

import math
import random

MIN_ACCURACY = 0.45
MAX_ACCURACY = 0.75
MEDIAN_TIME_MS = 6000
TIME_SIGMA = 0.5  # standard deviation of the log of the time
MIN_TIME_MS = 1500


def bot_accuracy(expected_user_accuracy: float) -> float:
    """The user's expected accuracy clamped to [0.45, 0.75]."""
    if math.isnan(expected_user_accuracy):
        raise ValueError("expected accuracy must be a number")
    return min(MAX_ACCURACY, max(MIN_ACCURACY, expected_user_accuracy))


def bot_answer(rng: random.Random, *, accuracy: float, limit_ms: int) -> tuple[bool, int | None]:
    """One answer as (correct, time_ms): correct with probability ``accuracy``, time log-normal.

    A time at or past ``limit_ms`` is a timeout, returned as (False, None).
    """
    if not 0 <= accuracy <= 1:
        raise ValueError("accuracy must be within [0, 1]")
    correct = rng.random() < accuracy
    sample = rng.lognormvariate(math.log(MEDIAN_TIME_MS), TIME_SIGMA)
    time_ms = max(MIN_TIME_MS, round(sample))
    if time_ms >= limit_ms:
        return False, None
    return correct, time_ms
