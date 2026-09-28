"""Exactly-once settlement of ended matches (``docs/plan.md``, "Exactly-once settlement").

When a match ends (finished, aborted or voided) the engine writes its immutable result to
``m:{mid}:final`` and queues it in ``settle:q``. The owner node settles at once and the worker
retries anything left behind. One Postgres transaction:

1. locks the match row and stops if it is already settled;
2. records the players, their answers, ``question_attempts`` (with speed labels and peer
   times, through the same functions as practice), seen questions, review boxes and running
   totals;
3. applies Glicko-2 to rated games (both players' pre-game values), and the head-to-head record;
4. captures, releases or pays out casual entries through the ``EscrowPort``;
5. runs the settlement hooks (XP, coins, missions, ...) and stores each player's
   ``match.settled`` payload.

After the commit each player gets ``match.settled`` (on ``ev:u:{uid}``, channel ``m:<mid>``, no
seq); aborted matches put players who were ready back in the queue and count abort strikes; and
the match's Redis keys are left to expire.
"""

import uuid
from collections.abc import Callable, Mapping, Sequence
from contextlib import AbstractAsyncContextManager
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any

import orjson
import structlog
from redis.asyncio import Redis
from sqlalchemy import select, update
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.clock import IST, redis_now_ms, utc_now
from app.core.config import Settings
from app.core.ids import new_id
from app.modules.content.models import Question, Subject
from app.modules.matches.models import (
    RATED_KINDS,
    HeadToHead,
    Match,
    MatchAnswer,
    MatchKind,
    MatchParticipant,
    MatchQuestion,
    MatchStatus,
    ParticipantResult,
)
from app.modules.matches.ports import Integrations, SettledPlayer, SettlementContext
from app.modules.practice.answers import update_user_questions
from app.modules.practice.models import Outcome, QuestionAttempt
from app.modules.practice.totals import OPPONENTS, AnswerFacts, add_to_totals
from app.modules.progression.xp import next_ist_midnight
from app.modules.ratings.service import RatingChange, apply_game
from app.modules.realtime import keys, protocol
from app.modules.realtime.engine import scripts
from app.modules.realtime.matchmaking import tickets

log = structlog.stdlib.get_logger(__name__)

SessionFactory = Callable[[], AbstractAsyncContextManager[AsyncSession]]
# How long a settled match's Redis keys stay readable (late resumes, rematches).
SETTLED_TTL_S = 3600
H2H_KINDS = frozenset(
    {MatchKind.QUICK_RATED, MatchKind.QUICK_CASUAL, MatchKind.FRIEND, MatchKind.TOURNAMENT}
)
_STATUS = {
    "finished": MatchStatus.SETTLED,
    "aborted": MatchStatus.ABORTED,
    "voided": MatchStatus.VOIDED,
}


@dataclass(frozen=True, slots=True)
class SettleDeps:
    redis: Redis
    sessionmaker: SessionFactory
    settings: Settings
    integrations: Integrations


@dataclass(slots=True)
class _Seen:
    """One recorded answer, as ``update_user_questions`` wants it."""

    question: Question
    outcome: Outcome
    answered_at: datetime
    first_try: bool = False


@dataclass(frozen=True, slots=True)
class _Outcome:
    payloads: dict[uuid.UUID, dict[str, Any]]
    requeue: list[uuid.UUID]  # ready players of an aborted quick match, holds kept


def _at(ms: int) -> datetime:
    return datetime.fromtimestamp(ms / 1000, UTC)


