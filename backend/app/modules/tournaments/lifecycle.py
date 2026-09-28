"""The tournament lifecycle, one worker step at a time (docs/plan.md, Phase 5 "Lifecycle").

``run_due`` picks the most overdue tournament with ``FOR UPDATE SKIP LOCKED`` (replicas share
the work), runs its step and commits; the step's side effects are outbox rows (inbox items,
pushes, live events) in the same transaction. A crash anywhere just means the step runs again:
nothing is committed half way, and every key (holds, ledger postings, notices, events) is
unique, so a re-run changes nothing twice.

| From | When | Step |
|---|---|---|
| scheduled | ``reg_opens_at`` | open registration |
| reg_open | T - 30 min | "at risk" notices when too few registered |
| reg_open | T - 15 min | open check-in (inbox, push, ``t.check_in``) |
| check_in | T - 5 min | lock registration |
| locked | T | too few checked in: cancel, refund all; else pair round 1 (below) |
| running | round deadline | end unfinished games (then they settle) |
| running | deadline + 5 s | boards still without a result are double no-shows |
| running | last result + 90 s | pair the next round, or finalize |
| finalizing | at once | ranks, prizes, XP and progression, notices |

At the start, players who didn't check in are refunded and dropped, the other fees are
captured, and the field is seeded by rating.

Pairing a round writes the round, its boards with pre-generated match ids and the match rows,
then creates the live games in Redis (``create.lua`` is idempotent) just before the commit. If
the commit fails the games are orphans that end as no-shows and settle as unknown matches.
"""

import asyncio
import uuid
from collections.abc import Sequence
from dataclasses import dataclass, field
from datetime import datetime, timedelta

import structlog
from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.clock import utc_now
from app.core.config import Settings
from app.core.ids import new_id
from app.modules.content.models import ExamGoal, GoalSubject, Subject
from app.modules.economy.models import CoinReason, HoldStatus, RefKind
from app.modules.economy.service import Ref, capture_hold, credit, locked_hold
from app.modules.matches.creation import Contender, prepare_match
from app.modules.matches.models import MatchKind
from app.modules.matches.players import load_players
from app.modules.matches.settlement import SettleDeps, settle_match
from app.modules.notifications.service import notify
from app.modules.progression.service import EventKind, record_event
from app.modules.ratings.models import OVERALL
from app.modules.ratings.service import load_ratings, to_glicko
from app.modules.realtime.engine import scripts
from app.modules.social.activity import record_activity
from app.modules.tournaments import events, rules
from app.modules.tournaments.models import (
    PairingStatus,
    RoundStatus,
    Tournament,
    TournamentEntry,
    TournamentPairing,
    TournamentPrize,
    TournamentRound,
    TournamentStatus,
    TournamentTemplate,
)
from app.modules.tournaments.prizes import MAX_ENTRANTS, MIN_ENTRANTS, distribute
from app.modules.tournaments.results import close_round_if_done, record_pairing
from app.modules.tournaments.service import refund_hold, tournament_xp
from app.modules.tournaments.standings import GameResult
from app.modules.tournaments.standings_view import field_entries, points_out, recompute
from app.modules.tournaments.swiss_pairing import (
    Pairings,
    SwissPlayer,
    greedy_pairing,
    pair_first_round,
    pair_round,
)
from app.modules.users.models import User, UserStatus

log = structlog.stdlib.get_logger("app.worker")

S = TournamentStatus
SETTLE_GRACE = timedelta(seconds=5)
MAX_STEPS = 100  # per run, so one busy tick can't starve the others


@dataclass(slots=True)
class StepOutcome:
    settle: list[str] = field(default_factory=list)  # matches to settle after the commit


def _ms(moment: datetime) -> int:
    return int(moment.timestamp() * 1000)


def _action(t: Tournament) -> dict[str, object]:
    return {"route": f"/arena/{t.id}", "params": {}}


