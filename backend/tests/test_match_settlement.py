"""The engine's scripts driven directly, and settlement: exactly once, hooks, retries and the
reconciler; and how a battle's questions are chosen."""

import asyncio
import time
import uuid
from collections.abc import Mapping
from datetime import timedelta
from typing import Any

import orjson
import pytest
from httpx import AsyncClient
from redis.asyncio import Redis
from sqlalchemy import func, select

from app.core.clock import utc_now
from app.core.config import Settings
from app.core.ids import new_id
from app.modules.content.models import Chapter, Question, Subject
from app.modules.matches.creation import Contender, prepare_match
from app.modules.matches.jobs import reconcile, settle_pending
from app.modules.matches.models import (
    Match,
    MatchAnswer,
    MatchKind,
    MatchParticipant,
    MatchQuestion,
)
from app.modules.matches.ports import Integrations, NoopEscrow, SettlementContext
from app.modules.matches.questions import pick_questions
from app.modules.matches.settlement import SettleDeps, settle_match
from app.modules.practice.models import QuestionAttempt, UserQuestion
from app.modules.ratings.models import Rating, RatingHistory
from app.modules.realtime import keys
from app.modules.realtime.engine import scripts
from tests.rt_helpers import LockedSessions, fast_settings, sign_in


async def two_users(api: AsyncClient) -> tuple[uuid.UUID, uuid.UUID]:
    a = await sign_in(api, "asha@example.com")
    b = await sign_in(api, "ravi@example.com")
    return uuid.UUID(a["user"]["id"]), uuid.UUID(b["user"]["id"])


async def new_match(
    sessions: LockedSessions,
    redis: Redis,
    settings: Settings,
    users: tuple[uuid.UUID, ...],
    *,
    kind: MatchKind = MatchKind.QUICK_RATED,
    holds: Mapping[uuid.UUID, str] | None = None,
) -> str:
    mid = new_id()
    async with sessions() as db:
        prepared = await prepare_match(
            db,
            settings,
            match_id=mid,
            kind=kind,
            subject_slug="physics",
            contenders=[
                Contender(
                    user_id=user,
                    chapter="kinematics",
                    joined_ms=n,
                    hold_id=(holds or {}).get(user),
                )
                for n, user in enumerate(users)
            ],
            with_bot=len(users) == 1,
        )
        await db.commit()
    await scripts.create(redis, str(mid), prepared.config, prepared.questions, ttl_s=600)
    return str(mid)


async def advance_until(redis: Redis, mid: str, *phases: str) -> scripts.Step:
    """Run the timer transitions (waiting for each due time) until one of ``phases``."""
    for _ in range(200):
        step = await scripts.advance(redis, mid, -1)
        if step.status in phases:
            return step
        now_ms = (await redis.time())[0] * 1000
        if step.due > now_ms:
            await asyncio.sleep(min(0.5, (step.due - now_ms) / 1000 + 0.01))
    raise AssertionError(f"{mid} never reached {phases}")


async def phase(redis: Redis, mid: str) -> str:
    return str(await redis.hget(keys.match(mid), "phase"))


async def answer_live(redis: Redis, mid: str, uid: uuid.UUID, q: int, *, right: bool) -> str:
    key = keys.match_question(mid, q)
    shown_at = int(await redis.hget(key, "shown_at") or 0)
    delay = shown_at / 1000 - time.time() + 0.02
    if delay > 0:
        await asyncio.sleep(delay)
    correct = str(await redis.hget(key, "correct"))
    options = [o["id"] for o in orjson.loads(await redis.hget(key, "options") or "[]")]
    opt = correct if right else next(o for o in options if o != correct)
    step = await scripts.answer(redis, mid, str(uid), q=q, opt=opt, el_ms=700)
    return step.status


async def play_rated(redis: Redis, mid: str, winner: uuid.UUID, loser: uuid.UUID) -> None:
    for uid in (winner, loser):
        await scripts.ready(redis, mid, str(uid))
    for q in (1, 2):
        await advance_until(redis, mid, "q_open")
        assert await answer_live(redis, mid, winner, q, right=True) == "accepted"
        assert await answer_live(redis, mid, loser, q, right=False) == "accepted"
        assert await phase(redis, mid) == "q_reveal"  # both answered: revealed early
    await advance_until(redis, mid, "finished")


