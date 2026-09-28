"""The Arena for players: cards, detail, standings, registration, withdrawal and check-in
(docs/api-play.md, "Tournaments"), plus what other features read (the busy check, Home's next
tournament and the Hall of Fame).

Registration, withdrawal and check-in lock the tournament row first, then the wallet (the lock
order of every tournament step), so the field and the held fees never disagree.
"""

import uuid
from collections.abc import Sequence
from datetime import UTC, datetime, timedelta
from typing import Any

from redis.asyncio import Redis
from sqlalchemy import and_, func, or_, select, tuple_
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import Settings
from app.core.errors import Conflict, Forbidden, NotFound
from app.core.pagination import decode_cursor, encode_cursor
from app.core.schemas import ApiModel, Lax
from app.modules.content.catalog import DEFAULT_GOAL
from app.modules.content.models import Subject
from app.modules.economy.models import CoinReason, HoldStatus, RefKind
from app.modules.economy.service import Ref, hold, locked_hold, release_hold
from app.modules.matches.players import load_players, rest_card
from app.modules.matches.schemas import ActiveOut
from app.modules.progression.models import XpEvent
from app.modules.tournaments import events, rules
from app.modules.tournaments.models import (
    TERMINAL,
    PairingStatus,
    RoundStatus,
    Tournament,
    TournamentEntry,
    TournamentPairing,
    TournamentPrize,
    TournamentRound,
    TournamentStatus,
)
from app.modules.tournaments.prizes import (
    FULL_POOL_ENTRANTS,
    MAX_ENTRANTS,
    MIN_ENTRANTS,
    distribute,
)
from app.modules.tournaments.standings_view import points_out
from app.modules.users.models import User

S = TournamentStatus
ALL_TONE = "lime"  # the card colour of an all-subjects tournament
ACTIVE_STATES = (S.REG_OPEN, S.CHECK_IN, S.LOCKED, S.RUNNING, S.FINALIZING)


class TournamentFull(Conflict):
    default_code = "TOURNAMENT_FULL"
    default_message = "This tournament is full."


class RegistrationClosed(Conflict):
    default_code = "REGISTRATION_CLOSED"
    default_message = "Registration for this tournament is closed."


class ScheduleConflict(Conflict):
    default_code = "SCHEDULE_CONFLICT"
    default_message = "You're already in a tournament at that time."


class CheckInClosed(Conflict):
    default_code = "CHECK_IN_CLOSED"
    default_message = "Check-in is open from 15 to 2 minutes before the start."


class NotRegistered(Conflict):
    default_code = "NOT_REGISTERED"
    default_message = "You're not registered for this tournament."


class NotAllowed(Forbidden):
    default_code = "NOT_ALLOWED"


# --- Shapes --------------------------------------------------------------------------------


async def subjects_by_id(db: AsyncSession) -> dict[int, Subject]:
    return {s.id: s for s in await db.scalars(select(Subject))}


def shown_effective_pool(pool: int, players: int) -> int:
    """What the pool pays with this many players: pool * min(1, players / 32)."""
    return pool * min(max(players, 0), FULL_POOL_ENTRANTS) // FULL_POOL_ENTRANTS


def shown_rounds(t: Tournament) -> int:
    if t.rounds_planned is not None:
        return t.rounds_planned
    return rules.rounds_for(t.rounds, t.players) if t.players >= 2 else t.rounds


def ends_at_estimate(t: Tournament, settings: Settings) -> datetime:
    if t.finished_at is not None:
        return t.finished_at
    return rules.ends_at_estimate(
        t.starts_at,
        shown_rounds(t),
        round(settings.tournament_round_s),
        round(settings.tournament_pause_s),
    )


def card(
    t: Tournament,
    subjects: dict[int, Subject],
    settings: Settings,
    entry: TournamentEntry | None,
) -> dict[str, Any]:
    subject = subjects.get(t.subject_id) if t.subject_id is not None else None
    return {
        "id": str(t.id),
        "title": t.title,
        "goal": t.goal,
        "subject": subject.slug if subject else None,
        "tone": subject.tone if subject else ALL_TONE,
        "status": t.status,
        "reg_opens_at": _iso(t.reg_opens_at),
        "checkin_opens_at": _iso(rules.checkin_opens_at(t.starts_at)),
        "starts_at": _iso(t.starts_at),
        "ends_at_estimate": _iso(ends_at_estimate(t, settings)),
        "rounds": shown_rounds(t),
        "entry_fee": t.entry_fee,
        "prize_pool": t.prize_pool,
        "effective_pool": shown_effective_pool(t.prize_pool, t.players),
        "players": t.players,
        "min_players": rules.min_players(t.min_players),
        "capacity": t.capacity,
        "me": (
            {"registered": True, "checked_in": entry.checked_in, "withdrawn": entry.withdrawn}
            if entry is not None
            else None
        ),
    }