async def run_due(deps: SettleDeps, *, now: datetime | None = None) -> int:
    """Run every due step (up to ``MAX_STEPS``); returns how many ran."""
    ran = 0
    while ran < MAX_STEPS:
        moment = now or utc_now()
        async with deps.sessionmaker() as db:
            t = await db.scalar(
                select(Tournament)
                .where(Tournament.next_action_at <= moment)
                .order_by(Tournament.next_action_at, Tournament.id)
                .limit(1)
                .with_for_update(skip_locked=True)
            )
            if t is None:
                return ran
            before = (t.status, t.next_action_at)
            outcome = await step(db, deps, t, moment)
            if (t.status, t.next_action_at) == before:
                # Nothing moved (only possible through a bug): try again a little later.
                t.next_action_at = moment + timedelta(seconds=5)
            await db.commit()
        ran += 1
        for mid in outcome.settle:
            try:
                await settle_match(deps, mid)
            except Exception:  # settle_pending retries it
                log.exception("tournament.settle_failed", match_id=mid)
    return ran


async def step(db: AsyncSession, deps: SettleDeps, t: Tournament, now: datetime) -> StepOutcome:
    """One transition of ``t`` (locked), as due at ``now``."""
    settings = deps.settings
    status = TournamentStatus(t.status)
    outcome = StepOutcome()
    if status == S.SCHEDULED:
        if now >= t.reg_opens_at:
            t.status = S.REG_OPEN.value
            t.next_action_at = _registration_next(t)
        else:
            t.next_action_at = t.reg_opens_at
    elif status == S.REG_OPEN:
        if now >= rules.checkin_opens_at(t.starts_at):
            await open_check_in(db, t, now)
        elif now >= rules.at_risk_at(t.starts_at) and not t.at_risk_sent:
            await at_risk(db, t)
            t.next_action_at = _registration_next(t)
        else:
            t.next_action_at = _registration_next(t)
    elif status == S.CHECK_IN:
        if now >= rules.locks_at(t.starts_at):
            t.status = S.LOCKED.value
            t.next_action_at = t.starts_at
        else:
            t.next_action_at = rules.locks_at(t.starts_at)
    elif status == S.LOCKED:
        if now >= t.starts_at:
            await start(db, deps, t, now)
        else:
            t.next_action_at = t.starts_at
    elif status == S.RUNNING:
        outcome = await running(db, deps, t, now)
    elif status == S.FINALIZING:
        await finalize(db, settings, t, now)
    else:
        t.next_action_at = None
    await db.flush()
    log.info("tournament.step", tournament_id=str(t.id), status=t.status)
    return outcome


def _registration_next(t: Tournament) -> datetime:
    times = [rules.checkin_opens_at(t.starts_at)]
    if not t.at_risk_sent:
        times.append(rules.at_risk_at(t.starts_at))
    return min(times)


async def _active_entries(db: AsyncSession, t: Tournament) -> list[TournamentEntry]:
    return list(
        await db.scalars(
            select(TournamentEntry)
            .where(TournamentEntry.tournament_id == t.id, ~TournamentEntry.withdrawn)
            .order_by(TournamentEntry.user_id)
        )
    )


# --- Before the start ------------------------------------------------------------------------


async def at_risk(db: AsyncSession, t: Tournament) -> None:
    t.at_risk_sent = True
    needed = rules.min_players(t.min_players) - t.players
    if needed <= 0:
        return
    for entry in await _active_entries(db, t):
        await notify(
            db,
            entry.user_id,
            kind="tournament_at_risk",
            title=f"At risk: {needed} more players needed",
            body=f"{t.title} needs {needed} more players to start. Invite friends!",
            icon="trophy",
            action=_action(t),
            key=f"tournament_at_risk:{t.id}",
        )
        await events.user_event(
            db,
            entry.user_id,
            "t.at_risk",
            {"tournament_id": str(t.id), "players": t.players, "needed": needed},
            key=f"at_risk:{t.id}:{entry.user_id}",
        )