async def settle_match(deps: SettleDeps, mid: str) -> bool:
    """Settle one ended match; True once it is settled (now or before)."""
    raw = await deps.redis.get(keys.match_final(mid))
    if raw is None:
        await deps.redis.zrem(keys.SETTLE_QUEUE, mid)
        return False
    final: dict[str, Any] = orjson.loads(raw)
    online = await _online(deps.redis, final.get("ready", []))
    outcome: _Outcome | None = None
    async with deps.sessionmaker() as db:
        match = await db.get(Match, uuid.UUID(mid), with_for_update=True)
        if match is None:
            log.error("settlement.unknown_match", match_id=mid)
            await deps.redis.zrem(keys.SETTLE_QUEUE, mid)
            return False
        if match.settled_at is None:
            outcome = await _settle(db, deps, match, final, online, now=utc_now())
            await db.commit()
            log.info("match.settled", match_id=mid, status=match.status, reason=match.end_reason)

    if outcome is not None:
        now = await redis_now_ms(deps.redis)
        for user_id, payload in outcome.payloads.items():
            await protocol.publish_to_user(
                deps.redis,
                str(user_id),
                "match.settled",
                payload,
                ts=now,
                ch=protocol.match_channel(mid),
            )
    await _after_settlement(deps, mid, final, outcome)
    await scripts.finalize(deps.redis, mid, ttl_s=SETTLED_TTL_S)
    return True


async def _online(redis: Redis, uids: Sequence[str]) -> set[str]:
    if not uids:
        return set()
    values = await redis.mget([keys.connection(uid) for uid in uids])
    return {uid for uid, value in zip(uids, values, strict=True) if value}


def _results(final: Mapping[str, Any]) -> dict[str, tuple[str, int | None]]:
    """(result, place) per player."""
    status = final["status"]
    if status != "finished":
        return dict.fromkeys(final["players"], (status, None))
    out: dict[str, tuple[str, int | None]] = {}
    ranking: list[list[str]] = final["ranking"]
    for index, group in enumerate(ranking):
        for uid in group:
            if index == 0:
                result = ParticipantResult.DRAW if len(group) > 1 else ParticipantResult.WIN
            else:
                result = ParticipantResult.LOSS
            out[uid] = (result.value, index + 1)
    return out


