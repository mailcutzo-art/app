"""Rooms: creating them, the settings, who may join, previews by code, and the Postgres record.

A room is created over REST (``create_room``); everything after is live on the socket
(``app.modules.realtime.rooms``). The rules that need Postgres live here so both sides share
them:

- **Settings.** A friend duel picks a subject, one chapter or All, 5/7/10 questions and
  10/15/20/30 s; a group battle adds several chapters, 5/10/15/20 questions, difficulty, late
  join (until halfway, or off), the leaderboard between questions and who can join (friends of
  the host, or anyone with the code).
- **Who may join.** Nobody who blocked (or was blocked by) someone in the room; for a friends-
  only group, friends of the host and players whose invite was accepted. Kicks, the lock and
  capacity (2 or 8) are checked atomically by the join script.
- **Busy.** The player's busy slot must be free, and no registered busy check (tournaments)
  may need them before the room's longest game could end.
- **Code guesses** by user: 5 wrong a minute and 30 an hour, then every lookup is refused
  until the limit has passed.
"""

import math
import uuid
from collections.abc import Mapping
from datetime import datetime, timedelta
from typing import Any

import orjson
import structlog
from redis.asyncio import Redis
from sqlalchemy import select, update
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import Settings
from app.core.errors import (
    AppError,
    Conflict,
    Forbidden,
    NotFound,
    RateLimited,
    ServiceUnavailable,
    ValidationFailed,
)
from app.core.ids import new_id
from app.core.ratelimit import consume
from app.modules.content.models import Chapter, Subject
from app.modules.matches.creation import GameRules, _card, max_duration_ms
from app.modules.matches.players import load_players
from app.modules.matches.schemas import ActiveOut
from app.modules.notifications.service import notify
from app.modules.realtime import keys, protocol, rstr
from app.modules.realtime.engine import scripts
from app.modules.realtime.matchmaking.service import battle_ready, searches_closed
from app.modules.rooms import codes, live
from app.modules.rooms.busy import active_of, busy_elsewhere
from app.modules.rooms.models import (
    InviteStatus,
    Room,
    RoomInvite,
    RoomKick,
    RoomKind,
    RoomMember,
)
from app.modules.rooms.schemas import RoomCreatedOut, RoomPreviewOut, RoomSettingsIn
from app.modules.social.cards import cards
from app.modules.social.relations import are_blocked, are_friends
from app.modules.system.runtime import load_runtime_config

log = structlog.stdlib.get_logger(__name__)

# Redis keys (and members' busy slots) of a room outlive a whole idle lobby comfortably; any
# activity renews them.
ROOM_TTL_S = 6 * 3600
CAPACITY = {RoomKind.FRIEND: 2, RoomKind.GROUP: 8}
QUESTIONS = {RoomKind.FRIEND: (5, 7, 10), RoomKind.GROUP: (5, 10, 15, 20)}
DEFAULT_QUESTIONS = {RoomKind.FRIEND: 7, RoomKind.GROUP: 10}
SECONDS = (10, 15, 20, 30)
DEFAULT_SECONDS = 15
MAX_GROUP_CHAPTERS = 12
CODE_ATTEMPTS = 8
# Wrong code guesses per user: (bucket, capacity, per second).
GUESS_LIMITS = (("min", 5, 5 / 60), ("hour", 30, 30 / 3600))


class Busy(Conflict):
    """``409 BUSY`` with where the player is in ``details.active``."""

    default_code = "BUSY"
    default_message = "You're already in a game."

    def __init__(self, active: ActiveOut, message: str | None = None) -> None:
        super().__init__(message, details={"active": active.model_dump(mode="json")})
        self.active = active


class NotAllowed(Forbidden):
    default_code = "NOT_ALLOWED"
    default_message = "You can't do that."


class RoomNotFound(NotFound):
    default_code = "ROOM_NOT_FOUND"
    default_message = "That code isn't active. Ask for a new one."


class Gone(AppError):
    http_status = 410
    default_code = "GONE"
    default_message = "This is no longer available."


class SettingsInvalid(ValidationFailed):
    def __init__(self, field: str, message: str) -> None:
        super().__init__(message, details={"fields": {field: message}})


# Settings


