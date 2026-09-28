"""Creating a match: its Postgres rows first, then everything the engine needs in Redis.

The ``matches`` row and ``match_questions`` (with the option maps) are written before the game
exists in Redis, so the id is known everywhere and a failure can be reconciled. This module only
prepares; ``app.modules.realtime.engine.owner.MatchEngine.start`` creates the live state.
"""

import math
import uuid
from collections import Counter
from collections.abc import Mapping, Sequence
from dataclasses import dataclass, field
from typing import Any

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import Settings
from app.modules.content.models import Chapter, Subject
from app.modules.content.refs import question_ref
from app.modules.matches.models import HeadToHead, Match, MatchKind, MatchQuestion
from app.modules.matches.players import PlayerInfo, bot_card, bot_uid, load_players
from app.modules.matches.questions import pick_questions, shuffle_options
from app.modules.practice.models import UserChapterStats
from app.modules.ratings.models import Rating
from app.modules.ratings.service import load_ratings, rating_out, to_glicko
from app.modules.realtime.bots.model import bot_accuracy
from app.modules.realtime.matchmaking import rules

MODES: Mapping[MatchKind, str] = {
    MatchKind.QUICK_RATED: "rated",
    MatchKind.QUICK_CASUAL: "casual",
    MatchKind.BOT: "bot",
}
KINDS: Mapping[str, MatchKind] = {mode: kind for kind, mode in MODES.items()}


class MatchUnavailable(Exception):
    """No questions to play (an empty subject); the tickets go back to the queue."""


@dataclass(frozen=True, slots=True)
class Contender:
    """A human about to play: what they searched for and how to put them back in the queue."""

    user_id: uuid.UUID
    chapter: str | None  # slug; None means all chapters
    joined_ms: int
    ticket_id: str | None = None
    ticket: Mapping[str, str] = field(default_factory=dict)  # the ticket's fields
    hold_id: str | None = None


@dataclass(frozen=True, slots=True)
class PreparedMatch:
    match_id: uuid.UUID
    kind: MatchKind
    subject: str
    config: dict[str, Any]  # for create.lua
    questions: list[dict[str, Any]]  # for create.lua
    found: dict[uuid.UUID, dict[str, Any]]  # each human's mm.found payload
    ttl_s: int


def max_duration_ms(settings: Settings, total: int) -> int:
    """The longest a match can run: ready, countdown, every question, and a last grace."""
    per_question = (
        settings.match_show_lead_ms
        + settings.match_limit_ms
        + settings.match_answer_grace_ms
        + settings.match_reveal_ms
    )
    return (
        settings.match_ready_ms
        + settings.match_countdown_ms
        + total * per_question
        + settings.match_grace_ms
        + settings.match_drain_grace_ms
        + settings.match_void_window_ms
    )


async def _chapters(db: AsyncSession, subject: Subject, slugs: set[str]) -> dict[str, Chapter]:
    if not slugs:
        return {}
    rows = await db.scalars(
        select(Chapter).where(
            Chapter.subject_id == subject.id, Chapter.slug.in_(slugs), Chapter.is_active
        )
    )
    return {chapter.slug: chapter for chapter in rows}


async def head_to_head(db: AsyncSession, viewer: uuid.UUID, other: uuid.UUID) -> dict[str, int]:
    """The viewer's record against ``other``."""
    lo, hi = sorted((viewer, other))
    row = await db.get(HeadToHead, (lo, hi))
    if row is None:
        return {"wins": 0, "losses": 0, "draws": 0}
    mine, theirs = (row.lo_wins, row.hi_wins) if viewer == lo else (row.hi_wins, row.lo_wins)
    return {"wins": mine, "losses": theirs, "draws": row.draws}


async def expected_accuracy(
    db: AsyncSession, user_id: uuid.UUID, chapter_ids: Sequence[int]
) -> float:
    """The user's smoothed accuracy over these chapters, (correct + 2) / (answered + 4)."""
    answered, correct = (
        await db.execute(
            select(
                func.coalesce(func.sum(UserChapterStats.attempts), 0),
                func.coalesce(func.sum(UserChapterStats.correct), 0),
            ).where(
                UserChapterStats.user_id == user_id,
                UserChapterStats.chapter_id.in_(list(chapter_ids)),
            )
        )
    ).one()
    return (int(correct) + 2) / (int(answered) + 4)