async def _settle(
    db: AsyncSession,
    deps: SettleDeps,
    match: Match,
    final: Mapping[str, Any],
    online: set[str],
    *,
    now: datetime,
) -> _Outcome:
    kind = MatchKind(match.kind)
    status = final["status"]
    config = match.config
    humans = [uuid.UUID(uid) for uid in final["humans"]]
    results = _results(final)
    losers = set(final.get("losers", []))
    left = set(final.get("left", []))
    subject = await db.get_one(Subject, match.subject_id)

    match.status = _STATUS[status].value
    match.end_reason = final["reason"]
    if final.get("started_ms"):
        match.started_at = _at(int(final["started_ms"]))
    match.finished_at = _at(int(final["finished_ms"]))
    match.settled_at = now

    answered = await _record_answers(db, match, final, kind)

    ratings: dict[uuid.UUID, dict[str, RatingChange]] = {}
    if kind in RATED_KINDS and status == "finished" and len(humans) == 2 and not final.get("bot"):
        a, b = humans
        score_a = {"win": 1.0, "draw": 0.5, "loss": 0.0}[results[str(a)][0]]
        ratings = await apply_game(
            db, match_id=match.id, a=a, b=b, score_a=score_a, subject=subject.slug, now=now
        )
    if kind in H2H_KINDS and status == "finished" and len(humans) == 2:
        await _record_h2h(db, humans, results, now)

    requeue: list[uuid.UUID] = []
    if status == "aborted" and kind in {MatchKind.QUICK_RATED, MatchKind.QUICK_CASUAL}:
        tickets_by_user = config.get("tickets", {})
        requeue = [
            uuid.UUID(uid)
            for uid in final.get("ready", [])
            if uid in online and uid not in left and uid in tickets_by_user
        ]
    coins = await _move_coins(db, deps, match, final, results, keep={str(u) for u in requeue})

    cards: dict[str, Any] = config.get("cards", {})
    seats = []
    for seat, uid in enumerate(final["players"], start=1):
        result, place = results[uid]
        totals = final["totals"].get(uid, {})
        user_id = None if uid == final.get("bot") else uuid.UUID(uid)
        change = ratings.get(user_id, {}).get(subject.slug) if user_id else None
        seats.append(
            {
                "match_id": match.id,
                "seat": seat,
                "user_id": user_id,
                "is_bot": user_id is None,
                "card": cards.get(uid, {"uid": uid}),
                "result": result,
                "forfeited": uid in losers,
                "score": int(totals.get("points", 0)),
                "correct": int(totals.get("correct", 0)),
                "correct_time_ms": int(totals.get("correct_ms", 0)),
                "place": place,
                "rating_before": change.before.rating if change else None,
                "rating_after": change.after.rating if change else None,
                "rating_delta": change.delta if change else None,
                "coins_delta": coins.get(user_id) if user_id else None,
            }
        )
    await db.execute(insert(MatchParticipant).values(seats).on_conflict_do_nothing())

    players = [
        SettledPlayer(
            user_id=user_id,
            result=results[str(user_id)][0],
            score=int(final["totals"].get(str(user_id), {}).get("points", 0)),
            correct=int(final["totals"].get(str(user_id), {}).get("correct", 0)),
            answered=answered.get(user_id, 0),
            place=results[str(user_id)][1],
            forfeited=str(user_id) in losers,
            rating_delta=(ratings[user_id][subject.slug].delta if user_id in ratings else None),
        )
        for user_id in humans
    ]
    ctx = SettlementContext(
        db=db,
        match_id=match.id,
        kind=kind.value,
        status=match.status,
        reason=final["reason"],
        subject=subject.slug,
        players=players,
        has_bot=bool(final.get("bot")),
        opponents={u: [o for o in humans if o != u] for u in humans},
        coins=coins,
        now=now,
    )
    pieces = await deps.integrations.hooks.run(ctx)

    payloads: dict[uuid.UUID, dict[str, Any]] = {}
    resets_at = int(next_ist_midnight(now).timestamp() * 1000)
    for user_id in humans:
        payload: dict[str, Any] = {
            "match_id": str(match.id),
            "rating": None,
            "rank": None,
            "coins": None,
            "xp": None,
            "resets_at": resets_at,
            "missions": [],
            "streak": None,
            "achievements": [],
            "tip": None,
        }
        if user_id in ratings:
            payload["rating"] = ratings[user_id][subject.slug].settled_out()
        if user_id in coins:
            balance = await deps.integrations.wallet(db, user_id)
            if balance is not None:
                payload["coins"] = {"delta": coins[user_id], "balance": balance, "capped": False}
        payload.update(pieces.get(user_id, {}))
        payloads[user_id] = payload
        coins_piece = payload.get("coins")
        await db.execute(
            update(MatchParticipant)
            .where(MatchParticipant.match_id == match.id, MatchParticipant.user_id == user_id)
            .values(
                settlement=payload,
                coins_delta=coins_piece["delta"] if coins_piece else coins.get(user_id),
            )
        )
    await db.flush()
    return _Outcome(payloads=payloads, requeue=requeue)


