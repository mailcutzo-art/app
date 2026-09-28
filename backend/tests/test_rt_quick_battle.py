"""Quick Battles between two protocol bots: a full rated game, forfeits, drops and resumes."""

import asyncio
import uuid

import pytest
from httpx import AsyncClient
from redis.asyncio import Redis
from sqlalchemy import select

from app.modules.matches.models import HeadToHead, Match, MatchParticipant
from app.modules.practice.models import QuestionAttempt
from app.modules.ratings import glicko2
from app.modules.ratings.models import Rating, RatingHistory
from tests.rt_helpers import (
    LockedSessions,
    RtServer,
    connect_bot,
    correct_option,
    pair,
    ready_both,
    sign_in,
    until_shown,
    wrong_option,
)


async def test_a_rated_game_rates_both_players_with_glicko2(
    rt: RtServer, api: AsyncClient, redis: Redis, sessions: LockedSessions
) -> None:
    asha, ravi, mid = await pair(rt, api)
    found = asha.seen("mm.found")[0]["d"]
    await ready_both(asha, ravi, mid)

    for _ in range(2):
        show = await asha.expect("q.show")
        await ravi.expect("q.show", lambda f, q=show["d"]["q"]: f["d"]["q"] == q)
        await until_shown(show)
        right = await correct_option(redis, mid, show["d"]["q"])
        fast = await asha.request(
            "ans.submit", {"match_id": mid, "q": show["d"]["q"], "opt": right, "el_ms": 10}
        )
        await asha.expect("q.progress")
        await asyncio.sleep(0.6)
        slow = await ravi.request(
            "ans.submit",
            {
                "match_id": mid,
                "q": show["d"]["q"],
                "opt": await wrong_option(redis, mid, show),
                "el_ms": 900,
            },
        )
        assert fast["d"]["status"] == slow["d"]["status"] == "accepted"
        reveal = await asha.expect("q.reveal")
        mine, theirs = reveal["d"]["players"][asha.user_id], reveal["d"]["players"][ravi.user_id]
        assert reveal["d"]["correct"] == right
        assert mine["correct"] is True
        assert mine["pts"] >= 145
        assert theirs["correct"] is False
        assert theirs["pts"] == 0
        assert (mine["speed"], theirs["speed"]) == ("fast", "slow")
        assert reveal["d"]["ref"].startswith("q_")

    end_asha = await asha.expect("match.end")
    end_ravi = await ravi.expect("match.end")
    settled_asha = await asha.expect("match.settled")
    settled_ravi = await ravi.expect("match.settled")

    assert found["mode"] == "rated"
    assert found["opponent"]["uid"] == ravi.user_id
    assert found["opponent"]["rating"] == {"display": "—", "value": None, "provisional": True}
    assert found["opponent"]["record"] == {"wins": 0, "losses": 0, "draws": 0}
    assert end_asha["seq"] == end_ravi["seq"]
    assert (end_asha["d"]["result"], end_ravi["d"]["result"]) == ("win", "loss")
    assert end_asha["d"]["ranking"] == [[asha.user_id], [ravi.user_id]]
    winner, loser = glicko2.rate_game(glicko2.Rating(), glicko2.Rating(), 1.0)
    assert settled_asha["d"]["rating"] == {
        "scope": "physics",
        "before": "—",
        "after": f"{round(winner.rating)}?",
        "delta": round(winner.rating) - 1500,
    }
    assert settled_ravi["d"]["rating"]["after"] == f"{round(loser.rating)}?"
    assert settled_asha["d"]["xp"]["delta"] == 30
    assert settled_ravi["d"]["xp"]["delta"] == 10

    async with sessions() as db:
        ratings = {(str(r.user_id), r.scope): r for r in (await db.scalars(select(Rating))).all()}
        history = (await db.scalars(select(RatingHistory))).all()
        h2h = (await db.scalars(select(HeadToHead))).one()
        seats = (
            await db.scalars(
                select(MatchParticipant).where(MatchParticipant.match_id == uuid.UUID(mid))
            )
        ).all()
        attempts = (
            await db.scalars(
                select(QuestionAttempt).where(QuestionAttempt.session_id == uuid.UUID(mid))
            )
        ).all()
        match = await db.get_one(Match, uuid.UUID(mid))
    for scope in ("overall", "physics"):
        assert ratings[(asha.user_id, scope)].rating == pytest.approx(winner.rating)
        assert ratings[(asha.user_id, scope)].rd == pytest.approx(winner.rd)
        assert ratings[(ravi.user_id, scope)].rating == pytest.approx(loser.rating)
        assert ratings[(ravi.user_id, scope)].games == 1
    assert len(history) == 4
    lo_is_asha = uuid.UUID(asha.user_id) < uuid.UUID(ravi.user_id)
    assert (h2h.lo_wins, h2h.hi_wins) == ((1, 0) if lo_is_asha else (0, 1))
    assert {s.result for s in seats} == {"win", "loss"}
    assert match.status == "settled"
    assert match.end_reason == "normal"
    assert {(a.speed, a.speed_basis) for a in attempts if str(a.user_id) == asha.user_id} == {
        ("fast", "opponents")
    }
    assert all(a.peer_time_ms is not None for a in attempts)
    assert {a.mode for a in attempts} == {"quick_rated"}
    for bot in (asha, ravi):
        await bot.close()