async def resolve_settings(db: AsyncSession, kind: RoomKind, raw: RoomSettingsIn) -> dict[str, Any]:
    """The room's settings with defaults filled in, or ``SettingsInvalid``."""
    subject = await db.scalar(select(Subject).where(Subject.slug == raw.subject))
    if subject is None:
        raise SettingsInvalid("subject", "Pick a subject.")
    chapters = list(dict.fromkeys(raw.chapters or ([raw.chapter] if raw.chapter else [])))
    if kind == RoomKind.FRIEND and len(chapters) > 1:
        raise SettingsInvalid("chapters", "A friend duel is one chapter or all of them.")
    if len(chapters) > MAX_GROUP_CHAPTERS:
        raise SettingsInvalid("chapters", "Pick fewer chapters, or all of them.")
    if chapters:
        found = {
            row.slug: row
            for row in await db.scalars(
                select(Chapter).where(
                    Chapter.subject_id == subject.id, Chapter.slug.in_(chapters), Chapter.is_active
                )
            )
        }
        for slug in chapters:
            row = found.get(slug)
            if row is None or not await battle_ready(db, subject.id, row.id):
                raise SettingsInvalid("chapters", "That chapter isn't available for battles.")
    questions = raw.questions if raw.questions is not None else DEFAULT_QUESTIONS[kind]
    if questions not in QUESTIONS[kind]:
        allowed = ", ".join(str(n) for n in QUESTIONS[kind])
        raise SettingsInvalid("questions", f"Choose {allowed} questions.")
    seconds = raw.seconds if raw.seconds is not None else DEFAULT_SECONDS
    if seconds not in SECONDS:
        raise SettingsInvalid("seconds", "Choose 10, 15, 20 or 30 seconds.")
    group = kind == RoomKind.GROUP
    if not group and (
        raw.difficulty not in {None, "mixed"}
        or raw.late_join
        or raw.leaderboard
        or raw.join not in {None, "anyone"}
    ):
        raise SettingsInvalid("settings", "Friend duels only pick the questions and the time.")
    return {
        "subject": subject.slug,
        "chapters": chapters or None,
        "questions": questions,
        "seconds": seconds,
        "difficulty": (raw.difficulty or "mixed") if group else "mixed",
        "late_join": (raw.late_join if raw.late_join is not None else True) if group else False,
        "leaderboard": (raw.leaderboard if raw.leaderboard is not None else True)
        if group
        else False,
        "join": (raw.join or "anyone") if group else "anyone",
    }


def reveal_ms(settings: Settings, kind: str, room_settings: Mapping[str, Any]) -> int:
    """3 s, or 4 s in a group battle showing the leaderboard between questions."""
    if kind == RoomKind.GROUP and room_settings.get("leaderboard"):
        return settings.room_group_reveal_ms
    return settings.match_reveal_ms


def limit_ms(settings: Settings, room_settings: Mapping[str, Any]) -> int:
    return max(1100, round(int(room_settings["seconds"]) * 1000 * settings.room_time_scale))


def grace_ms(settings: Settings, kind: str) -> int:
    """A friend duel gives a dropped player 60 s; a group battle never forfeits anyone."""
    return settings.room_friend_grace_ms if kind == RoomKind.FRIEND else settings.match_grace_ms


def longest_game_ms(settings: Settings, kind: str, room_settings: Mapping[str, Any]) -> int:
    return max_duration_ms(
        settings,
        int(room_settings["questions"]),
        limit_ms=limit_ms(settings, room_settings),
        reveal_ms=reveal_ms(settings, kind, room_settings),
        grace_ms=grace_ms(settings, kind),
    )


def game_rules(
    settings: Settings, rid: str, kind: str, room_settings: Mapping[str, Any]
) -> GameRules:
    """The engine's settings for one game of this room."""
    total = int(room_settings["questions"])
    chapters: list[str] = room_settings.get("chapters") or []
    sources: list[tuple[str | None, int]]
    if chapters:
        # Spread evenly; the first chapters take the remainder.
        base, spare = divmod(total, len(chapters))
        sources = [
            (slug, base + (1 if index < spare else 0)) for index, slug in enumerate(chapters)
        ]
        sources = [(slug, count) for slug, count in sources if count > 0]
    else:
        sources = [(None, total)]
    difficulty = room_settings.get("difficulty")
    group = kind == RoomKind.GROUP
    extra: dict[str, Any] = {"room": rid, "room_ttl": ROOM_TTL_S}
    if group:
        extra.update(
            {
                "rules": "group",
                "short_ms": settings.room_group_short_ms,
                "short_until": 0,
                "standings": "1" if room_settings.get("leaderboard") else "0",
                "late_join": "1" if room_settings.get("late_join") else "0",
            }
        )
    return GameRules(
        total=total,
        limit_ms=limit_ms(settings, room_settings),
        reveal_ms=reveal_ms(settings, kind, room_settings),
        grace_ms=grace_ms(settings, kind),
        sources=sources,
        difficulty=None if difficulty in {None, "mixed"} else difficulty,
        extra=extra,
        config={"room_id": rid, "room_settings": dict(room_settings)},
    )


