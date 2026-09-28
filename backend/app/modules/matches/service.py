"""Reading matches over REST: the Battle tab, history, results, reviews and opponents.

A match is ``live`` until it ends in Redis, ``settling`` until settlement commits (results are
then read from the immutable ``m:{mid}:final``), and ``settled``, ``aborted`` or ``voided``
after that. Only players of a match can see it.
"""

import uuid
from collections import defaultdict
from datetime import UTC, datetime, timedelta
from typing import Any, Literal

import orjson
from redis.asyncio import Redis
from sqlalchemy import func, select, tuple_
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import aliased

from app.core.config import Settings
from app.core.errors import Conflict, NotFound
from app.core.pagination import decode_cursor, encode_cursor
from app.core.schemas import ApiModel, Lax
from app.modules.content.catalog import build_catalog
from app.modules.content.models import Chapter, Subject
from app.modules.content.views import bookmarked_ids, load_views
from app.modules.matches.models import (
    HeadToHead,
    Match,
    MatchAnswer,
    MatchParticipant,
    MatchQuestion,
    MatchStatus,
)
from app.modules.matches.players import load_players, rest_card
from app.modules.matches.ports import Integrations
from app.modules.matches.schemas import (
    ActiveOut,
    BattleChapterOut,
    BattleSetupOut,
    BattleSubjectOut,
    CardOut,
    MatchesOut,
    MatchItemOut,
    MatchOut,
    OnlineOut,
    OpponentOut,
    OpponentsOut,
    RatingOut,
    RecordOut,
    ReviewAnswerOut,
    ReviewOptionOut,
    ReviewOut,
    ReviewQuestionOut,
    ScoreOut,
    SelectionOut,
    TotalsOut,
)
from app.modules.practice.models import UserChapterStats
from app.modules.practice.progress import chapter_label
from app.modules.ratings.models import Rating
from app.modules.ratings.service import rating_out
from app.modules.realtime import keys, rstr
from app.modules.realtime.matchmaking.service import first_search, online_stats
from app.modules.realtime.matchmaking.tickets import cooldown_until

RIVAL_DAYS = 60
RIVAL_MIN_GAMES = 3
MAX_OPPONENTS = 50


def _ms_datetime(ms: int) -> datetime:
    return datetime.fromtimestamp(ms / 1000, UTC)


# The Battle tab


async def battle_setup(
    db: AsyncSession,
    redis: Redis,
    settings: Settings,
    integrations: Integrations,
    user_id: uuid.UUID,
    *,
    goal: str,
    now_ms: int,
) -> BattleSetupOut:
    catalog = await build_catalog(db, goal, version="")
    slugs = [subject.slug for subject in catalog.subjects]
    ratings = {
        row.scope: row
        for row in await db.scalars(
            select(Rating).where(Rating.user_id == user_id, Rating.scope.in_(slugs))
        )
    }
    labels: dict[tuple[str, str], Any] = {}
    rows = await db.execute(
        select(Subject.slug, Chapter.slug, UserChapterStats.attempts, UserChapterStats.correct)
        .join(Chapter, Chapter.id == UserChapterStats.chapter_id)
        .join(Subject, Subject.id == Chapter.subject_id)
        .where(UserChapterStats.user_id == user_id)
    )
    for subject_slug, chapter_slug, attempts, correct in rows:
        labels[(subject_slug, chapter_slug)] = chapter_label(attempts, correct)
    subjects = [
        BattleSubjectOut(
            slug=subject.slug,
            name=subject.name,
            tone=subject.tone,
            rating=RatingOut(**rating_out(ratings.get(subject.slug))),
            chapters=[
                BattleChapterOut(
                    slug=chapter.slug,
                    name=chapter.name,
                    battle_ready=chapter.battle_ready,
                    question_count=chapter.question_count,
                    label=labels.get((subject.slug, chapter.slug)),
                )
                for chapter in subject.chapters
            ],
        )
        for subject in catalog.subjects
    ]
    online = {}
    for slug in slugs:
        searching, p50 = await online_stats(redis, slug, now_ms)
        online[slug] = OnlineOut(searching=searching, p50_wait_s=p50)
    until = await cooldown_until(redis, str(user_id))
    last_raw = await rstr.get(redis, keys.last_selection(str(user_id)))
    last = None
    if last_raw is not None:
        stored = orjson.loads(last_raw)
        if stored.get("subject") in slugs and stored.get("mode") in {"rated", "casual"}:
            last = SelectionOut(**stored)
    leaders = await integrations.leaders(db, user_id, slugs)
    return BattleSetupOut(
        subjects=subjects,
        coins=await integrations.wallet(db, user_id),
        casual_fee=settings.casual_fee,
        cooldown_until=_ms_datetime(until) if until and until > now_ms else None,
        active=await _active(redis, str(user_id)),
        last=last,
        online=online,
        first_search=await first_search(db, redis, str(user_id)),
        leaders={subject: dict(row) for subject, row in leaders.items()} if leaders else None,
    )


