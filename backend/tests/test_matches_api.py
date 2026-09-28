"""REST around live games: the Battle tab, history, results, reviews, opponents and rivals."""

import uuid
from datetime import timedelta
from typing import Any

from fastapi import FastAPI
from httpx import AsyncClient
from redis.asyncio import Redis
from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert

from app.core.clock import utc_now
from app.core.ids import new_id
from app.modules.content.models import Subject
from app.modules.matches.models import HeadToHead, Match, MatchParticipant
from app.modules.ratings.models import Rating
from app.modules.realtime import keys
from app.modules.realtime.matchmaking import tickets
from app.modules.system.models import AppConfig
from tests.helpers import bearer
from tests.rt_helpers import (
    Bot,
    LockedSessions,
    RtServer,
    connect_bot,
    search,
    sign_in,
    until_shown,
)


async def bot_match(rt: RtServer, api: AsyncClient, login: dict[str, Any]) -> tuple[Bot, str]:
    """Play a whole Practice Bot game; returns the bot connection and the match id."""
    bot = await connect_bot(rt.url, api, login)
    await bot.send(
        "mm.join", {"mode": "bot", "subject": "physics", "chapter": "kinematics", "idem": "b1"}
    )
    mid: str = (await bot.expect("mm.found"))["d"]["match_id"]
    await bot.request("match.ready", {"match_id": mid})
    for _ in range(2):
        show = await bot.expect("q.show")
        await until_shown(show)
        await bot.request(
            "ans.submit",
            {
                "match_id": mid,
                "q": show["d"]["q"],
                "opt": show["d"]["options"][1]["id"],
                "el_ms": 800,
            },
        )
        await bot.expect("q.reveal")
    await bot.expect("match.settled")
    return bot, mid


async def test_history_result_and_review_of_a_bot_game(rt: RtServer, api: AsyncClient) -> None:
    login = await sign_in(api, "asha@example.com")
    stranger = await sign_in(api, "ravi@example.com")
    bot, mid = await bot_match(rt, api, login)
    me = bearer(login["access_token"])
    settled = bot.seen("match.settled")[0]["d"]
    reveals = bot.seen("q.reveal")

    history = (await api.get("/v1/me/matches", headers=me)).json()
    result = (await api.get(f"/v1/matches/{mid}", headers=me)).json()
    review = (await api.get(f"/v1/matches/{mid}/review", headers=me)).json()
    hidden = await api.get(f"/v1/matches/{mid}", headers=bearer(stranger["access_token"]))
    hidden_review = await api.get(
        f"/v1/matches/{mid}/review", headers=bearer(stranger["access_token"])
    )

    item = history["items"][0]
    assert history["next_cursor"] is None
    assert item["id"] == mid
    assert item["kind"] == "bot"
    assert item["subject"] == "physics"
    assert item["chapters"] == ["Motion in a Straight Line"]
    assert item["result"] in {"win", "loss", "draw"}
    assert item["opponents"][0]["is_bot"] is True
    assert item["opponents"][0]["id"] == f"bot:{mid}"
    assert item["rating_delta"] is None
    assert result["status"] == "settled"
    assert result["settlement"] == settled
    assert result["totals"][login["user"]["id"]]["points"] == item["score"]["me"]
    assert len(review["questions"]) == 2
    first = review["questions"][0]
    assert first["correct"] == reveals[0]["d"]["correct"]
    assert first["ref"] == reveals[0]["d"]["ref"]
    assert [o["id"] for o in first["options"]] == [
        o["id"] for o in bot.seen("q.show")[0]["d"]["options"]
    ]
    assert (
        first["players"][login["user"]["id"]]["opt"]
        == bot.seen("q.show")[0]["d"]["options"][1]["id"]
    )
    assert first["explanation"]
    assert first["chapter"] == "Motion in a Straight Line"
    assert first["bookmarked"] is False
    assert hidden.status_code == hidden_review.status_code == 404
    await bot.close()


async def test_a_live_match_reports_live_and_has_no_review_yet(
    rt: RtServer, api: AsyncClient
) -> None:
    login = await sign_in(api, "asha@example.com")
    bot = await connect_bot(rt.url, api, login)
    await bot.send("mm.join", {"mode": "bot", "subject": "physics", "chapter": None, "idem": "l1"})
    mid = (await bot.expect("mm.found"))["d"]["match_id"]

    live = await api.get(f"/v1/matches/{mid}", headers=bearer(login["access_token"]))
    review = await api.get(f"/v1/matches/{mid}/review", headers=bearer(login["access_token"]))

    assert live.json()["status"] == "live"
    assert live.json()["result"] is None
    assert review.status_code == 409
    assert review.json()["error"]["code"] == "MATCH_NOT_OVER"
    await bot.close()