def deps(
    redis: Redis, sessions: LockedSessions, settings: Settings, plugins: Integrations
) -> SettleDeps:
    return SettleDeps(redis=redis, sessionmaker=sessions, settings=settings, integrations=plugins)


async def counts(sessions: LockedSessions, mid: str) -> tuple[int, ...]:
    match_id = uuid.UUID(mid)
    async with sessions() as db:
        found = []
        for column in (
            MatchParticipant.match_id,
            MatchAnswer.match_id,
            QuestionAttempt.session_id,
            RatingHistory.match_id,
        ):
            found.append(int(await db.scalar(select(func.count()).where(column == match_id)) or 0))
        return tuple(found)


async def test_settlement_happens_exactly_once(
    api: AsyncClient,
    redis: Redis,
    sessions: LockedSessions,
    rt_settings: Settings,
    plugins: Integrations,
) -> None:
    asha, ravi = await two_users(api)
    mid = await new_match(sessions, redis, rt_settings, (asha, ravi))
    await play_rated(redis, mid, asha, ravi)
    settle = deps(redis, sessions, rt_settings, plugins)

    first = await settle_match(settle, mid)
    after_first = await counts(sessions, mid)
    async with sessions() as db:
        ratings = {(r.user_id, r.scope): r.rating for r in await db.scalars(select(Rating))}
    await redis.zadd(keys.SETTLE_QUEUE, {mid: 0})  # as if a retry raced the owner
    again = await settle_match(settle, mid)
    after_again = await counts(sessions, mid)
    async with sessions() as db:
        ratings_again = {(r.user_id, r.scope): r.rating for r in await db.scalars(select(Rating))}
        match = await db.get_one(Match, uuid.UUID(mid))
        seen = await db.scalar(select(func.count()).where(UserQuestion.user_id == asha))

    assert first is again is True
    assert after_first == after_again == (2, 4, 4, 4)
    assert ratings == ratings_again
    assert match.status == "settled"
    assert seen == 2
    assert not await redis.zscore(keys.SETTLE_QUEUE, mid)
    assert await redis.hget(keys.match(mid), "settled") == "1"


async def test_hooks_add_to_the_settlement_payload_inside_the_transaction(
    api: AsyncClient,
    redis: Redis,
    sessions: LockedSessions,
    rt_settings: Settings,
    plugins: Integrations,
) -> None:
    asha, ravi = await two_users(api)
    mid = await new_match(sessions, redis, rt_settings, (asha, ravi))
    await play_rated(redis, mid, asha, ravi)
    seen: list[SettlementContext] = []

    async def missions(ctx: SettlementContext) -> Mapping[uuid.UUID, Mapping[str, Any]]:
        seen.append(ctx)
        return {
            p.user_id: {
                "missions": [
                    {
                        "id": "m1",
                        "title": "Play 1 rated battle",
                        "progress": 1,
                        "target": 1,
                        "done": True,
                    }
                ],
                "streak": {"days": 3, "extended": True},
            }
            for p in ctx.players
        }

    plugins.hooks.register("missions", missions)
    await settle_match(deps(redis, sessions, rt_settings, plugins), mid)
    async with sessions() as db:
        stored = await db.scalar(
            select(MatchParticipant.settlement).where(
                MatchParticipant.match_id == uuid.UUID(mid), MatchParticipant.user_id == asha
            )
        )

    ctx = seen[0]
    assert ctx.kind == "quick_rated"
    assert ctx.status == "settled"
    assert {p.user_id: p.result for p in ctx.players} == {asha: "win", ravi: "loss"}
    assert ctx.opponents[asha] == [ravi]
    assert stored is not None
    assert stored["missions"][0]["done"] is True
    assert stored["streak"] == {"days": 3, "extended": True}
    assert stored["xp"]["delta"] == 30
    assert stored["rating"]["scope"] == "physics"
    assert plugins.hooks.names == ["xp", "missions"]