def room_link(settings: Settings, code: str) -> str:
    return f"{settings.public_url.rstrip('/')}/j/{code}"


async def socket_card(db: AsyncSession, user_id: uuid.UUID) -> dict[str, Any]:
    """The player card as the socket shows it."""
    return _card(await load_players(db, [user_id]), user_id)


# Creating a room


async def ensure_open(db: AsyncSession, settings: Settings, now: datetime) -> None:
    """New rooms and games stop during (and 10 minutes before) maintenance."""
    if searches_closed(await load_runtime_config(db, settings), now):
        raise ServiceUnavailable("Battles are paused for maintenance.", code="UNAVAILABLE")


async def create_room(
    db: AsyncSession,
    redis: Redis,
    settings: Settings,
    user_id: uuid.UUID,
    kind: RoomKind,
    raw: RoomSettingsIn,
    *,
    now: datetime,
) -> RoomCreatedOut:
    """A new lobby with ``user_id`` as host (their busy slot becomes the room)."""
    room_settings = await resolve_settings(db, kind, raw)
    until = now + timedelta(milliseconds=longest_game_ms(settings, kind, room_settings))
    active = await busy_elsewhere(db, redis, user_id, until=until)
    if active is not None:
        raise Busy(active)
    card = await socket_card(db, user_id)
    rid = new_id()
    for _ in range(CODE_ATTEMPTS):
        code = codes.new_code()
        try:
            async with db.begin_nested():
                db.add(
                    Room(
                        id=rid,
                        code=code,
                        kind=kind.value,
                        created_by=user_id,
                        settings=room_settings,
                        created_at=now,
                    )
                )
                await db.flush()
        except IntegrityError:
            continue  # an open room has this code
        outcome = await live.create(
            redis,
            str(rid),
            {
                "id": str(rid),
                "kind": kind.value,
                "code": code,
                "host": str(user_id),
                "card": card,
                "settings": orjson.dumps(room_settings).decode(),
                "capacity": CAPACITY[kind],
                "idle_ms": settings.room_idle_ms,
                "handover_ms": settings.room_handover_ms,
                "host_left_ms": settings.room_host_left_ms,
                "autostart_ms": settings.room_autostart_ms,
                "rematch_ms": settings.room_rematch_ms,
                "again_ms": settings.room_again_ms,
                "rematch_max": settings.room_rematch_max,
                "ttl": ROOM_TTL_S,
            },
        )
        if outcome.status == "code_taken":
            await db.delete(await db.get_one(Room, rid))
            await db.flush()
            continue
        if outcome.status == "busy":
            raise Busy(await active_of(redis, outcome.detail))
        if outcome.status != "ok":
            raise Conflict("That room already exists.")
        db.add(RoomMember(room_id=rid, user_id=user_id, joined_at=now))
        await db.flush()
        log.info("room.created", room_id=str(rid), kind=kind.value, user_id=str(user_id))
        return RoomCreatedOut(
            room_id=rid,
            code=code,
            link=room_link(settings, code),
            expires_at=now + timedelta(milliseconds=settings.room_idle_ms),
        )
    raise ServiceUnavailable("Couldn't make a room code. Please try again.", code="UNAVAILABLE")


# Who may join


async def join_refusal(
    db: AsyncSession, state: Mapping[str, Any], user_id: uuid.UUID
) -> str | None:
    """``blocked`` or ``friends_only`` when Postgres says no (the rest is the script's)."""
    members = [uuid.UUID(member["uid"]) for member in state["members"]]
    if user_id in members:
        return None
    for member in members:
        if await are_blocked(db, user_id, member):
            return "blocked"
    settings = state["settings"]
    host = uuid.UUID(state["host"])
    if settings.get("join") == "friends" and not await are_friends(db, user_id, host):
        invited = await db.scalar(
            select(RoomInvite.id).where(
                RoomInvite.room_id == uuid.UUID(state["room_id"]),
                RoomInvite.to_id == user_id,
                RoomInvite.status == InviteStatus.ACCEPTED.value,
            )
        )
        if invited is None:
            return "friends_only"
    return None