async def prepare_match(
    db: AsyncSession,
    settings: Settings,
    *,
    match_id: uuid.UUID,
    kind: MatchKind,
    subject_slug: str,
    contenders: Sequence[Contender],
    with_bot: bool = False,
    rematch_of: uuid.UUID | None = None,
    rematch_chain: int = 0,
) -> PreparedMatch:
    """Pick the questions, write the match rows (not committed) and build the live state."""
    subject = await db.scalar(select(Subject).where(Subject.slug == subject_slug))
    if subject is None:
        raise MatchUnavailable(f"unknown subject {subject_slug}")
    humans = [c.user_id for c in contenders]
    chapters = await _chapters(db, subject, {c.chapter for c in contenders if c.chapter})
    total = settings.match_questions
    if len(contenders) == 2:
        a, b = (
            rules.Ticket(
                user_id=str(c.user_id),
                rating=0.0,
                rd=0.0,
                subject=subject_slug,
                chapter=c.chapter if c.chapter in chapters else None,
                joined_ms=c.joined_ms,
                device_hash="",
            )
            for c in contenders
        )
        wanted = rules.question_sources(a, b, total)
    else:
        chapter = contenders[0].chapter
        wanted = [(chapter if chapter in chapters else None, total)]
    sources = [(chapters[slug].id if slug else None, count) for slug, count in wanted]

    ratings = await load_ratings(db, humans, subject_slug)
    avg_rating = sum(to_glicko(ratings.get(uid)).rating for uid in humans) / len(humans)
    players = await load_players(db, humans)
    picked = await pick_questions(
        db,
        subject_id=subject.id,
        sources=sources,
        user_ids=humans,
        goals={players[uid].goal for uid in humans if uid in players},
        avg_rating=avg_rating,
    )
    if not picked:
        raise MatchUnavailable(f"no battle questions in {subject_slug}")

    counts = Counter(p.chapter.id for p in picked)
    by_id = {p.chapter.id: p.chapter for p in picked}
    requested = [cid for cid, _ in sources if cid is not None and cid in counts]
    ordered = [*requested, *(cid for cid in counts if cid not in requested)]
    shown_sources = [
        {
            "chapter_id": cid,
            "chapter": by_id[cid].slug,
            "name": by_id[cid].name,
            "count": counts[cid],
        }
        for cid in ordered
    ]

    bot = bot_uid(match_id) if with_bot else ""
    accuracy = 0.0
    if with_bot:
        scope_ids = [cid for cid, _ in sources if cid is not None] or list(counts)
        accuracy = bot_accuracy(await expected_accuracy(db, humans[0], scope_ids))

    live_questions = []
    for position, item in enumerate(picked, start=1):
        options = shuffle_options(item.question)
        db.add(
            MatchQuestion(
                match_id=match_id,
                position=position,
                question_id=item.question.id,
                option_map=options.option_map(),
            )
        )
        live_questions.append(
            {
                "stem": item.question.stem,
                "options": [
                    {"id": option_id, "text": item.question.options[index]}
                    for option_id, index in zip(options.ids, options.order, strict=True)
                ],
                "correct": options.correct,
                "ref": question_ref(item.question.id),
                "limit_ms": settings.match_limit_ms,
                "chapter": item.chapter.name,
            }
        )

    cards: dict[str, dict[str, Any]] = {str(uid): _card(players, uid) for uid in humans}
    if with_bot:
        cards[bot] = bot_card(match_id)
    longest = max_duration_ms(settings, len(picked))
    db.add(
        Match(
            id=match_id,
            kind=kind.value,
            subject_id=subject.id,
            sources=shown_sources,
            chapter_ids=ordered,
            config={
                "mode": MODES.get(kind, kind.value),
                "total": len(picked),
                "limit_ms": settings.match_limit_ms,
                "reveal_ms": settings.match_reveal_ms,
                "grace_ms": settings.match_grace_ms,
                "max_duration_ms": longest,
                "cards": cards,
                "requested": [{"chapter": c.chapter, "joined_ms": c.joined_ms} for c in contenders],
                "tickets": {str(c.user_id): dict(c.ticket) for c in contenders if c.ticket},
                "holds": {str(c.user_id): c.hold_id for c in contenders if c.hold_id},
                "bot_accuracy": accuracy if with_bot else None,
                "rematch_of": str(rematch_of) if rematch_of else None,
                "rematch_chain": rematch_chain,
            },
        )
    )
    await db.flush()

    players_order = [str(uid) for uid in humans] + ([bot] if with_bot else [])
    found: dict[uuid.UUID, dict[str, Any]] = {}
    for uid in humans:
        if with_bot:
            opponent: dict[str, Any] = bot_card(match_id)
        else:
            other = next(o for o in humans if o != uid)
            opponent = {
                **_card(players, other),
                "rating": rating_out(ratings.get(other)),
                "record": await head_to_head(db, uid, other),
            }
        found[uid] = {
            "match_id": str(match_id),
            "ch": f"m:{match_id}",
            "mode": MODES.get(kind, kind.value),
            "opponent": opponent,
            "sources": [
                {"chapter": s["chapter"], "name": s["name"], "count": s["count"]}
                for s in shown_sources
            ],
            "bot": with_bot,
        }
    return PreparedMatch(
        match_id=match_id,
        kind=kind,
        subject=subject_slug,
        config={
            "id": str(match_id),
            "kind": kind.value,
            "mode": MODES.get(kind, kind.value),
            "subject": subject_slug,
            "players": players_order,
            "humans": [str(uid) for uid in humans],
            "bot": bot,
            "bot_acc": accuracy,
            "cards": cards,
            "meta": {"rematch_chain": rematch_chain},
            "ready_ms": settings.match_ready_ms,
            "reveal_ms": settings.match_reveal_ms,
            "countdown_ms": settings.match_countdown_ms,
            "show_lead_ms": settings.match_show_lead_ms,
            "answer_grace_ms": settings.match_answer_grace_ms,
            "grace_ms": settings.match_grace_ms,
            "void_window_ms": settings.match_void_window_ms,
        },
        questions=live_questions,
        found=found,
        ttl_s=math.ceil(longest / 1000) + 3600,
    )


def _card(players: Mapping[uuid.UUID, PlayerInfo], user_id: uuid.UUID) -> dict[str, Any]:
    info = players.get(user_id)
    if info is None:  # a deleted account: still a player of this match
        return {
            "uid": str(user_id),
            "handle": None,
            "display_name": "Player",
            "avatar": {"tone": "lime", "symbol": "rocket"},
            "level": 1,
            "is_bot": False,
        }
    return info.card()


async def subject_rating(db: AsyncSession, user_id: uuid.UUID, subject: str) -> Rating | None:
    return (await load_ratings(db, [user_id], subject)).get(user_id)