async def open_check_in(db: AsyncSession, t: Tournament, now: datetime) -> None:
    if not t.at_risk_sent:
        await at_risk(db, t)
    t.status = S.CHECK_IN.value
    t.next_action_at = rules.locks_at(t.starts_at)
    closes = rules.checkin_closes_at(t.starts_at)
    for entry in await _active_entries(db, t):
        await notify(
            db,
            entry.user_id,
            kind="tournament_check_in",
            title="Check in now",
            body=f"{t.title} starts in 15 minutes. Check in to play.",
            icon="trophy",
            action=_action(t),
            key=f"tournament_check_in:{t.id}",
            time_critical=True,
        )
        await events.user_event(
            db,
            entry.user_id,
            "t.check_in",
            {
                "tournament_id": str(t.id),
                "title": t.title,
                "starts_at": _ms(t.starts_at),
                "closes_at": _ms(closes),
            },
            key=f"check_in:{t.id}:{entry.user_id}",
        )


async def start(db: AsyncSession, deps: SettleDeps, t: Tournament, now: datetime) -> None:
    """T: cancel a field that is too small, else drop the no-shows and pair round 1."""
    entries = await _active_entries(db, t)
    checked = [e for e in entries if e.checked_in]
    if len(checked) < rules.min_players(t.min_players):
        await cancel(db, t, reason="not_enough_players", now=now)
        return
    for entry in entries:
        if entry.checked_in:
            continue
        refunded = await refund_hold(db, entry, f"Refund: didn't check in to {t.title}")
        entry.no_show = True
        entry.withdrawn = True
        entry.withdrawn_at = now
        entry.withdraw_reason = "no_show"
        t.players = max(0, t.players - 1)
        await notify(
            db,
            entry.user_id,
            kind="refund" if refunded else "tournament_withdrawn",
            title="You didn't check in",
            body=(
                f"You didn't check in to {t.title}; your {refunded} coins were returned."
                if refunded
                else f"You didn't check in to {t.title}, so you weren't paired."
            ),
            icon="trophy",
            action=_action(t),
            key=f"tournament_no_show:{t.id}",
        )
    for entry in checked:
        if entry.hold_id is not None:
            record, _wallet = await locked_hold(db, entry.hold_id)
            if record.status == HoldStatus.HELD:
                await capture_hold(db, entry.hold_id)
    subject = await db.get(Subject, t.subject_id) if t.subject_id is not None else None
    scope = subject.slug if subject is not None else OVERALL
    ratings = await load_ratings(db, [e.user_id for e in checked], scope)
    ordered = sorted(
        checked,
        key=lambda e: (-to_glicko(ratings.get(e.user_id)).rating, e.registered_at, e.user_id),
    )
    for seed, entry in enumerate(ordered, start=1):
        entry.seed = seed
    t.rounds_planned = rules.rounds_for(t.rounds, len(checked))
    t.status = S.RUNNING.value
    t.started_at = now
    await db.flush()
    await pair_next_round(db, deps, t, now)


# --- Rounds ----------------------------------------------------------------------------------