async def _record_answers(
    db: AsyncSession, match: Match, final: Mapping[str, Any], kind: MatchKind
) -> dict[uuid.UUID, int]:
    """``match_answers`` for every seat and revealed question; ``question_attempts``, seen
    questions and running totals for the humans. Returns how many each human answered."""
    rows = (
        await db.execute(
            select(MatchQuestion, Question)
            .join(Question, Question.id == MatchQuestion.question_id)
            .where(MatchQuestion.match_id == match.id)
        )
    ).all()
    asked = {mq.position: (mq, question) for mq, question in rows}
    bot = final.get("bot") or ""
    seats = {uid: seat for seat, uid in enumerate(final["players"], start=1)}
    answer_rows: list[dict[str, Any]] = []
    attempts: dict[uuid.UUID, list[tuple[_Seen, dict[str, Any]]]] = {}
    answered: dict[uuid.UUID, int] = {}
    for q in final["questions"]:
        position = int(q["q"])
        if position not in asked:
            continue
        mq, question = asked[position]
        option_map = mq.option_map
        limit = int(q["limit_ms"])
        for uid in final["players"]:
            a = q["answers"].get(uid)
            res = q.get("results", {}).get(uid) or {}
            accepted = a is not None and a["status"] == "accepted"
            selected = None
            if a is not None and a["opt"] in option_map["ids"]:
                selected = option_map["order"][option_map["ids"].index(a["opt"])]
            answered_ms = int(a["recv"]) if a is not None else int(q["shown_at"]) + limit
            answer_rows.append(
                {
                    "match_id": match.id,
                    "seat": seats[uid],
                    "position": position,
                    "user_id": None if uid == bot else uuid.UUID(uid),
                    "option_id": a["opt"] if a else None,
                    "selected_option": selected,
                    "status": a["status"] if a else "timeout",
                    "is_correct": bool(a and a["ok"]),
                    "raw_ms": int(a["raw"]) if a else None,
                    "time_ms": int(a["e"]) if accepted and a else None,
                    "points": int(a["pts"]) if a else 0,
                    "speed": res.get("speed"),
                    "peer_time_ms": res.get("peer"),
                    "answered_at": _at(answered_ms),
                }
            )
            if uid == bot:
                continue
            user_id = uuid.UUID(uid)
            if accepted:
                answered[user_id] = answered.get(user_id, 0) + 1
            outcome = (
                (Outcome.CORRECT if a["ok"] else Outcome.WRONG)
                if accepted and a
                else Outcome.TIMEOUT
            )
            attempts.setdefault(user_id, []).append(
                (
                    _Seen(question=question, outcome=outcome, answered_at=_at(answered_ms)),
                    {
                        "position": position,
                        "selected_option": selected if accepted else None,
                        "time_ms": int(a["e"]) if accepted and a else limit,
                        "time_limit_ms": limit,
                        "speed": res.get("speed"),
                        "peer_time_ms": res.get("peer"),
                        "points": int(a["pts"]) if a else 0,
                    },
                )
            )
    if answer_rows:
        await db.execute(insert(MatchAnswer).values(answer_rows).on_conflict_do_nothing())
    for user_id, items in sorted(attempts.items()):
        await _write_attempts(db, user_id, match, kind, items)
    return answered


async def _write_attempts(
    db: AsyncSession,
    user_id: uuid.UUID,
    match: Match,
    kind: MatchKind,
    items: list[tuple[_Seen, dict[str, Any]]],
) -> None:
    await update_user_questions(db, user_id, [seen for seen, _ in items])
    rows = []
    facts = []
    for seen, detail in items:
        q = seen.question
        ist_day = seen.answered_at.astimezone(IST).date()
        basis = OPPONENTS if detail["speed"] is not None else None
        rows.append(
            {
                "id": new_id(),
                "answered_at": seen.answered_at,
                "user_id": user_id,
                "question_id": q.id,
                "subject_id": q.subject_id,
                "chapter_id": q.chapter_id,
                "topic_id": q.topic_id,
                "category": q.category,
                "difficulty": q.difficulty,
                "mode": kind.value,
                "session_id": match.id,
                "position": detail["position"],
                "selected_option": detail["selected_option"],
                "outcome": seen.outcome.value,
                "time_ms": detail["time_ms"],
                "time_limit_ms": detail["time_limit_ms"],
                "speed": detail["speed"],
                "speed_basis": basis,
                "peer_time_ms": detail["peer_time_ms"],
                "answer_changes": 0,
                "first_try": seen.first_try,
                "points": detail["points"],
                "ist_day": ist_day,
            }
        )
        facts.append(
            AnswerFacts(
                subject_id=q.subject_id,
                chapter_id=q.chapter_id,
                topic_id=q.topic_id,
                category=q.category,
                difficulty=q.difficulty,
                outcome=seen.outcome.value,
                time_ms=detail["time_ms"],
                speed=detail["speed"],
                speed_basis=basis,
                peer_time_ms=detail["peer_time_ms"],
                first_try=seen.first_try,
                answered_at=seen.answered_at,
                ist_day=ist_day,
            )
        )
    await db.execute(insert(QuestionAttempt).values(rows))
    await add_to_totals(db, user_id, facts)