async def test_battle_setup(
    rt: RtServer, api: AsyncClient, redis: Redis, sessions: LockedSessions
) -> None:
    login = await sign_in(api, "asha@example.com")
    me = bearer(login["access_token"])
    before = (await api.get("/v1/battle/setup?goal=neet", headers=me)).json()
    bot = await connect_bot(rt.url, api, login)
    await search(bot, mode="casual", chapter="kinematics")
    async with sessions() as db:
        await db.execute(
            insert(Rating).values(
                user_id=uuid.UUID(login["user"]["id"]),
                scope="physics",
                rating=1523.4,
                rd=80,
                games=12,
            )
        )
        await db.commit()
    during = (await api.get("/v1/battle/setup?goal=neet", headers=me)).json()

    physics = next(s for s in before["subjects"] if s["slug"] == "physics")
    kinematics = next(c for c in physics["chapters"] if c["slug"] == "kinematics")
    assert [s["slug"] for s in before["subjects"]] == ["physics", "chemistry", "biology"]
    assert physics["rating"] == {"display": "—", "value": None, "provisional": True}
    assert kinematics == {
        "slug": "kinematics",
        "name": "Motion in a Straight Line",
        "battle_ready": True,
        "question_count": 8,
        "label": None,
    }
    assert before["coins"] == 0  # the wallet balance (no welcome bonus yet)
    assert before["casual_fee"] == 5
    assert before["cooldown_until"] is None
    assert before["active"] is None
    assert before["last"] is None
    assert before["first_search"] is True
    assert before["online"]["physics"] == {"searching": 0, "p50_wait_s": None}
    assert before["leaders"] is None
    during_physics = next(s for s in during["subjects"] if s["slug"] == "physics")
    assert during_physics["rating"] == {"display": "1523", "value": 1523, "provisional": False}
    assert during["active"]["kind"] == "queue"
    assert during["last"] == {"subject": "physics", "chapter": "kinematics", "mode": "casual"}
    assert during["first_search"] is False
    assert during["online"]["physics"]["searching"] == 1
    await bot.close()


async def test_battle_setup_shows_the_cooldown(
    api: AsyncClient, redis: Redis, rt_settings: Any
) -> None:
    login = await sign_in(api, "asha@example.com")
    for n in range(3):
        until = await tickets.record_abort(redis, rt_settings, login["user"]["id"], f"m{n}")

    setup = (await api.get("/v1/battle/setup", headers=bearer(login["access_token"]))).json()

    assert until is not None
    assert setup["cooldown_until"] is not None
    assert await redis.exists(keys.cooldown(login["user"]["id"]))


async def played(
    db: Any, subject_id: int, me: uuid.UUID, other: uuid.UUID, result: str, *, days_ago: int
) -> None:
    mid = new_id()
    at = utc_now() - timedelta(days=days_ago)
    db.add(
        Match(
            id=mid,
            kind="quick_rated",
            subject_id=subject_id,
            sources=[],
            chapter_ids=[],
            status="settled",
            end_reason="normal",
            config={},
            created_at=at,
            settled_at=at,
        )
    )
    await db.flush()
    other_result = {"win": "loss", "loss": "win", "draw": "draw"}[result]
    for seat, (user, outcome) in enumerate(((me, result), (other, other_result)), start=1):
        db.add(
            MatchParticipant(
                match_id=mid,
                seat=seat,
                user_id=user,
                is_bot=False,
                card={"uid": str(user)},
                result=outcome,
            )
        )
    await db.flush()


async def test_opponents_and_rivals(api: AsyncClient, sessions: LockedSessions) -> None:
    asha = await sign_in(api, "asha@example.com")
    ravi = await sign_in(api, "ravi@example.com")
    meera = await sign_in(api, "meera@example.com")
    asha_id, ravi_id, meera_id = (uuid.UUID(u["user"]["id"]) for u in (asha, ravi, meera))
    async with sessions() as db:
        subject_id = await db.scalar(select(Subject.id).where(Subject.slug == "physics"))
        for result in ("win", "win", "loss"):
            await played(db, subject_id, asha_id, ravi_id, result, days_ago=2)
        await played(db, subject_id, asha_id, meera_id, "draw", days_ago=40)
        lo, hi = sorted((asha_id, ravi_id))
        asha_wins = 2
        db.add(
            HeadToHead(
                lo=lo,
                hi=hi,
                lo_wins=asha_wins if lo == asha_id else 1,
                hi_wins=1 if lo == asha_id else asha_wins,
                draws=0,
                last_played_at=utc_now(),
            )
        )
        await db.commit()
    me = bearer(asha["access_token"])

    recent = (await api.get("/v1/me/opponents?days=30", headers=me)).json()["items"]
    older = (await api.get("/v1/me/opponents?days=60", headers=me)).json()["items"]
    rivals = (await api.get("/v1/me/rivals", headers=me)).json()["items"]

    assert [o["user"]["id"] for o in recent] == [str(ravi_id)]
    assert recent[0]["h2h"] == {"wins": 2, "losses": 1, "draws": 0}
    assert recent[0]["relationship"] == "none"
    assert recent[0]["games"] == 3
    assert {o["user"]["id"] for o in older} == {str(ravi_id), str(meera_id)}
    assert [o["user"]["id"] for o in rivals] == [str(ravi_id)]


async def test_results_stay_reachable_for_old_builds(
    app: FastAPI, api: AsyncClient, sessions: LockedSessions
) -> None:
    login = await sign_in(api, "asha@example.com")
    async with sessions() as db:
        await db.merge(AppConfig(key="min_build", value=100))
        await db.commit()
    app.state.runtime_config.clear()
    old = {**bearer(login["access_token"]), "X-App-Build": "7"}

    result = await api.get(f"/v1/matches/{uuid.uuid4()}", headers=old)
    history = await api.get("/v1/me/matches", headers=old)
    ticket = await api.post("/v1/rt/tickets", headers=old)

    assert result.status_code == 404  # not 426: a game in progress can finish
    assert history.status_code == 426
    assert ticket.status_code == 200