async def running(db: AsyncSession, deps: SettleDeps, t: Tournament, now: datetime) -> StepOutcome:
    outcome = StepOutcome()
    row = await db.get(TournamentRound, (t.id, t.current_round), populate_existing=True)
    if row is None:  # started but round 1 never paired (a crash can't leave this; be safe)
        await pair_next_round(db, deps, t, now)
        return outcome
    status = RoundStatus(row.status)
    if status in {RoundStatus.LIVE, RoundStatus.STARTING}:
        if row.deadline_at is not None and now < row.deadline_at:
            t.next_action_at = row.deadline_at
            return outcome
        pending = await _pending(db, t, row.number)
        for pairing in pending:
            if pairing.match_id is not None:
                await scripts.end(deps.redis, str(pairing.match_id))
                outcome.settle.append(str(pairing.match_id))
        row.status = RoundStatus.CLOSING.value
        t.next_action_at = now + SETTLE_GRACE
        if not pending:
            await close_round_if_done(db, deps.settings, t, row.number, now=now)
    elif status == RoundStatus.CLOSING:
        for pairing in await _pending(db, t, row.number):
            players = [pairing.a_id] + ([pairing.b_id] if pairing.b_id else [])
            await record_pairing(
                db,
                deps.settings,
                t,
                pairing,
                dict.fromkeys(players, GameResult.DOUBLE_FORFEIT),
                scores={},
                correct={},
                counts_absence=True,
                now=now,
            )
        await close_round_if_done(db, deps.settings, t, row.number, now=now)
    else:  # done: the pause is over
        active = [e for e in await field_entries(db, t.id) if not e.withdrawn]
        if t.current_round < (t.rounds_planned or 0) and len(active) >= 2:
            await pair_next_round(db, deps, t, now)
        else:
            t.status = S.FINALIZING.value
            t.next_action_at = now
    return outcome


async def _pending(db: AsyncSession, t: Tournament, number: int) -> list[TournamentPairing]:
    return list(
        await db.scalars(
            select(TournamentPairing)
            .where(
                TournamentPairing.tournament_id == t.id,
                TournamentPairing.round == number,
                TournamentPairing.status == PairingStatus.PENDING,
            )
            .order_by(TournamentPairing.board)
        )
    )


async def _round_subject(db: AsyncSession, t: Tournament, number: int) -> Subject:
    """The tournament's subject; an all-subjects tournament takes its exam's subjects in
    turn, one per round."""
    if t.subject_id is not None:
        return await db.get_one(Subject, t.subject_id)
    goals = ["neet", "jee"] if t.goal == "any" else [t.goal]
    subjects = list(
        await db.scalars(
            select(Subject)
            .join(GoalSubject, GoalSubject.subject_id == Subject.id)
            .join(ExamGoal, ExamGoal.id == GoalSubject.goal_id)
            .where(ExamGoal.slug.in_(goals))
            .distinct()
            .order_by(Subject.sort, Subject.id)
        )
    )
    return subjects[(number - 1) % len(subjects)]


async def swiss_players(db: AsyncSession, t: Tournament, number: int) -> list[SwissPlayer]:
    entries = [e for e in await field_entries(db, t.id) if not e.withdrawn]
    pairings = (
        await db.scalars(select(TournamentPairing).where(TournamentPairing.tournament_id == t.id))
    ).all()
    opponents: dict[uuid.UUID, set[str]] = {}
    last: dict[uuid.UUID, str] = {}
    for p in pairings:
        if p.b_id is None:
            continue
        opponents.setdefault(p.a_id, set()).add(str(p.b_id))
        opponents.setdefault(p.b_id, set()).add(str(p.a_id))
        if p.round == number - 1:
            last[p.a_id], last[p.b_id] = str(p.b_id), str(p.a_id)
    return [
        SwissPlayer(
            id=str(e.user_id),
            seed=e.seed or 0,
            points=float(e.points),
            opponents=frozenset(opponents.get(e.user_id, ())),
            last_opponent=last.get(e.user_id),
            byes=e.byes,
        )
        for e in entries
    ]


async def compute_pairings(
    players: Sequence[SwissPlayer], number: int, *, budget_s: float
) -> Pairings:
    """Round 1 folds the seeds; later rounds run the matching in a thread within the budget
    and fall back to the greedy pairing."""
    if number == 1:
        return pair_first_round(players)
    try:
        return await asyncio.wait_for(asyncio.to_thread(pair_round, players), budget_s)
    except TimeoutError:
        log.warning("tournament.pairing_timeout", players=len(players))
        return greedy_pairing(players)