async def test_a_forfeit_after_question_1_loses(rt: RtServer, api: AsyncClient) -> None:
    asha, ravi, mid = await pair(rt, api)
    await ready_both(asha, ravi, mid)
    await asha.expect("q.show")

    reply = await ravi.request("match.forfeit", {"match_id": mid})
    end_asha = await asha.expect("match.end")
    end_ravi = await ravi.expect("match.end")
    settled = await asha.expect("match.settled")

    assert reply["t"] == "ack"
    assert end_asha["d"]["reason"] == end_ravi["d"]["reason"] == "forfeit"
    assert (end_asha["d"]["result"], end_ravi["d"]["result"]) == ("win", "loss")
    assert settled["d"]["rating"]["delta"] > 0
    for bot in (asha, ravi):
        await bot.close()


async def test_a_drop_starts_the_grace_and_a_reconnect_resumes_the_game(
    rt: RtServer, api: AsyncClient
) -> None:
    asha, ravi, mid = await pair(rt, api)
    await ready_both(asha, ravi, mid)
    await asha.expect("q.show")
    last_seq = max(f.get("seq", 0) for f in ravi.frames if f.get("ch") == f"m:{mid}")

    await ravi.close()
    away = await asha.expect("opp.conn", lambda f: f["d"]["state"] == "reconnecting")
    back = await connect_bot(
        rt.url,
        api,
        await sign_in(api, "ravi@example.com"),
        name="ravi-again",
        resume=[{"ch": f"m:{mid}", "last_seq": last_seq}],
    )
    welcome = back.seen("welcome")[0]
    await asha.expect("opp.conn", lambda f: f["d"]["state"] == "connected")
    await back.expect("q.reveal")  # the game carries on for the returning player
    replayed = [f for f in back.frames if f.get("ch") == f"m:{mid}" and "seq" in f]

    assert away["d"]["uid"] == ravi.user_id
    assert away["d"]["grace_until"] > 0
    assert welcome["d"]["active"] == [
        {"kind": "match", "id": mid, "ch": f"m:{mid}", "state": welcome["d"]["active"][0]["state"]}
    ]
    assert welcome["d"]["hb_s"] == 1
    # Replayed from the log: nothing missed, nothing repeated, in order.
    seqs = [f["seq"] for f in replayed]
    assert seqs == list(range(last_seq + 1, last_seq + 1 + len(seqs)))
    assert "opp.conn" in [f["t"] for f in replayed]
    for bot in (asha, back):
        await bot.close()


async def test_a_player_away_past_their_grace_loses(rt: RtServer, api: AsyncClient) -> None:
    asha, ravi, mid = await pair(rt, api)
    await ready_both(asha, ravi, mid)
    await asha.expect("q.show")

    await ravi.close()
    end = await asha.expect("match.end", wait_s=8)

    assert end["d"]["reason"] == "disconnected"
    assert end["d"]["result"] == "win"
    await asha.close()


async def test_both_players_dropping_voids_the_match(
    rt: RtServer, api: AsyncClient, sessions: LockedSessions
) -> None:
    asha, ravi, mid = await pair(rt, api)
    await ready_both(asha, ravi, mid)
    await asha.expect("q.show")

    await asha.close()
    await ravi.close()
    for _ in range(100):
        async with sessions() as db:
            match = await db.get_one(Match, uuid.UUID(mid))
            if match.settled_at is not None:
                break
        await asyncio.sleep(0.1)

    assert match.status == "voided"
    assert match.end_reason == "voided"


async def test_not_getting_ready_aborts_and_requeues_the_ready_player(
    rt: RtServer, api: AsyncClient, sessions: LockedSessions
) -> None:
    asha, ravi, mid = await pair(rt, api)

    await asha.request("match.ready", {"match_id": mid})
    end = await asha.expect("match.end", wait_s=5)
    requeued = await asha.expect("mm.requeued")
    ravi_end = await ravi.expect("match.end")

    assert end["d"]["reason"] == "aborted"
    assert end["d"]["result"] == "draw"
    assert ravi_end["d"]["reason"] == "aborted"
    assert requeued["d"]["reason"] == "opponent_not_ready"
    assert requeued["d"]["waited_s"] >= 0
    async with sessions() as db:
        match = await db.get_one(Match, uuid.UUID(mid))
    assert match.status == "aborted"
    for bot in (asha, ravi):
        await bot.close()


async def test_an_answer_at_the_deadline_is_judged_by_its_timing(
    rt: RtServer, api: AsyncClient, redis: Redis
) -> None:
    asha, ravi, mid = await pair(rt, api)
    await ready_both(asha, ravi, mid)
    show = await asha.expect("q.show")
    deadline_s = (show["d"]["deadline_at"] - show["d"]["shown_at"]) / 1000

    await until_shown(show)
    await asyncio.sleep(deadline_s - 0.05)
    on_time = await asha.request(
        "ans.submit",
        {"match_id": mid, "q": 1, "opt": show["d"]["options"][0]["id"], "el_ms": 1400},
    )
    await asyncio.sleep(0.12)
    late = await ravi.request(
        "ans.submit",
        {"match_id": mid, "q": 1, "opt": show["d"]["options"][0]["id"], "el_ms": 1500},
    )
    again = await asha.request(
        "ans.submit",
        {"match_id": mid, "q": 1, "opt": show["d"]["options"][1]["id"], "el_ms": 1400},
    )

    assert on_time["d"]["status"] == "accepted"
    assert late["d"]["status"] == "late"
    assert again["d"] == {"ref": again["d"]["ref"], "q": 1, "status": "accepted", "dup": True}
    for bot in (asha, ravi):
        await bot.close()