async def test_a_failed_settlement_changes_nothing_and_the_worker_retries_it(
    api: AsyncClient,
    redis: Redis,
    sessions: LockedSessions,
    plugins: Integrations,
) -> None:
    settings = fast_settings(settle_retry_after_s=0)
    asha, ravi = await two_users(api)
    mid = await new_match(sessions, redis, settings, (asha, ravi))
    await play_rated(redis, mid, asha, ravi)

    async def broken(_ctx: SettlementContext) -> Mapping[uuid.UUID, Mapping[str, Any]]:
        raise RuntimeError("ledger down")

    plugins.hooks.register("broken", broken)
    with pytest.raises(RuntimeError):
        await settle_match(deps(redis, sessions, settings, plugins), mid)
    failed = await counts(sessions, mid)
    plugins.hooks.unregister("broken")
    settled = await settle_pending(deps(redis, sessions, settings, plugins))

    assert failed == (0, 0, 0, 0)
    assert settled == 1
    assert await counts(sessions, mid) == (2, 4, 4, 4)


async def test_the_reconciler_voids_matches_redis_lost(
    api: AsyncClient,
    redis: Redis,
    sessions: LockedSessions,
    rt_settings: Settings,
) -> None:
    asha, ravi = await two_users(api)
    escrow = NoopEscrow()
    integrations = Integrations(escrow=escrow)
    async with sessions() as db:
        holds = {
            user: await escrow.hold(db, user_id=user, amount=5, key=f"h:{user}")
            for user in (asha, ravi)
        }
    mid = await new_match(
        sessions, redis, rt_settings, (asha, ravi), kind=MatchKind.QUICK_CASUAL, holds=holds
    )
    for suffix in ("", ":p", ":q:1", ":q:2"):
        await redis.delete(keys.match(mid) + suffix)  # Redis lost the game
    async with sessions() as db:
        match = await db.get_one(Match, uuid.UUID(mid))
        match.created_at = utc_now() - timedelta(hours=1)
        await db.commit()

    async with sessions() as db:
        too_soon = await reconcile(db, redis, integrations, now=utc_now() - timedelta(minutes=55))
    async with sessions() as db:
        voided = await reconcile(db, redis, integrations, now=utc_now())
    async with sessions() as db:
        match = await db.get_one(Match, uuid.UUID(mid))
        results = set(
            await db.scalars(
                select(MatchParticipant.result).where(MatchParticipant.match_id == match.id)
            )
        )

    assert too_soon == []
    assert voided == [uuid.UUID(mid)]
    assert match.status == "voided"
    assert results == {"voided"}
    assert sorted(state for _, _, state in escrow.holds.values()) == ["released", "released"]
    assert await redis.get(keys.busy(str(asha))) is None


# The state machine, script by script


async def test_everyone_away_within_the_window_voids_the_match(
    api: AsyncClient, redis: Redis, sessions: LockedSessions, rt_settings: Settings
) -> None:
    asha, ravi = await two_users(api)
    mid = await new_match(sessions, redis, rt_settings, (asha, ravi))
    for uid in (asha, ravi):
        await scripts.ready(redis, mid, str(uid))
    await advance_until(redis, mid, "q_open")

    await scripts.connection(redis, mid, str(asha), connected=False)
    await asyncio.sleep(0.3)  # within the 600 ms void window
    await scripts.connection(redis, mid, str(ravi), connected=False)
    step = await advance_until(redis, mid, "voided", "finished")

    assert step.status == "voided"


async def test_a_reconnect_before_the_grace_ends_keeps_the_game_going(
    api: AsyncClient, redis: Redis, sessions: LockedSessions, rt_settings: Settings
) -> None:
    asha, ravi = await two_users(api)
    mid = await new_match(sessions, redis, rt_settings, (asha, ravi))
    for uid in (asha, ravi):
        await scripts.ready(redis, mid, str(uid))
    await advance_until(redis, mid, "q_open")

    dropped = await scripts.connection(redis, mid, str(asha), connected=False)
    back = await scripts.connection(redis, mid, str(asha), connected=True)
    noop = await scripts.connection(redis, mid, str(asha), connected=True)
    log = [orjson.loads(fields["ev"]) for _, fields in await redis.xrange(keys.match_log(mid))]

    assert dropped.status == back.status == "ok"
    assert noop.status == "noop"
    assert [e["d"]["state"] for e in log if e["t"] == "opp.conn"] == ["reconnecting", "connected"]
    assert [e["seq"] for e in log] == list(range(1, len(log) + 1))
    assert await redis.ttl(keys.match_log(mid)) > 0  # the log expires with the match