async def pair_next_round(db: AsyncSession, deps: SettleDeps, t: Tournament, now: datetime) -> None:
    """Pair and start round ``current_round + 1``: boards, byes, match rows, live games,
    and everyone's ``t.pairing`` or ``t.bye``."""
    settings = deps.settings
    number = t.current_round + 1
    players = await swiss_players(db, t, number)
    pairings = await compute_pairings(
        players, number, budget_s=settings.tournament_pairing_budget_s
    )
    subject = await _round_subject(db, t, number)
    deadline = now + timedelta(seconds=settings.tournament_round_s)
    db.add(
        TournamentRound(
            tournament_id=t.id,
            number=number,
            subject_id=subject.id,
            status=RoundStatus.LIVE.value,
            relaxations=[r.value for r in pairings.relaxations],
            started_at=now,
            deadline_at=deadline,
        )
    )
    t.current_round = number
    t.next_action_at = deadline
    await db.flush()
    cards = await load_players(db, [uuid.UUID(p.id) for p in players])
    live: list[tuple[TournamentPairing, dict[str, object], list[dict[str, object]], int]] = []
    for board, (a, b) in enumerate(pairings.pairs, start=1):
        a_id, b_id, match_id = uuid.UUID(a), uuid.UUID(b), new_id()
        pairing = TournamentPairing(
            tournament_id=t.id, round=number, board=board, a_id=a_id, b_id=b_id, match_id=match_id
        )
        db.add(pairing)
        await db.flush()
        prepared = await prepare_match(
            db,
            settings,
            match_id=match_id,
            kind=MatchKind.TOURNAMENT,
            subject_slug=subject.slug,
            contenders=[
                Contender(user_id=a_id, chapter=None, joined_ms=0),
                Contender(user_id=b_id, chapter=None, joined_ms=1),
            ],
            questions=settings.tournament_questions,
            ready_ms=settings.tournament_ready_ms,
            grace_ms=settings.tournament_grace_ms,
            extra={"tournament_id": str(t.id), "round": number},
        )
        live.append((pairing, prepared.config, prepared.questions, prepared.ttl_s))
    if pairings.bye is not None:
        bye_id = uuid.UUID(pairings.bye)
        db.add(
            TournamentPairing(
                tournament_id=t.id,
                round=number,
                board=len(pairings.pairs) + 1,
                a_id=bye_id,
                status=PairingStatus.DONE.value,
                result_a=GameResult.BYE.value,
                finished_at=now,
            )
        )
        entry = await db.get_one(TournamentEntry, (t.id, bye_id), populate_existing=True)
        entry.byes += 1
        entry.absences = 0
        await events.user_event(
            db,
            bye_id,
            "t.bye",
            {"tournament_id": str(t.id), "round": number, "points": 1},
            key=f"bye:{t.id}:{number}:{bye_id}",
        )
    await db.flush()

    # The live games, just before the commit (create.lua is idempotent).
    for pairing, config, questions, ttl_s in live:
        created = await scripts.create(
            deps.redis, str(pairing.match_id), config, questions, ttl_s=ttl_s
        )
        ready_by = created.due
        b_id = pairing.b_id or pairing.a_id  # always set on a board with a match
        for me, other in ((pairing.a_id, b_id), (b_id, pairing.a_id)):
            info = cards.get(other)
            opponent = info.card() if info is not None else {"uid": str(other)}
            await events.user_event(
                db,
                me,
                "t.pairing",
                {
                    "tournament_id": str(t.id),
                    "round": number,
                    "match_id": str(pairing.match_id),
                    "ch": f"m:{pairing.match_id}",
                    "opponent": opponent,
                    "ready_by": ready_by,
                },
                key=f"pairing:{pairing.match_id}:{me}",
            )
            await notify(
                db,
                me,
                kind="tournament_round",
                title=f"Round {number}: you vs {opponent.get('display_name') or 'your opponent'}",
                body=f"{t.title}: join within {settings.tournament_ready_ms // 1000} s.",
                icon="trophy",
                action=_action(t),
                key=f"tournament_round:{t.id}:{number}",
                time_critical=True,
            )
    await events.channel_event(
        db,
        t.id,
        "t.round",
        {
            "round": number,
            "status": "live",
            "starts_at": _ms(now),
            "ends_at": _ms(deadline),
        },
        key=f"round:{t.id}:{number}:live",
    )
    await recompute(db, t)
    await events.schedule_standings(
        db, t.id, now=now, interval_ms=settings.tournament_standings_interval_ms
    )
    if not live:
        await close_round_if_done(db, settings, t, number, now=now)