async def late_join_mode(redis: Redis, state: Mapping[str, Any]) -> str | None:
    """While a game runs: ``player`` (a group battle before halfway with late join on),
    ``spectator`` (a group battle after that), or None (a friend duel: nobody new)."""
    if state["kind"] != RoomKind.GROUP:
        return None
    mid = state.get("match_id")
    if not mid:
        return "spectator"
    q, total, phase = await rstr.hmget(redis, keys.match(mid), ["q", "total", "phase"])
    if phase is None or not state["settings"].get("late_join"):
        return "spectator"
    return "player" if int(q or 0) <= int(total or 0) // 2 else "spectator"


# Previews and code guesses


async def _guess_block(redis: Redis, user_id: uuid.UUID) -> int:
    ttl = await redis.pttl(f"rooms:guess_block:{user_id}")
    return math.ceil(ttl / 1000) if ttl and ttl > 0 else 0


async def check_guesses(redis: Redis, user_id: uuid.UUID) -> None:
    """Refuse lookups while the user is over the wrong-code limit."""
    retry = await _guess_block(redis, user_id)
    if retry:
        raise RateLimited(retry, "Too many wrong codes. Try again in a moment.")


async def wrong_guess(redis: Redis, user_id: uuid.UUID) -> int:
    """Count a wrong code; returns seconds to wait if that crossed a limit (else 0)."""
    wait_ms = 0
    for name, capacity, rate in GUESS_LIMITS:
        decision = await consume(
            redis, f"rl:rooms.code:{name}:{user_id}", capacity=capacity, refill_per_sec=rate
        )
        if not decision.allowed:
            wait_ms = max(wait_ms, decision.retry_after_ms)
    if wait_ms:
        await redis.set(f"rooms:guess_block:{user_id}", 1, px=wait_ms)
    return math.ceil(wait_ms / 1000)


async def room_by_code(redis: Redis, user_id: uuid.UUID, raw: str) -> str:
    """The id of the open room with this code; wrong codes count toward the guess limit."""
    await check_guesses(redis, user_id)
    code = codes.normalize(raw)
    rid = await rstr.get(redis, keys.room_code(code)) if code else None
    if rid is None:
        wait_s = await wrong_guess(redis, user_id)
        if wait_s:
            raise RateLimited(wait_s, "Too many wrong codes. Try again in a moment.")
        raise RoomNotFound()
    return rid


async def preview(db: AsyncSession, redis: Redis, user_id: uuid.UUID, code: str) -> RoomPreviewOut:
    rid = await room_by_code(redis, user_id, code)
    current = await live.read(redis, rid)
    if current is None or current["status"] == "closed":
        raise RoomNotFound()
    state = current["state"]
    room_settings = state["settings"]
    host = uuid.UUID(state["host"])
    host_card = (await cards(db, [host])).get(host)
    member_ids = {member["uid"] for member in state["members"]}
    reason: str | None = None
    if str(user_id) not in member_ids:
        if await redis.sismember(f"{keys.room(rid)}:k", str(user_id)):
            reason = "kicked"
        elif state["locked"]:
            reason = "locked"
        elif len(member_ids) >= state["capacity"]:
            reason = "full"
        elif current["status"] in {"playing", "starting"} and (
            await late_join_mode(redis, state) != "player"
        ):
            reason = "started"
        else:
            reason = await join_refusal(db, state, user_id)
    return RoomPreviewOut(
        room_id=uuid.UUID(rid),
        kind=state["kind"],
        code=state["code"],
        host=host_card,
        subject=room_settings["subject"],
        chapters=room_settings.get("chapters"),
        questions=room_settings["questions"],
        seconds=room_settings["seconds"],
        members=len(member_ids),
        capacity=state["capacity"],
        joinable=reason is None,
        reason=reason,  # type: ignore[arg-type]
    )


# The Postgres record (written by whoever changes the live room)