def _iso(moment: datetime) -> str:
    return moment.astimezone(UTC).isoformat().replace("+00:00", "Z")


def prize_table(pool: int, players: int) -> list[dict[str, int]]:
    """Places and coins for the current field, merged into ranges of equal amounts."""
    field = min(max(players, MIN_ENTRANTS), MAX_ENTRANTS)
    places = [f"p{i}" for i in range(1, field + 1)]
    amounts = distribute(pool, field, places) if pool > 0 else {}
    out: list[dict[str, int]] = []
    for index, place in enumerate(places, start=1):
        coins = amounts.get(place)
        if coins is None:
            break
        if out and out[-1]["coins"] == coins and out[-1]["to"] == index - 1:
            out[-1]["to"] = index
        else:
            out.append({"from": index, "to": index, "coins": coins})
    return out


async def _entry(
    db: AsyncSession, tournament_id: uuid.UUID, user_id: uuid.UUID
) -> TournamentEntry | None:
    return await db.get(TournamentEntry, (tournament_id, user_id), populate_existing=True)


async def _entries_of(
    db: AsyncSession, user_id: uuid.UUID, ids: Sequence[uuid.UUID]
) -> dict[uuid.UUID, TournamentEntry]:
    if not ids:
        return {}
    rows = await db.scalars(
        select(TournamentEntry).where(
            TournamentEntry.user_id == user_id, TournamentEntry.tournament_id.in_(list(ids))
        )
    )
    return {e.tournament_id: e for e in rows}


async def get_tournament(db: AsyncSession, tournament_id: uuid.UUID) -> Tournament:
    t = await db.get(Tournament, tournament_id)
    if t is None:
        raise NotFound("That tournament doesn't exist.", code="TOURNAMENT_NOT_FOUND")
    return t


async def locked(db: AsyncSession, tournament_id: uuid.UUID) -> Tournament:
    t = await db.get(Tournament, tournament_id, with_for_update=True, populate_existing=True)
    if t is None:
        raise NotFound("That tournament doesn't exist.", code="TOURNAMENT_NOT_FOUND")
    return t


# --- Lists ---------------------------------------------------------------------------------


class ListCursor(ApiModel):
    at: Lax[datetime]
    id: Lax[uuid.UUID]


async def list_cards(
    db: AsyncSession,
    settings: Settings,
    user_id: uuid.UUID,
    *,
    status: str,
    goal: str | None,
    cursor: str | None,
    limit: int,
) -> dict[str, Any]:
    """Arena cards by filter: open, upcoming and live soonest first, finished newest first."""
    states = [s.value for s in rules.FILTERS[status]]
    newest_first = status == "finished"
    statement = select(Tournament).where(Tournament.status.in_(states))
    if goal is not None:
        statement = statement.where(Tournament.goal.in_([goal, "any"]))
    order = (
        (Tournament.starts_at.desc(), Tournament.id.desc())
        if newest_first
        else (Tournament.starts_at, Tournament.id)
    )
    statement = statement.order_by(*order).limit(limit + 1)
    if cursor is not None:
        position = decode_cursor(cursor, ListCursor)
        key = tuple_(Tournament.starts_at, Tournament.id)
        target = tuple_(position.at, position.id)
        statement = statement.where(key < target if newest_first else key > target)
    rows = list(await db.scalars(statement))
    page = rows[:limit]
    return await _cards_page(db, settings, user_id, page, has_more=len(rows) > limit)


async def _cards_page(
    db: AsyncSession,
    settings: Settings,
    user_id: uuid.UUID,
    page: list[Tournament],
    *,
    has_more: bool,
) -> dict[str, Any]:
    subjects = await subjects_by_id(db)
    mine = await _entries_of(db, user_id, [t.id for t in page])
    next_cursor = None
    if has_more and page:
        next_cursor = encode_cursor(ListCursor(at=page[-1].starts_at, id=page[-1].id))
    return {
        "items": [card(t, subjects, settings, mine.get(t.id)) for t in page],
        "next_cursor": next_cursor,
    }