async def _active(redis: Redis, uid: str) -> ActiveOut | None:
    busy = await rstr.get(redis, keys.busy(uid))
    if busy is None:
        return None
    kind, _, ident = busy.partition(":")
    if kind == "m":
        return ActiveOut(
            kind="match", id=ident, title="Quick Battle", action={"route": f"/battle/match/{ident}"}
        )
    if kind == "q":
        return ActiveOut(
            kind="queue", id=ident, title="Quick Battle", action={"route": "/battle/search"}
        )
    if kind == "r":
        return ActiveOut(kind="room", id=ident, title="Room", action={"route": f"/rooms/{ident}"})
    return ActiveOut(
        kind="tournament", id=ident, title="Tournament", action={"route": f"/arena/{ident}"}
    )


# History and results


class HistoryCursor(ApiModel):
    id: Lax[uuid.UUID]


def _card(card: dict[str, Any]) -> CardOut:
    return CardOut.model_validate(rest_card(card))


def _item(
    match: Match,
    subject: str,
    mine: MatchParticipant,
    seats: list[MatchParticipant],
) -> dict[str, Any]:
    others = [seat for seat in seats if seat.seat != mine.seat]
    best_other = max((seat.score for seat in others), default=None)
    return {
        "id": match.id,
        "kind": match.kind,
        "subject": subject,
        "chapters": [source["name"] for source in match.sources],
        "played_at": match.started_at or match.created_at,
        "result": mine.result,
        "reason": match.end_reason,
        "score": ScoreOut(me=mine.score, best_other=best_other),
        "opponents": [_card(seat.card) for seat in others],
        "rating_delta": mine.rating_delta,
        "coins_delta": mine.coins_delta,
        "place": mine.place if match.kind == "group" else None,
    }


async def history(
    db: AsyncSession,
    user_id: uuid.UUID,
    *,
    kind: str | None,
    cursor: str | None,
    limit: int,
) -> MatchesOut:
    """Ended matches, newest first."""
    statement = (
        select(Match, MatchParticipant, Subject.slug)
        .join(MatchParticipant, MatchParticipant.match_id == Match.id)
        .join(Subject, Subject.id == Match.subject_id)
        .where(MatchParticipant.user_id == user_id, Match.settled_at.is_not(None))
        .order_by(Match.id.desc())
        .limit(limit + 1)
    )
    if kind is not None:
        statement = statement.where(Match.kind == kind)
    if cursor is not None:
        statement = statement.where(Match.id < decode_cursor(cursor, HistoryCursor).id)
    rows = (await db.execute(statement)).all()
    page = rows[:limit]
    seats: dict[uuid.UUID, list[MatchParticipant]] = defaultdict(list)
    if page:
        for seat in await db.scalars(
            select(MatchParticipant)
            .where(MatchParticipant.match_id.in_([match.id for match, _, _ in page]))
            .order_by(MatchParticipant.seat)
        ):
            seats[seat.match_id].append(seat)
    items = [
        MatchItemOut(**_item(match, subject, mine, seats[match.id]))
        for match, mine, subject in page
    ]
    next_cursor = encode_cursor(HistoryCursor(id=page[-1][0].id)) if len(rows) > limit else None
    return MatchesOut(items=items, next_cursor=next_cursor)