async def test_forfeiting_before_question_1_aborts(
    api: AsyncClient, redis: Redis, sessions: LockedSessions, rt_settings: Settings
) -> None:
    asha, ravi = await two_users(api)
    mid = await new_match(sessions, redis, rt_settings, (asha, ravi))

    step = await scripts.forfeit(redis, mid, str(ravi))
    final = orjson.loads(await redis.get(keys.match_final(mid)) or "{}")

    assert step.status == "aborted"
    assert final["left"] == [str(ravi)]
    assert final["ready"] == [str(asha)]
    assert await redis.zscore(keys.SETTLE_QUEUE, mid) is not None
    assert await redis.get(keys.busy(str(asha))) is None  # free to search again


# Choosing questions


async def test_questions_nobody_has_seen_come_first(
    api: AsyncClient, sessions: LockedSessions
) -> None:
    asha, ravi = await two_users(api)
    async with sessions() as db:
        chapter = await db.scalar(select(Chapter).where(Chapter.slug == "kinematics"))
        assert chapter is not None
        pool = list(
            await db.scalars(
                select(Question.id).where(
                    Question.chapter_id == chapter.id, Question.battle_pool != "none"
                )
            )
        )
        seen = pool[:6]
        for question_id in seen:
            db.add(
                UserQuestion(
                    user_id=asha,
                    question_id=question_id,
                    attempts=1,
                    first_at=utc_now(),
                    last_at=utc_now(),
                )
            )
        await db.flush()
        picked = await pick_questions(
            db,
            subject_id=chapter.subject_id,
            sources=[(chapter.id, 2)],
            user_ids=[asha, ravi],
            goals={"neet"},
            avg_rating=1500,
        )
        more = await pick_questions(
            db,
            subject_id=chapter.subject_id,
            sources=[(chapter.id, 5)],
            user_ids=[asha, ravi],
            goals={"neet"},
            avg_rating=1500,
        )
        whole = await pick_questions(
            db,
            subject_id=chapter.subject_id,
            sources=[(chapter.id, 12)],
            user_ids=[asha],
            goals={"neet"},
            avg_rating=1500,
        )
        picked_ids = {p.question.id for p in picked}
        more_ids = {p.question.id for p in more}
        whole_ids = {p.question.id for p in whole}
        whole_chapters = {p.chapter.slug for p in whole}
        await db.rollback()

    assert picked_ids == set(pool) - set(seen)
    # Past the unseen ones it repeats rather than blocking.
    assert len(more) == 5
    assert set(pool) - set(seen) <= more_ids
    # A chapter that runs out altogether is topped up from the whole subject.
    assert len(whole) == len(whole_ids) == 12
    assert whole_chapters == {"kinematics", "laws-of-motion"}


async def test_options_get_fresh_ids_and_the_answer_stays_on_the_server(
    api: AsyncClient, redis: Redis, sessions: LockedSessions, rt_settings: Settings
) -> None:
    asha, ravi = await two_users(api)
    mid = await new_match(sessions, redis, rt_settings, (asha, ravi))
    async with sessions() as db:
        asked = list(
            await db.scalars(select(MatchQuestion).where(MatchQuestion.match_id == uuid.UUID(mid)))
        )
        subject = await db.scalar(select(Subject).where(Subject.slug == "physics"))

    for mq in asked:
        ids = mq.option_map["ids"]
        assert len(ids) == len(set(ids)) == 4
        assert all(len(i) == 5 and i.isalnum() for i in ids)
        assert sorted(mq.option_map["order"]) == [0, 1, 2, 3]
        assert mq.option_map["correct"] in ids
        assert (
            await redis.hget(keys.match_question(mid, mq.position), "correct")
            == (mq.option_map["correct"])
        )
    assert subject is not None
