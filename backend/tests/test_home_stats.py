"""``GET /v1/me/stats`` and ``GET /v1/home``: the shapes the app parses, and Home's sections
failing one at a time."""

from collections.abc import Iterator
from datetime import UTC, datetime, timedelta
from typing import Any

import pytest
from httpx import AsyncClient
from redis.asyncio import Redis
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.errors import Conflict
from app.modules.content.models import Chapter
from app.modules.home import service as home
from app.modules.leaderboards import events, keys
from app.modules.practice.models import UserChapterStats
from app.modules.ratings.models import RatingHistory
from app.modules.realtime import keys as rt_keys
from app.modules.system.models import AppConfig
from tests.social_helpers import player
from tests.test_leaderboards import give_xp, play, rate


async def test_stats_shape(client: AsyncClient, db_session: AsyncSession, redis: Redis) -> None:
    me = await player(client, "statsme")
    other = await player(client, "statsother")
    now = datetime.now(UTC)
    db = db_session
    await rate(db, me.id, 1523.4, played_at=now - timedelta(days=1))
    await rate(db, me.id, 1548, scope="physics", games=3, rd=200, played_at=now)
    await rate(db, me.id, 1500, scope="chemistry", games=0, rd=350, played_at=now)
    old = await play(db, "quick_rated", [(me.id, 50, "win"), (other.id, 10, "loss")], at=now)
    recent = await play(db, "quick_rated", [(me.id, 20, "loss"), (other.id, 60, "win")], at=now)
    await play(db, "quick_casual", [(me.id, 20, "draw"), (other.id, 20, "draw")], at=now)
    await play(db, "bot", [(me.id, 70, "win"), (None, 10, "loss")], at=now)
    for match_id, days, value in ((old, 40, 1490.0), (recent, 10, 1523.4)):
        db.add(
            RatingHistory(
                match_id=match_id,
                user_id=me.id,
                scope="overall",
                rating_before=1500,
                rd_before=90,
                rating_after=value,
                rd_after=85,
                volatility_after=0.06,
                created_at=now - timedelta(days=days),
            )
        )
    chapter = await db.scalar(select(Chapter.id).limit(1))
    assert chapter is not None
    db.add(
        UserChapterStats(user_id=me.id, chapter_id=chapter, attempts=25, correct=17, last_at=now)
    )
    await db.commit()
    await events.sync_user(db, redis, me.id, now=now)

    response = await client.get("/v1/me/stats", params={"range": "30d"}, headers=me.headers)
    assert response.status_code == 200, response.text
    body = response.json()
    assert set(body) == {
        "level", "ratings", "record", "accuracy", "questions_answered", "streak",
        "rating_history",
    }  # fmt: skip
    assert body["level"] == {"level": 1, "into_level": 0, "for_next": 100}
    assert body["ratings"] == [
        {
            "scope": "overall",
            "name": "Overall",
            "rating": {"display": "1523", "value": 1523, "provisional": False},
            "position": 1,
        },
        {
            "scope": "physics",
            "name": "Physics",
            "rating": {"display": "1548?", "value": 1548, "provisional": True},
            "position": None,
        },
    ]
    assert body["record"]["rated"] == {"wins": 1, "draws": 0, "losses": 1}
    assert body["record"]["casual"] == {"wins": 0, "draws": 1, "losses": 0}
    assert body["record"]["bot"] == {"wins": 1, "draws": 0, "losses": 0}
    assert set(body["record"]) == {"rated", "casual", "bot", "friend", "group", "tournament"}
    assert body["accuracy"] == 0.68
    assert body["questions_answered"] == 25
    assert body["streak"] == {"current": 0, "best": 0}
    assert [point["value"] for point in body["rating_history"]] == [1523]
    everything = await client.get("/v1/me/stats", params={"range": "all"}, headers=me.headers)
    assert [p["value"] for p in everything.json()["rating_history"]] == [1490, 1523]
    bad = await client.get("/v1/me/stats", params={"range": "7d"}, headers=me.headers)
    assert bad.status_code == 422

    fresh = (await client.get("/v1/me/stats", headers=other.headers)).json()
    assert fresh["accuracy"] is None
    assert fresh["ratings"] == []