async def _owned_match(
    db: AsyncSession, user_id: uuid.UUID, match_id: uuid.UUID
) -> tuple[Match, str]:
    row = (
        await db.execute(
            select(Match, Subject.slug)
            .join(Subject, Subject.id == Match.subject_id)
            .where(Match.id == match_id)
        )
    ).one_or_none()
    if row is None:
        raise NotFound("This match doesn't exist.", code="MATCH_NOT_FOUND")
    match, subject = row
    config_players = set(match.config.get("cards", {}))
    played = await db.scalar(
        select(MatchParticipant.seat).where(
            MatchParticipant.match_id == match_id, MatchParticipant.user_id == user_id
        )
    )
    if played is None and str(user_id) not in config_players:
        raise NotFound("This match doesn't exist.", code="MATCH_NOT_FOUND")
    return match, subject


async def _final(redis: Redis, match_id: uuid.UUID) -> dict[str, Any] | None:
    raw = await rstr.get(redis, keys.match_final(str(match_id)))
    return orjson.loads(raw) if raw else None


async def match_result(
    db: AsyncSession, redis: Redis, user_id: uuid.UUID, match_id: uuid.UUID
) -> MatchOut:
    match, subject = await _owned_match(db, user_id, match_id)
    if match.settled_at is not None:
        seats = list(
            await db.scalars(
                select(MatchParticipant)
                .where(MatchParticipant.match_id == match.id)
                .order_by(MatchParticipant.seat)
            )
        )
        mine = next(seat for seat in seats if seat.user_id == user_id)
        uids = {seat.seat: _seat_uid(seat) for seat in seats}
        places: dict[int, list[str]] = defaultdict(list)
        for seat in seats:
            if seat.place is not None:
                places[seat.place].append(uids[seat.seat])
        status: Literal["settled", "aborted", "voided"] = "settled"
        if match.status == MatchStatus.ABORTED:
            status = "aborted"
        elif match.status == MatchStatus.VOIDED:
            status = "voided"
        return MatchOut(
            **_item(match, subject, mine, seats),
            status=status,
            totals={
                uids[seat.seat]: TotalsOut(points=seat.score, correct=seat.correct)
                for seat in seats
            },
            ranking=[sorted(places[place]) for place in sorted(places)],
            settlement=mine.settlement,
        )
    final = await _final(redis, match.id)
    cards: dict[str, dict[str, Any]] = match.config.get("cards", {})
    me = str(user_id)
    opponents = [_card(card) for uid, card in cards.items() if uid != me]
    base: dict[str, Any] = {
        "id": match.id,
        "kind": match.kind,
        "subject": subject,
        "chapters": [source["name"] for source in match.sources],
        "played_at": match.created_at,
        "opponents": opponents,
        "rating_delta": None,
        "coins_delta": None,
        "place": None,
        "settlement": None,
    }
    if final is None:
        return MatchOut(
            **base,
            result=None,
            reason=None,
            score=ScoreOut(me=0, best_other=None),
            status="live",
            totals={},
            ranking=[],
        )
    totals = final["totals"]
    ranking: list[list[str]] = final["ranking"]
    result = final["status"] if final["status"] != "finished" else None
    if result is None and ranking:
        result = "loss"
        if me in ranking[0]:
            result = "draw" if len(ranking[0]) > 1 else "win"
    others = [int(t["points"]) for uid, t in totals.items() if uid != me]
    return MatchOut(
        **base,
        result=result,
        reason=final["reason"],
        score=ScoreOut(
            me=int(totals.get(me, {}).get("points", 0)), best_other=max(others, default=None)
        ),
        status="settling",
        totals={
            uid: TotalsOut(points=int(t["points"]), correct=int(t["correct"]))
            for uid, t in totals.items()
        },
        ranking=ranking,
    )


def _seat_uid(seat: MatchParticipant) -> str:
    return str(seat.user_id) if seat.user_id else str(seat.card.get("uid", f"seat:{seat.seat}"))