async def record_join(db: AsyncSession, rid: str, user_id: uuid.UUID, now: datetime) -> None:
    await db.execute(
        insert(RoomMember)
        .values(room_id=uuid.UUID(rid), user_id=user_id, joined_at=now)
        .on_conflict_do_update(
            index_elements=[RoomMember.room_id, RoomMember.user_id], set_={"left_at": None}
        )
    )


async def record_leave(db: AsyncSession, rid: str, user_id: uuid.UUID, now: datetime) -> None:
    await db.execute(
        update(RoomMember)
        .where(RoomMember.room_id == uuid.UUID(rid), RoomMember.user_id == user_id)
        .values(left_at=now)
    )


async def record_kick(
    db: AsyncSession, rid: str, user_id: uuid.UUID, by: uuid.UUID, now: datetime
) -> None:
    await record_leave(db, rid, user_id, now)
    await db.execute(
        insert(RoomKick)
        .values(room_id=uuid.UUID(rid), user_id=user_id, kicked_by=by, created_at=now)
        .on_conflict_do_nothing()
    )


async def record_settings(db: AsyncSession, rid: str, room_settings: Mapping[str, Any]) -> None:
    await db.execute(
        update(Room).where(Room.id == uuid.UUID(rid)).values(settings=dict(room_settings))
    )


async def record_game(db: AsyncSession, rid: str) -> None:
    await db.execute(update(Room).where(Room.id == uuid.UUID(rid)).values(games=Room.games + 1))


async def record_close(
    db: AsyncSession, redis: Redis, rid: str, reason: str, now: datetime
) -> None:
    """The room closed: its code is free again, members left, and pending invites expire
    (both sides get ``invite.updated``)."""
    room_id = uuid.UUID(rid)
    await db.execute(
        update(Room)
        .where(Room.id == room_id, Room.closed_at.is_(None))
        .values(closed_at=now, close_reason=reason)
    )
    await db.execute(
        update(RoomMember)
        .where(RoomMember.room_id == room_id, RoomMember.left_at.is_(None))
        .values(left_at=now)
    )
    expired = await db.scalars(
        update(RoomInvite)
        .where(RoomInvite.room_id == room_id, RoomInvite.status == InviteStatus.PENDING.value)
        .values(status=InviteStatus.EXPIRED.value, responded_at=now)
        .returning(RoomInvite)
    )
    for invite in expired.all():
        for user_id in (invite.from_id, invite.to_id):
            await protocol.publish_to_user(
                redis,
                str(user_id),
                "invite.updated",
                {"invite_id": str(invite.id), "status": invite.status},
                ts=int(now.timestamp() * 1000),
            )
    log.info("room.closed", room_id=rid, reason=reason)


async def leave_room(
    db: AsyncSession,
    redis: Redis,
    rid: str,
    user_id: uuid.UUID,
    *,
    now: datetime,
    kicked_by: uuid.UUID | None = None,
) -> tuple[live.Outcome, scripts.Step | None]:
    """Take a member out of the room (and out of its running game: a friend duel is
    forfeited, a group battle just loses the player), with the Postgres record. Returns the
    room script's outcome and the match step, if the player was playing."""
    uid = str(user_id)
    current = await live.read(redis, rid)
    step = None
    mid = current["match"] if current else ""
    if mid and await rstr.get(redis, keys.busy(uid)) == f"m:{mid}":
        step = await scripts.forfeit(redis, mid, uid)
    outcome = await live.leave(redis, rid, uid, kicked=kicked_by is not None)
    if outcome.status == "not_member":
        return outcome, step
    if kicked_by is not None:
        await record_kick(db, rid, user_id, kicked_by, now)
    else:
        await record_leave(db, rid, user_id, now)
    if outcome.status == "closed":
        await record_close(db, redis, rid, outcome.detail, now)
    return outcome, step


async def notify_host_joined(
    db: AsyncSession, state: Mapping[str, Any], joiner: Mapping[str, Any]
) -> None:
    """The host hears that someone came in, even with the app in the background."""
    host = uuid.UUID(state["host"])
    name = joiner.get("display_name") or "A player"
    await notify(
        db,
        host,
        kind="invite",
        title=f"{name} joined your room",
        body="Come back to the lobby to start the game.",
        icon="battle",
        action={"route": f"/rooms/{state['room_id']}", "params": {}},
        key=f"room_joined:{state['room_id']}:{joiner['uid']}",
        time_critical=True,  # the host's own room, waiting for them
    )