# --- The end ---------------------------------------------------------------------------------


async def finalize(db: AsyncSession, settings: Settings, t: Tournament, now: datetime) -> None:
    """Final ranks, prizes (skipping withdrawn, banned and deleted players; places shift up),
    progression, the podium in the friends' feed, and everyone's result."""
    ranked = await recompute(db, t)
    field_size = len(ranked)
    users = {
        u.id: u
        for u in await db.scalars(select(User).where(User.id.in_([e.user_id for e in ranked])))
    }
    for entry in ranked:
        entry.final_rank = entry.rank

    def eligible(entry: TournamentEntry) -> bool:
        user = users.get(entry.user_id)
        return (
            not entry.withdrawn
            and user is not None
            and user.status in {UserStatus.ACTIVE, UserStatus.RESTRICTED}
            and not user.ban_in_force(now)
        )

    places = [e for e in ranked if eligible(e)]
    place_of = {e.user_id: index for index, e in enumerate(places, start=1)}
    payout: dict[str, int] = {}
    if t.prize_pool > 0 and MIN_ENTRANTS <= field_size <= MAX_ENTRANTS:
        payout = distribute(t.prize_pool, field_size, [str(e.user_id) for e in places])

    event_id = f"tournament:{t.id}"
    for entry in sorted(ranked, key=lambda e: e.user_id):  # progress rows before wallets
        place = place_of.get(entry.user_id)
        await record_event(
            db, entry.user_id, kind=EventKind.TOURNAMENT_FINISHED, event_id=event_id, now=now
        )
        if place is not None and place <= 3:
            await record_event(
                db, entry.user_id, kind=EventKind.TOURNAMENT_PODIUM, event_id=event_id, now=now
            )
            await record_activity(
                db,
                entry.user_id,
                "podium",
                {"tournament_id": str(t.id), "name": t.title, "rank": place},
                key=f"podium:{t.id}",
                now=now,
            )
        if place == 1:
            await record_event(
                db, entry.user_id, kind=EventKind.TOURNAMENT_WON, event_id=event_id, now=now
            )
    for entry in sorted(ranked, key=lambda e: e.user_id):
        amount = payout.get(str(entry.user_id), 0)
        place = place_of.get(entry.user_id)
        if amount > 0 and place is not None:
            await db.execute(
                insert(TournamentPrize)
                .values(tournament_id=t.id, user_id=entry.user_id, place=place, amount=amount)
                .on_conflict_do_nothing()
            )
            await credit(
                db,
                entry.user_id,
                amount,
                reason=CoinReason.TOURNAMENT_PRIZE,
                title=f"Prize: {t.title} (#{place})",
                key=f"t:{t.id}:{entry.user_id}:prize",
                ref=Ref(RefKind.TOURNAMENT, str(t.id)),
            )
        xp = await tournament_xp(db, t.id, entry.user_id)
        rank = entry.final_rank or 0
        await notify(
            db,
            entry.user_id,
            kind="tournament_result",
            title=f"You finished #{rank} of {field_size}",
            body=(
                f"{t.title}: +{amount} coins and {xp} XP."
                if amount
                else f"{t.title}: {points_out(entry.points)} points and {xp} XP."
            ),
            icon="trophy",
            action={"route": f"/arena/{t.id}/results", "params": {}},
            key=f"tournament_result:{t.id}",
        )
        await events.user_event(
            db,
            entry.user_id,
            "t.finished",
            {
                "tournament_id": str(t.id),
                "rank": rank,
                "players": field_size,
                "points": points_out(entry.points),
                "prize": amount,
                "xp": xp,
            },
            key=f"finished:{t.id}:{entry.user_id}",
        )
    t.status = S.FINISHED.value
    t.finished_at = now
    t.next_action_at = None
    await events.schedule_standings(
        db, t.id, now=now, interval_ms=settings.tournament_standings_interval_ms
    )