async def my_tournaments(
    db: AsyncSession,
    settings: Settings,
    user_id: uuid.UUID,
    *,
    cursor: str | None,
    limit: int,
) -> dict[str, Any]:
    """The player's tournaments, newest start first; finished ones carry the result."""
    statement = (
        select(Tournament, TournamentEntry)
        .join(TournamentEntry, TournamentEntry.tournament_id == Tournament.id)
        .where(TournamentEntry.user_id == user_id)
        .order_by(Tournament.starts_at.desc(), Tournament.id.desc())
        .limit(limit + 1)
    )
    if cursor is not None:
        position = decode_cursor(cursor, ListCursor)
        statement = statement.where(
            tuple_(Tournament.starts_at, Tournament.id) < tuple_(position.at, position.id)
        )
    rows = (await db.execute(statement)).all()
    page = rows[:limit]
    subjects = await subjects_by_id(db)
    items = []
    for t, entry in page:
        item = card(t, subjects, settings, entry)
        if t.status == S.FINISHED and entry.checked_in:
            final = await final_result(db, t, entry)
            item.update(
                final_rank=final["rank"],
                prize=final["prize"],
                xp=final["xp"],
                points=final["points"],
            )
        items.append(item)
    next_cursor = None
    if len(rows) > limit and page:
        last = page[-1][0]
        next_cursor = encode_cursor(ListCursor(at=last.starts_at, id=last.id))
    return {"items": items, "next_cursor": next_cursor}


# --- Detail --------------------------------------------------------------------------------


async def tournament_xp(db: AsyncSession, tournament_id: uuid.UUID, user_id: uuid.UUID) -> int:
    """XP the player earned from this tournament's games (10 per round played)."""
    match_ids = select(TournamentPairing.match_id).where(
        TournamentPairing.tournament_id == tournament_id,
        TournamentPairing.match_id.is_not(None),
        or_(TournamentPairing.a_id == user_id, TournamentPairing.b_id == user_id),
    )
    total = await db.scalar(
        select(func.coalesce(func.sum(XpEvent.amount), 0)).where(
            XpEvent.user_id == user_id, XpEvent.ref_id.in_(match_ids)
        )
    )
    return int(total or 0)


async def final_result(db: AsyncSession, t: Tournament, entry: TournamentEntry) -> dict[str, Any]:
    prize = await db.scalar(
        select(TournamentPrize.amount).where(
            TournamentPrize.tournament_id == t.id, TournamentPrize.user_id == entry.user_id
        )
    )
    field = await db.scalar(
        select(func.count()).where(
            TournamentEntry.tournament_id == t.id, TournamentEntry.checked_in
        )
    )
    return {
        "rank": entry.final_rank,
        "players": int(field or 0),
        "points": points_out(entry.points),
        "prize": int(prize or 0),
        "xp": await tournament_xp(db, t.id, entry.user_id),
    }


async def _pairing_of(
    db: AsyncSession, tournament_id: uuid.UUID, number: int, user_id: uuid.UUID
) -> TournamentPairing | None:
    return await db.scalar(
        select(TournamentPairing).where(
            TournamentPairing.tournament_id == tournament_id,
            TournamentPairing.round == number,
            or_(TournamentPairing.a_id == user_id, TournamentPairing.b_id == user_id),
        )
    )


async def _pairing_out(
    db: AsyncSession, redis: Redis | None, pairing: TournamentPairing, user_id: uuid.UUID
) -> dict[str, Any]:
    opponent_id = pairing.b_id if pairing.a_id == user_id else pairing.a_id
    opponent = None
    if opponent_id is not None:
        players = await load_players(db, [opponent_id])
        info = players.get(opponent_id)
        opponent = rest_card(info.card()) if info else None
    ready_by = None
    if pairing.match_id is not None and redis is not None and pairing.status == "pending":
        # Imported here: the engine keys module is only needed for live pairings.
        from app.modules.realtime import keys, rstr

        phase, ends_at = await rstr.hmget(
            redis, keys.match(str(pairing.match_id)), ["phase", "ends_at"]
        )
        if phase == "ready_wait" and ends_at:
            ready_by = _iso(datetime.fromtimestamp(int(ends_at) / 1000, UTC))
    return {
        "round": pairing.round,
        "opponent": opponent,
        "bye": pairing.b_id is None,
        "match_id": str(pairing.match_id) if pairing.match_id else None,
        "ready_by": ready_by,
    }