async def _record_h2h(
    db: AsyncSession,
    humans: Sequence[uuid.UUID],
    results: Mapping[str, tuple[str, int | None]],
    now: datetime,
) -> None:
    lo, hi = sorted(humans)
    lo_result = results[str(lo)][0]
    values = {
        "lo": lo,
        "hi": hi,
        "lo_wins": int(lo_result == ParticipantResult.WIN),
        "hi_wins": int(lo_result == ParticipantResult.LOSS),
        "draws": int(lo_result == ParticipantResult.DRAW),
        "last_played_at": now,
    }
    statement = insert(HeadToHead).values(values)
    table = HeadToHead.__table__.c
    await db.execute(
        statement.on_conflict_do_update(
            index_elements=["lo", "hi"],
            set_={
                "lo_wins": table.lo_wins + statement.excluded.lo_wins,
                "hi_wins": table.hi_wins + statement.excluded.hi_wins,
                "draws": table.draws + statement.excluded.draws,
                "last_played_at": statement.excluded.last_played_at,
            },
        )
    )


async def _move_coins(
    db: AsyncSession,
    deps: SettleDeps,
    match: Match,
    final: Mapping[str, Any],
    results: Mapping[str, tuple[str, int | None]],
    *,
    keep: set[str],
) -> dict[uuid.UUID, int]:
    """Casual entries: the winner takes the pot; a draw, abort or void refunds each entry.
    Holds of players going back to the queue (``keep``) stay held for their new ticket."""
    holds: dict[str, str] = match.config.get("holds", {})
    if match.kind != MatchKind.QUICK_CASUAL or not holds:
        return {}
    escrow = deps.integrations.escrow
    fee = deps.settings.casual_fee
    mid = match.id
    coins: dict[uuid.UUID, int] = {}
    winners = [uid for uid, (result, _) in results.items() if result == ParticipantResult.WIN]
    for uid, hold_id in sorted(holds.items()):
        user_id = uuid.UUID(uid)
        if uid in keep:
            continue
        if final["status"] == "finished" and winners:
            await escrow.capture(db, hold_id=hold_id, key=f"m:{mid}:{uid}:capture")
            coins[user_id] = 0
        else:
            coins[user_id] = await escrow.release(db, hold_id=hold_id, key=f"m:{mid}:{uid}:refund")
    for uid in winners:
        if uid in holds:
            pot = fee * len(holds)
            await escrow.payout(
                db,
                user_id=uuid.UUID(uid),
                amount=pot,
                key=f"m:{mid}:{uid}:pot",
                reason="casual_win",
            )
            coins[uuid.UUID(uid)] = pot
    return coins


async def _after_settlement(
    deps: SettleDeps, mid: str, final: Mapping[str, Any], outcome: _Outcome | None
) -> None:
    """Once per match: requeue the ready players of an aborted quick match and count abort
    strikes against the players who caused it."""
    if final["status"] != "aborted" or final.get("kind") == MatchKind.BOT:
        return
    if not await deps.redis.set(keys.match_post(mid), 1, nx=True, ex=86_400):
        return
    requeued: set[str] = set()
    if outcome is not None and outcome.requeue:
        async with deps.sessionmaker() as db:
            match = await db.get_one(Match, uuid.UUID(mid))
            ticket_fields: dict[str, dict[str, str]] = match.config.get("tickets", {})
            holds: dict[str, str] = match.config.get("holds", {})
        for user_id in outcome.requeue:
            uid = str(user_id)
            if await tickets.requeue(
                deps.redis, deps.settings, ticket_fields[uid], reason="opponent_not_ready"
            ):
                requeued.add(uid)
            elif uid in holds:
                async with deps.sessionmaker() as db:
                    await deps.integrations.escrow.release(
                        db, hold_id=holds[uid], key=f"m:{mid}:{uid}:refund"
                    )
                    await db.commit()
    # A player who left, or who never got ready while away or in the background, gets a strike;
    # one who simply missed the tap while using the app doesn't.
    culprits = set(final.get("left", [])) | set(final.get("away", []))
    for uid in final.get("not_ready", []):
        connected = await deps.redis.exists(keys.connection(uid))
        background = await deps.redis.exists(keys.background(uid))
        if not connected or background:
            culprits.add(uid)
    for uid in sorted(culprits - requeued):
        await tickets.record_abort(deps.redis, deps.settings, uid, mid)