async def cancel(db: AsyncSession, t: Tournament, *, reason: str, now: datetime) -> None:
    """Refund everyone still in (``not_enough_players`` or ``admin``): held fees are released,
    fees already captured are paid back; no prizes. Games already played keep their ratings."""
    started = t.status in {S.RUNNING, S.FINALIZING}
    for entry in await _active_entries(db, t):
        refunded = await refund_hold(db, entry, f"Refund: {t.title} cancelled")
        if refunded == 0 and started and entry.checked_in and t.entry_fee > 0:
            await credit(
                db,
                entry.user_id,
                t.entry_fee,
                reason=CoinReason.REFUND,
                title=f"Refund: {t.title} cancelled",
                key=f"t:{t.id}:{entry.user_id}:cancel_refund",
                ref=Ref(RefKind.TOURNAMENT, str(t.id)),
            )
            refunded = t.entry_fee
        why = "not enough players" if reason == "not_enough_players" else "it was called off"
        await notify(
            db,
            entry.user_id,
            kind="tournament_cancelled",
            title=f"Cancelled: {why}",
            body=(
                f"{t.title} was cancelled. Your {refunded} coins are back."
                if refunded
                else f"{t.title} was cancelled."
            ),
            icon="trophy",
            action=_action(t),
            key=f"tournament_cancelled:{t.id}",
        )
        await events.user_event(
            db,
            entry.user_id,
            "t.cancelled",
            {"tournament_id": str(t.id), "reason": reason, "refunded": refunded},
            key=f"cancelled:{t.id}:{entry.user_id}",
        )
    t.status = S.CANCELLED.value
    t.cancel_reason = reason
    t.finished_at = now
    t.next_action_at = None
    await db.flush()


# --- Recurring templates ---------------------------------------------------------------------


async def expand_templates(db: AsyncSession, *, now: datetime, days: int) -> int:
    """Create the instances of every active template starting within ``days`` (idempotent
    through ``UQ(template_id, starts_at)``); returns how many were new."""
    created = 0
    horizon = now + timedelta(days=days)
    for template in await db.scalars(select(TournamentTemplate).where(TournamentTemplate.active)):
        try:
            rule = rules.parse_rrule(template.rrule)
        except rules.RRuleError:
            log.error("tournament.bad_rrule", template_id=str(template.id))
            continue
        for starts_at in rule.occurrences(now + rules.CHECK_IN_OPENS, horizon):
            reg_opens_at = starts_at - timedelta(minutes=template.reg_opens_before_min)
            inserted = await db.scalar(
                insert(Tournament)
                .values(
                    id=new_id(),
                    template_id=template.id,
                    title=template.title,
                    description=template.description,
                    subject_id=template.subject_id,
                    goal=template.goal,
                    rounds=template.rounds,
                    entry_fee=template.entry_fee,
                    prize_pool=template.prize_pool,
                    capacity=template.capacity,
                    min_players=template.min_players,
                    reg_opens_at=reg_opens_at,
                    starts_at=starts_at,
                    status=S.SCHEDULED.value,
                    next_action_at=reg_opens_at,
                )
                .on_conflict_do_nothing(index_elements=["template_id", "starts_at"])
                .returning(Tournament.id)
            )
            created += inserted is not None
    await db.flush()
    return created