async def detail(
    db: AsyncSession,
    redis: Redis | None,
    settings: Settings,
    tournament_id: uuid.UUID,
    user_id: uuid.UUID,
) -> dict[str, Any]:
    t = await get_tournament(db, tournament_id)
    subjects = await subjects_by_id(db)
    entry = await _entry(db, t.id, user_id)
    out = card(t, subjects, settings, entry)
    rounds_rows = {
        r.number: r
        for r in await db.scalars(
            select(TournamentRound).where(TournamentRound.tournament_id == t.id)
        )
    }
    schedule = []
    step = timedelta(seconds=settings.tournament_round_s + settings.tournament_pause_s)
    for number in range(1, shown_rounds(t) + 1):
        row = rounds_rows.get(number)
        starts = row.started_at if row is not None and row.started_at else None
        state = "upcoming"
        if row is not None:
            state = {
                RoundStatus.STARTING: "pairing",
                RoundStatus.LIVE: "live",
                RoundStatus.CLOSING: "live",
                RoundStatus.DONE: "done",
            }[RoundStatus(row.status)]
        schedule.append(
            {
                "round": number,
                "starts_at": _iso(starts or t.starts_at + (number - 1) * step),
                "status": state,
            }
        )
    out.update(
        description=t.description,
        rules={
            "questions": settings.tournament_questions,
            "seconds_per_question": settings.match_limit_ms // 1000,
            "rated": True,
            "ready_s": settings.tournament_ready_ms // 1000,
            "draw_points": 0.5,
            "bye_points": 1,
        },
        schedule=schedule,
        prizes=prize_table(t.prize_pool, t.players),
        current_round=t.current_round or None,
        me=await _me(db, redis, t, entry) if entry is not None else None,
    )
    return out


async def _me(
    db: AsyncSession, redis: Redis | None, t: Tournament, entry: TournamentEntry
) -> dict[str, Any]:
    next_pairing = None
    if t.status == S.RUNNING and t.current_round:
        pairing = await _pairing_of(db, t.id, t.current_round, entry.user_id)
        if pairing is not None:
            next_pairing = await _pairing_out(db, redis, pairing, entry.user_id)
    final = None
    if t.status == S.FINISHED and entry.checked_in:
        final = await final_result(db, t, entry)
    return {
        "registered": True,
        "checked_in": entry.checked_in,
        "withdrawn": entry.withdrawn,
        "record": {"wins": entry.wins, "draws": entry.draws, "losses": entry.losses},
        "points": points_out(entry.points),
        "rank": entry.final_rank or entry.rank,
        "next_pairing": next_pairing,
        "final": final,
    }


class StandingsCursor(ApiModel):
    position: int


async def standings(
    db: AsyncSession,
    tournament_id: uuid.UUID,
    user_id: uuid.UUID,
    *,
    cursor: str | None,
    limit: int,
) -> dict[str, Any]:
    t = await get_tournament(db, tournament_id)
    after = decode_cursor(cursor, StandingsCursor).position if cursor else 0
    statement = (
        select(TournamentEntry)
        .where(
            TournamentEntry.tournament_id == t.id,
            TournamentEntry.checked_in,
            TournamentEntry.rank.is_not(None),
            TournamentEntry.rank > after,
        )
        .order_by(TournamentEntry.rank)
        .limit(limit + 1)
    )
    rows = list(await db.scalars(statement))
    page = rows[:limit]
    mine = await _entry(db, t.id, user_id)
    wanted = [e.user_id for e in page] + ([mine.user_id] if mine else [])
    players = await load_players(db, wanted)

    def row(entry: TournamentEntry) -> dict[str, Any]:
        info = players.get(entry.user_id)
        return {
            "position": entry.final_rank or entry.rank,
            "user": rest_card(info.card()) if info else {"id": str(entry.user_id)},
            "points": points_out(entry.points),
            "w": entry.wins,
            "d": entry.draws,
            "l": entry.losses,
            "bh_c1": points_out(entry.bh_c1),
            "bh": points_out(entry.bh),
            "sb": points_out(entry.sb),
            "withdrawn": entry.withdrawn,
        }

    next_cursor = None
    if len(rows) > limit and page:
        next_cursor = encode_cursor(StandingsCursor(position=page[-1].rank or 0))
    return {
        "items": [row(e) for e in page],
        "next_cursor": next_cursor,
        "me": row(mine) if mine is not None and mine.rank is not None else None,
        "round": t.current_round,
    }


