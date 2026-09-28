"""The engine's Lua timing, points, speed labels and rankings agree with the Python rules.

``app.modules.realtime.engine.scoring`` is the reference; the scripts in ``engine/lua`` run the
same rules inside Redis. A probe script runs the shared Lua functions on generated inputs.
"""

from collections.abc import Iterator
from pathlib import Path
from typing import Any

import orjson
import pytest
import redis as sync_redis
from hypothesis import HealthCheck, given, settings
from hypothesis import strategies as st

from app.core.config import Settings
from app.modules.realtime.engine import scoring
from app.modules.realtime.engine.scripts import LIB_SOURCE

PROBE = LIB_SOURCE + "\n" + (Path(__file__).parent / "fixtures" / "lua" / "probe.lua").read_text()


@pytest.fixture(scope="module")
def lua(settings: Settings) -> Iterator[Any]:
    client = sync_redis.Redis.from_url(settings.redis_url.get_secret_value(), decode_responses=True)
    probe = client.register_script(PROBE)

    def run(op: str, **args: Any) -> Any:
        return orjson.loads(probe(args=[op, orjson.dumps(args).decode()]))

    yield run
    client.close()


FAST = settings(
    max_examples=150, deadline=None, suppress_health_check=[HealthCheck.function_scoped_fixture]
)


@FAST
@given(
    raw=st.integers(-2000, 40_000),
    el=st.integers(-1000, 40_000),
    lat=st.integers(0, 250),
    limit=st.integers(1001, 30_000),
    picked_correct=st.booleans(),
)
def test_timing_and_points_agree(
    lua: Any, raw: int, el: int, lat: int, limit: int, picked_correct: bool
) -> None:
    got = lua("judge", raw=raw, el=el, lat=lat, limit=limit, correct=picked_correct)

    effective = scoring.effective_time_ms(el, raw, lat)
    verdict = scoring.judge_timing(raw_ms=raw, effective_ms=effective, limit_ms=limit, lat_ms=lat)
    scores = verdict == "accepted" and picked_correct
    assert got == {
        "e": effective,
        "status": verdict,
        "ok": scores,
        "pts": scoring.question_points(scores, effective, limit),
    }


@pytest.mark.parametrize(
    ("e", "limit", "points"),
    [(0, 15_000, 150), (1000, 15_000, 150), (8000, 15_000, 125), (15_000, 15_000, 100)],
)
def test_points_at_the_edges(lua: Any, e: int, limit: int, points: int) -> None:
    got = lua("judge", raw=e, el=e, lat=0, limit=limit, correct=True)

    assert got["pts"] == points == scoring.question_points(True, e, limit)


timing = st.one_of(
    st.none(),  # no answer
    st.tuples(st.sampled_from(["accepted", "late"]), st.integers(0, 15_000)),
)


@FAST
@given(mine=timing, peers=st.lists(timing, min_size=0, max_size=6))
def test_speed_labels_agree(lua: Any, mine: Any, peers: list[Any]) -> None:
    humans = ["me", *(f"p{i}" for i in range(len(peers)))]
    answers = {
        uid: {"status": value[0], "e": value[1]}
        for uid, value in zip(humans, [mine, *peers], strict=True)
        if value is not None
    }
    got = lua("speed", bot="", humans=humans, open=humans, uid="me", answers=answers)

    def as_timing(value: Any) -> scoring.Timing:
        answered = value is not None and value[0] == "accepted"
        return scoring.Timing(answered=answered, time_ms=value[1] if answered else 0)

    speed, peer = scoring.speed_vs_opponents(as_timing(mine), [as_timing(p) for p in peers])
    assert got == {"speed": speed.value if speed else None, "peer": peer}


def test_players_who_were_away_at_the_open_and_bot_games_get_no_label(lua: Any) -> None:
    answers = {"me": {"status": "accepted", "e": 3000}, "you": {"status": "accepted", "e": 6000}}

    away = lua("speed", bot="", humans=["me", "you"], open=["you"], uid="me", answers=answers)
    peer_away = lua("speed", bot="", humans=["me", "you"], open=["me"], uid="me", answers=answers)
    bot = lua("speed", bot="bot:1", humans=["me"], open=["me", "bot:1"], uid="me", answers=answers)

    assert away == peer_away == bot == {"speed": None, "peer": None}


points = st.integers(0, 3)
totals = st.builds(
    scoring.PlayerTotals,
    points=st.sampled_from([0, 100, 150, 250]),
    correct=st.integers(0, 2),
    correct_time_ms=st.sampled_from([0, 1000, 2000]),
)


@FAST
@given(players=st.dictionaries(st.sampled_from("abcdefgh"), totals, min_size=1, max_size=8))
def test_places_agree(lua: Any, players: dict[str, scoring.PlayerTotals]) -> None:
    got = lua(
        "places",
        uids=list(players),
        totals={
            uid: {"points": t.points, "correct": t.correct, "correct_ms": t.correct_time_ms}
            for uid, t in players.items()
        },
    )

    assert got == scoring.rank_group(players)
