"""Practice Bot games over real sockets: unrated, coin-free, and answered by the owner node."""

import uuid

from httpx import AsyncClient
from sqlalchemy import func, select

from app.modules.matches.models import Match, MatchAnswer, MatchParticipant
from app.modules.practice.models import QuestionAttempt
from app.modules.ratings.models import Rating
from tests.rt_helpers import Bot, LockedSessions, RtServer, connect_bot, sign_in, until_shown


async def play_through(bot: Bot, mid: str) -> None:
    """Ready up and answer every question with its first option."""
    ready = await bot.request("match.ready", {"match_id": mid})
    assert ready["t"] == "ack"
    await bot.expect("match.phase", lambda f: f["d"]["phase"] == "countdown")
    total = None
    q = 0
    while total is None or q < total:
        show = await bot.expect("q.show")
        q, total = show["d"]["q"], show["d"]["total"]
        await until_shown(show)
        ack = await bot.request(
            "ans.submit",
            {"match_id": mid, "q": q, "opt": show["d"]["options"][0]["id"], "el_ms": 900},
        )
        assert ack["t"] == "ans.ack"
        assert ack["d"]["status"] == "accepted"
        assert ack["ch"] == f"m:{mid}"
        assert "seq" not in ack
        await bot.expect("q.reveal", lambda f, q=q: f["d"]["q"] == q)


async def test_a_bot_game_is_unrated_and_coin_free(
    rt: RtServer, api: AsyncClient, sessions: LockedSessions
) -> None:
    login = await sign_in(api, "asha@example.com")
    player = await connect_bot(rt.url, api, login)

    await player.send(
        "mm.join",
        {"mode": "bot", "subject": "physics", "chapter": "kinematics", "idem": "j1"},
    )
    found = await player.expect("mm.found")
    mid = found["d"]["match_id"]
    snapshot = await player.expect("match.snapshot")
    await play_through(player, mid)
    end = await player.expect("match.end")
    settled = await player.expect("match.settled")

    assert found["d"]["bot"] is True
    assert found["d"]["mode"] == "bot"
    assert found["d"]["opponent"]["is_bot"] is True
    assert found["d"]["opponent"]["display_name"] == "Practice Bot"
    assert found["d"]["sources"] == [
        {"chapter": "kinematics", "name": "Motion in a Straight Line", "count": 2}
    ]
    assert snapshot["ch"] == f"m:{mid}"
    assert snapshot["d"]["phase"] == "ready_wait"
    assert snapshot["d"]["kind"] == "bot"
    assert [p["is_bot"] for p in snapshot["d"]["players"]] == [False, True]
    reveals = player.seen("q.reveal")
    assert all(r["d"]["players"][p]["speed"] is None for r in reveals for p in r["d"]["players"])
    assert end["d"]["reason"] == "normal"
    assert end["d"]["result"] in {"win", "loss", "draw"}
    assert settled["ch"] == f"m:{mid}"
    assert "seq" not in settled
    assert settled["d"]["match_id"] == mid
    assert settled["d"]["rating"] is None
    assert settled["d"]["coins"] is None
    assert settled["d"]["xp"]["delta"] == {"win": 10, "draw": 7, "loss": 4}[end["d"]["result"]]

    async with sessions() as db:
        match = await db.get_one(Match, uuid.UUID(mid))
        seats = (
            await db.scalars(select(MatchParticipant).where(MatchParticipant.match_id == match.id))
        ).all()
        answers = await db.scalar(
            select(func.count()).where(MatchAnswer.match_id == match.id)
        )
        attempts = (
            await db.scalars(select(QuestionAttempt).where(QuestionAttempt.session_id == match.id))
        ).all()
        ratings = await db.scalar(select(func.count()).select_from(Rating))
    assert match.status == "settled"
    assert match.kind == "bot"
    assert sorted(s.is_bot for s in seats) == [False, True]
    assert answers == 4  # 2 questions x 2 seats
    assert len(attempts) == 2
    assert {a.mode for a in attempts} == {"bot"}
    assert {a.speed for a in attempts} == {None}
    assert ratings == 0
    await player.close()