async def my_games(
    db: AsyncSession, redis: Redis | None, tournament_id: uuid.UUID, user_id: uuid.UUID
) -> dict[str, Any]:
    t = await get_tournament(db, tournament_id)
    entry = await _entry(db, t.id, user_id)
    if entry is None:
        raise NotRegistered()
    pairings = list(
        await db.scalars(
            select(TournamentPairing)
            .where(
                TournamentPairing.tournament_id == t.id,
                or_(TournamentPairing.a_id == user_id, TournamentPairing.b_id == user_id),
            )
            .order_by(TournamentPairing.round)
        )
    )
    opponents = [p.b_id if p.a_id == user_id else p.a_id for p in pairings]
    players = await load_players(db, [o for o in opponents if o is not None])
    rounds_out = []
    for p, opponent_id in zip(pairings, opponents, strict=True):
        mine = p.result_a if p.a_id == user_id else p.result_b
        info = players.get(opponent_id) if opponent_id else None
        result = None
        if p.status == PairingStatus.DONE and mine is not None:
            result = {
                "win": "win",
                "forfeit_win": "win",
                "bye": "win",
                "draw": "draw",
            }.get(mine, "loss")
        rounds_out.append(
            {
                "round": p.round,
                "opponent": rest_card(info.card()) if info else None,
                "bye": p.b_id is None,
                "result": result,
                "points": {"win": 1, "forfeit_win": 1, "bye": 1, "draw": 0.5}.get(mine or "", 0),
                "match_id": str(p.match_id) if p.match_id else None,
                "no_show": mine in {"forfeit_win", "forfeit_loss", "double_forfeit"},
            }
        )
    current = None
    if t.status == S.RUNNING and t.current_round:
        pairing = next((p for p in pairings if p.round == t.current_round), None)
        if pairing is not None:
            current = await _pairing_out(db, redis, pairing, user_id)
    return {
        "rounds": rounds_out,
        "current": current,
        "record": {"wins": entry.wins, "draws": entry.draws, "losses": entry.losses},
        "points": points_out(entry.points),
        "rank": entry.final_rank or entry.rank,
    }


# --- Registration --------------------------------------------------------------------------


async def no_show_block(db: AsyncSession, user_id: uuid.UUID, now: datetime) -> datetime | None:
    starts = list(
        await db.scalars(
            select(Tournament.starts_at)
            .join(TournamentEntry, TournamentEntry.tournament_id == Tournament.id)
            .where(
                TournamentEntry.user_id == user_id,
                TournamentEntry.no_show,
                Tournament.starts_at > now - rules.NO_SHOW_WINDOW - rules.NO_SHOW_BLOCK,
            )
        )
    )
    return rules.no_show_blocked(starts, now)


async def _conflict(
    db: AsyncSession, settings: Settings, t: Tournament, user_id: uuid.UUID
) -> Tournament | None:
    """Another live tournament of the player whose time overlaps this one."""
    others = await db.scalars(
        select(Tournament)
        .join(TournamentEntry, TournamentEntry.tournament_id == Tournament.id)
        .where(
            TournamentEntry.user_id == user_id,
            ~TournamentEntry.withdrawn,
            Tournament.id != t.id,
            Tournament.status.not_in([s.value for s in TERMINAL]),
        )
    )
    start = rules.checkin_opens_at(t.starts_at)
    end = ends_at_estimate(t, settings)
    for other in others:
        if rules.checkin_opens_at(other.starts_at) < end and start < ends_at_estimate(
            other, settings
        ):
            return other
    return None