async def test_home_sections(client: AsyncClient, db_session: AsyncSession, redis: Redis) -> None:
    now = datetime.now(UTC)
    db_session.add(AppConfig(key="maintenance_at", value=(now + timedelta(hours=1)).isoformat()))
    await db_session.commit()
    me = await player(client, "homeme")
    rival = await player(client, "homerival")
    await give_xp(db_session, rival.id, 40, at=now)
    await give_xp(db_session, me.id, 25, at=now)
    await db_session.commit()
    await events.sync_user(db_session, redis, rival.id, now=now)
    await events.sync_user(db_session, redis, me.id, now=now)

    response = await client.get("/v1/home", headers=me.headers)
    assert response.status_code == 200, response.text
    body = response.json()
    sections = ("hero", "live", "continue", "tip", "missions", "leaders", "tournament")
    for name in sections:
        assert body[name]["status"] == "ok", (name, body[name])
    assert body["hero"]["data"] == {
        "rating": {"display": "—", "value": None, "provisional": True},
        "rank": {"board": "rating:overall", "position": None, "games_to_rank": 10},
        "coins": 100,
        "level": {"level": 1, "into_level": 0, "for_next": 100},
    }
    assert body["live"]["data"] is None
    assert body["tournament"]["data"] is None
    missions = body["missions"]["data"]
    assert len(missions["items"]) == 3
    assert set(missions["streak"]) == {
        "days",
        "today_done",
        "freezes",
    }
    leaders = body["leaders"]["data"]
    assert leaders["board"] == "weekly_xp"
    assert [row["user"]["id"] for row in leaders["top"]] == [rival.uid, me.uid]
    assert leaders["me"]["position"] == 2
    assert leaders["me"]["value"] == 25
    assert body["welcome"] == {"coins": 100}
    banner = body["maintenance_banner"]
    assert banner is not None
    assert "IST" in banner["message"]
    assert banner["at"].endswith("Z")

    again = (await client.get("/v1/home", headers=me.headers)).json()
    assert again["welcome"] is None


@pytest.fixture
def broken_sections() -> Iterator[None]:
    saved_tip, saved_leaders = home.SECTIONS["tip"], home.SECTIONS["leaders"]

    async def boom(_ctx: home.HomeContext) -> Any:
        raise RuntimeError("the coach is down")

    async def conflict(_ctx: home.HomeContext) -> Any:
        raise Conflict("Try again.", code="BUSY")

    home.SECTIONS["tip"] = boom
    home.SECTIONS["leaders"] = conflict
    yield
    home.SECTIONS["tip"], home.SECTIONS["leaders"] = saved_tip, saved_leaders


@pytest.fixture
def tournament_provider(client: AsyncClient) -> Iterator[None]:
    # After ``client``: the app's startup installs the real tournaments provider.
    saved = home._PROVIDED["tournament"]

    async def next_cup(ctx: home.HomeContext) -> dict[str, Any]:
        return {"id": "t1", "title": "Physics Sunday Cup", "players": 5, "capacity": 8}

    home.register_home_section("tournament", next_cup)
    yield
    home.register_home_section("tournament", saved)


@pytest.mark.usefixtures("broken_sections", "tournament_provider")
async def test_home_survives_a_failing_section(client: AsyncClient, redis: Redis) -> None:
    me = await player(client, "homebroken")
    await redis.set(rt_keys.busy(me.uid), "q:ticket-1")
    response = await client.get("/v1/home", headers=me.headers)
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["tip"] == {
        "status": "error",
        "error": {"code": "INTERNAL_ERROR", "message": body["tip"]["error"]["message"]},
    }
    assert body["leaders"] == {
        "status": "error",
        "error": {"code": "BUSY", "message": "Try again."},
    }
    assert body["hero"]["status"] == "ok"
    assert body["missions"]["status"] == "ok"
    assert body["live"]["data"] == {
        "kind": "queue",
        "id": "ticket-1",
        "title": "Quick Battle",
        "action": {"route": "/battle/search", "params": {}},
        "state": None,
        "until": None,
    }
    assert body["tournament"]["data"]["title"] == "Physics Sunday Cup"
    assert body["maintenance_banner"] is None
    with pytest.raises(ValueError, match="unknown home section"):
        home.register_home_section("weather", home._nothing)


def test_maintenance_banner_window() -> None:
    now = datetime(2026, 9, 30, 10, 0, tzinfo=UTC)
    config = home.RuntimeConfig(
        min_build=0,
        maintenance=False,
        maintenance_message="Upgrading",
        maintenance_until=now + timedelta(hours=4),
        maintenance_at=now + timedelta(hours=3),
    )
    assert home.maintenance_banner(config, now) is None
    soon = home.maintenance_banner(config, now + timedelta(hours=1, minutes=30))
    assert soon == {
        "message": "Upgrading",
        "at": "2026-09-30T13:00:00Z",
        "until": "2026-09-30T14:00:00Z",
    }
    assert home.maintenance_banner(config, now + timedelta(hours=3)) is None
    assert keys.week_label(keys.week_of(now)) == "2026-W40"