async def review(
    db: AsyncSession, redis: Redis, user_id: uuid.UUID, match_id: uuid.UUID
) -> ReviewOut:
    """Every question with the answers, explanations and bookmark state, once it has ended."""
    match, _ = await _owned_match(db, user_id, match_id)
    answers: dict[int, dict[str, ReviewAnswerOut]] = defaultdict(dict)
    if match.settled_at is not None:
        seats = {
            seat.seat: _seat_uid(seat)
            for seat in await db.scalars(
                select(MatchParticipant).where(MatchParticipant.match_id == match.id)
            )
        }
        for answer in await db.scalars(select(MatchAnswer).where(MatchAnswer.match_id == match.id)):
            answers[answer.position][seats[answer.seat]] = ReviewAnswerOut(
                opt=answer.option_id,
                correct=answer.is_correct,
                pts=answer.points,
                time_ms=answer.time_ms,
                speed=answer.speed,
            )
        revealed = max(answers, default=0)
    else:
        final = await _final(redis, match.id)
        if final is None:
            raise Conflict("The match is still being played.", code="MATCH_NOT_OVER")
        for question in final["questions"]:
            for uid in final["players"]:
                a = question["answers"].get(uid)
                result = question.get("results", {}).get(uid) or {}
                accepted = a is not None and a["status"] == "accepted"
                answers[int(question["q"])][uid] = ReviewAnswerOut(
                    opt=a["opt"] if a else None,
                    correct=bool(a and a["ok"]),
                    pts=int(a["pts"]) if a else 0,
                    time_ms=int(a["e"]) if accepted and a else None,
                    speed=result.get("speed"),
                )
        revealed = int(final["revealed"])
    asked = list(
        await db.scalars(
            select(MatchQuestion)
            .where(MatchQuestion.match_id == match.id, MatchQuestion.position <= revealed)
            .order_by(MatchQuestion.position)
        )
    )
    views = await load_views(db, [mq.question_id for mq in asked])
    bookmarked = await bookmarked_ids(db, user_id, [mq.question_id for mq in asked])
    questions = []
    for mq in asked:
        view = views[mq.question_id]
        question = view.question
        option_map = mq.option_map
        questions.append(
            ReviewQuestionOut(
                q=mq.position,
                ref=view.summary().ref,
                stem=question.stem,
                options=[
                    ReviewOptionOut(id=option_id, text=question.options[index])
                    for option_id, index in zip(option_map["ids"], option_map["order"], strict=True)
                ],
                correct=option_map["correct"],
                explanation=question.explanation,
                chapter=view.chapter.name if view.chapter else None,
                topic=view.topic.name if view.topic else None,
                players=answers.get(mq.position, {}),
                bookmarked=mq.question_id in bookmarked,
            )
        )
    return ReviewOut(questions=questions)


# Opponents and rivals


async def opponents(
    db: AsyncSession,
    integrations: Integrations,
    user_id: uuid.UUID,
    *,
    days: int,
    min_games: int = 1,
    now: datetime,
) -> OpponentsOut:
    """People (never the bot) played in settled matches of the last ``days`` days."""
    mine = aliased(MatchParticipant)
    theirs = aliased(MatchParticipant)
    rows = (
        await db.execute(
            select(theirs.user_id, func.count(), func.max(Match.settled_at))
            .select_from(mine)
            .join(theirs, (theirs.match_id == mine.match_id) & (theirs.seat != mine.seat))
            .join(Match, Match.id == mine.match_id)
            .where(
                mine.user_id == user_id,
                theirs.user_id.is_not(None),
                Match.status == MatchStatus.SETTLED.value,
                Match.settled_at >= now - timedelta(days=days),
            )
            .group_by(theirs.user_id)
            .having(func.count() >= min_games)
            .order_by(func.max(Match.settled_at).desc())
            .limit(MAX_OPPONENTS)
        )
    ).all()
    others = [other for other, _, _ in rows if other is not None]
    players = await load_players(db, others)
    pairs = [tuple(sorted((user_id, other))) for other in others]
    records = {
        (row.lo, row.hi): row
        for row in (
            await db.scalars(
                select(HeadToHead).where(tuple_(HeadToHead.lo, HeadToHead.hi).in_(pairs))
            )
            if pairs
            else []
        )
    }
    relationships = await integrations.relationships(db, user_id, others)
    items = []
    for other, games, last_played in rows:
        if other is None or other not in players:
            continue
        lo, hi = sorted((user_id, other))
        row = records.get((lo, hi))
        wins = losses = draws = 0
        if row is not None:
            wins, losses = (
                (row.lo_wins, row.hi_wins) if user_id == lo else (row.hi_wins, row.lo_wins)
            )
            draws = row.draws
        items.append(
            OpponentOut(
                user=_card(players[other].card()),
                h2h=RecordOut(wins=wins, losses=losses, draws=draws),
                relationship=relationships.get(other, "none"),
                games=int(games),
                last_played_at=last_played or now,
            )
        )
    return OpponentsOut(items=items)