async def register(
    db: AsyncSession,
    settings: Settings,
    tournament_id: uuid.UUID,
    user_id: uuid.UUID,
    *,
    now: datetime,
) -> dict[str, Any]:
    """Register and hold the entry fee; the updated card. Registering again is a no-op."""
    t = await locked(db, tournament_id)
    entry = await _entry(db, t.id, user_id)
    if entry is not None and not entry.withdrawn:
        return card(t, await subjects_by_id(db), settings, entry)
    if t.status not in {S.REG_OPEN, S.CHECK_IN} or now >= rules.locks_at(t.starts_at):
        raise RegistrationClosed()
    user = await db.get_one(User, user_id)
    if not rules.exam_allows(t.goal, user.goal or DEFAULT_GOAL):
        raise NotAllowed(
            "This tournament is for the other exam.", details={"reason": "exam", "goal": t.goal}
        )
    if t.players >= t.capacity:
        raise TournamentFull()
    if t.entry_fee > 0:
        blocked = await no_show_block(db, user_id, now)
        if blocked is not None:
            raise NotAllowed(
                "You missed 3 tournaments you entered, so paid ones are paused for a week.",
                details={"reason": "no_shows", "until": _iso(blocked)},
            )
    other = await _conflict(db, settings, t, user_id)
    if other is not None:
        raise ScheduleConflict(details={"id": str(other.id), "title": other.title})
    hold_id = None
    if t.entry_fee > 0:
        result = await hold(
            db,
            user_id,
            t.entry_fee,
            reason=CoinReason.TOURNAMENT_ENTRY,
            title=f"Entry: {t.title}",
            key=f"t:{t.id}:{user_id}:entry:{int(now.timestamp() * 1000)}",
            ref=Ref(RefKind.TOURNAMENT, str(t.id)),
        )
        hold_id = result.hold.id
    if entry is None:
        entry = TournamentEntry(tournament_id=t.id, user_id=user_id, registered_at=now)
        db.add(entry)
    else:
        entry.registered_at = now
        entry.withdrawn = False
        entry.withdrawn_at = None
        entry.withdraw_reason = None
        entry.checked_in = False
        entry.checked_in_at = None
    entry.hold_id = hold_id
    t.players += 1
    await db.flush()
    return card(t, await subjects_by_id(db), settings, entry)


async def refund_hold(db: AsyncSession, entry: TournamentEntry, title: str) -> int:
    """Release the entry's held fee; how many coins went back (0 if none or already)."""
    if entry.hold_id is None:
        return 0
    record, _wallet = await locked_hold(db, entry.hold_id)
    if record.status != HoldStatus.HELD:
        return 0
    await release_hold(db, entry.hold_id, title=title)
    return int(record.amount)


async def withdraw(
    db: AsyncSession,
    settings: Settings,
    tournament_id: uuid.UUID,
    user_id: uuid.UUID,
    *,
    now: datetime,
    reason: str = "withdrew",
) -> dict[str, Any]:
    """Leave. Before the start the fee comes back; after it the player keeps their place in
    the standings, gets no refund and can't win a prize."""
    t = await locked(db, tournament_id)
    entry = await _entry(db, t.id, user_id)
    if entry is None or entry.withdrawn:
        raise NotRegistered()
    if t.status in TERMINAL:
        raise Conflict("This tournament is over.", code="TOURNAMENT_OVER")
    refunded = await withdraw_entry(db, t, entry, now=now, reason=reason)
    return {"tournament": card(t, await subjects_by_id(db), settings, entry), "refunded": refunded}


async def withdraw_entry(
    db: AsyncSession, t: Tournament, entry: TournamentEntry, *, now: datetime, reason: str
) -> int:
    """Mark ``entry`` withdrawn (the tournament row is locked); returns the coins refunded."""
    started = t.status in {S.RUNNING, S.FINALIZING}
    refunded = 0
    if not started:
        refunded = await refund_hold(db, entry, f"Refund: left {t.title}")
        t.players = max(0, t.players - 1)
    entry.withdrawn = True
    entry.withdrawn_at = now
    entry.withdraw_reason = reason
    await db.flush()
    return refunded


async def check_in(
    db: AsyncSession,
    settings: Settings,
    tournament_id: uuid.UUID,
    user_id: uuid.UUID,
    *,
    now: datetime,
) -> dict[str, Any]:
    t = await locked(db, tournament_id)
    entry = await _entry(db, t.id, user_id)
    if entry is None or entry.withdrawn:
        raise NotRegistered()
    opens, closes = rules.checkin_opens_at(t.starts_at), rules.checkin_closes_at(t.starts_at)
    if t.status not in {S.REG_OPEN, S.CHECK_IN, S.LOCKED} or not opens <= now < closes:
        raise CheckInClosed(details={"opens_at": _iso(opens), "closes_at": _iso(closes)})
    if not entry.checked_in:
        entry.checked_in = True
        entry.checked_in_at = now
        await events.user_event(
            db,
            user_id,
            "t.checked_in",
            {"tournament_id": str(t.id)},
            key=f"checked_in:{t.id}:{user_id}",
        )
        await db.flush()
    return card(t, await subjects_by_id(db), settings, entry)


# --- For other features --------------------------------------------------------------------


def active_out(t: Tournament) -> ActiveOut:
    return ActiveOut(
        kind="tournament", id=str(t.id), title=t.title, action={"route": f"/arena/{t.id}"}
    )


async def busy_check(
    db: AsyncSession, _redis: Redis, user_id: uuid.UUID, until_ms: int
) -> ActiveOut | None:
    """``matches.busy``: a registered player's tournament that needs them (T - 2 min) before
    ``until_ms``, or the running tournament they are checked in to."""
    until = datetime.fromtimestamp(until_ms / 1000, UTC)
    rows = (
        await db.execute(
            select(Tournament, TournamentEntry)
            .join(TournamentEntry, TournamentEntry.tournament_id == Tournament.id)
            .where(
                TournamentEntry.user_id == user_id,
                ~TournamentEntry.withdrawn,
                Tournament.status.in_([s.value for s in rules.BUSY_STATES]),
            )
            .order_by(Tournament.starts_at)
        )
    ).all()
    for t, entry in rows:
        if t.status in {S.RUNNING, S.FINALIZING}:
            if entry.checked_in:
                return active_out(t)
        elif until >= rules.checkin_closes_at(t.starts_at):
            return active_out(t)
    return None


async def next_tournament(
    db: AsyncSession, settings: Settings, user: User, now: datetime
) -> dict[str, Any] | None:
    """Home's tournament card: the player's own tournament checking in or running, else the
    soonest open one of their exam with the biggest pool."""
    subjects = await subjects_by_id(db)
    own = (
        await db.execute(
            select(Tournament, TournamentEntry)
            .join(TournamentEntry, TournamentEntry.tournament_id == Tournament.id)
            .where(
                TournamentEntry.user_id == user.id,
                ~TournamentEntry.withdrawn,
                Tournament.status.in_([S.CHECK_IN, S.LOCKED, S.RUNNING, S.FINALIZING]),
            )
            .order_by(Tournament.starts_at)
            .limit(1)
        )
    ).first()
    if own is not None:
        return card(own[0], subjects, settings, own[1])
    goal = user.goal or DEFAULT_GOAL
    t = await db.scalar(
        select(Tournament)
        .where(
            Tournament.status.in_([S.REG_OPEN, S.CHECK_IN]),
            Tournament.goal.in_([goal, "any"]),
            Tournament.starts_at > now,
        )
        .order_by(Tournament.starts_at, Tournament.prize_pool.desc(), Tournament.id)
        .limit(1)
    )
    if t is None:
        return None
    return card(t, subjects, settings, await _entry(db, t.id, user.id))


async def hall_of_fame(db: AsyncSession, subject: str | None, goal: str) -> list[dict[str, Any]]:
    """The last 10 winners of finished tournaments in ``subject`` (None: all-subject ones)
    for ``goal`` (tournaments open to both exams count for either)."""
    statement = (
        select(Tournament, TournamentPrize)
        .join(
            TournamentPrize,
            and_(TournamentPrize.tournament_id == Tournament.id, TournamentPrize.place == 1),
        )
        .where(Tournament.status == S.FINISHED, Tournament.goal.in_([goal, "any"]))
        .order_by(Tournament.finished_at.desc(), Tournament.id.desc())
        .limit(10)
    )
    if subject is None:
        statement = statement.where(Tournament.subject_id.is_(None))
    else:
        statement = statement.join(Subject, Subject.id == Tournament.subject_id).where(
            Subject.slug == subject
        )
    rows = (await db.execute(statement)).all()
    players = await load_players(db, [prize.user_id for _, prize in rows])
    out = []
    for t, prize in rows:
        entry = await _entry(db, t.id, prize.user_id)
        info = players.get(prize.user_id)
        out.append(
            {
                "tournament_id": str(t.id),
                "title": t.title,
                "finished_at": _iso(t.finished_at or t.starts_at),
                "winner": rest_card(info.card()) if info else {"id": str(prize.user_id)},
                "points": points_out(entry.points) if entry else None,
                "prize": prize.amount,
            }
        )
    return out
