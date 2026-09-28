"""Writing the boards: every entry is computed from Postgres and written as an absolute score.

Nothing is ever incremented in Redis. When something changes (an XP award, a settled match, a
ban), the affected player's entries are recomputed from the source tables and written with
``ZADD`` (or removed with ``ZREM`` when the player isn't eligible or is hidden), so replays,
out-of-order deliveries and the nightly rebuild all converge on the same boards.

**What counts:**

- ``weekly_xp``: the sum of ``xp_events`` in the IST week, except Practice Bot games and casual
  games beyond the third of a pair within 24 hours (``casual_excluded``).
- ``weekly:{subject}``: the points scored in settled rated, casual and tournament games against
  people in the subject that week (the same casual rule). A player is on it after one game.
- ``rating:{scope}``: players with at least 10 rated games whose RD, aged for the time since
  their last rated game (Glicko-2 fractional periods), is at most 110. The stored RD is never
  aged here: ``ratings.service.apply_game`` ages it from ``last_played_at`` at the next game.

**Hidden** players are on no board: banned, pending deletion or deleted accounts, the moderation
shadow pool (players under an anti-cheat review), and anyone who opted out of public boards.
"""

import uuid
from collections import defaultdict
from collections.abc import Collection, Iterable, Mapping
from dataclasses import dataclass
from datetime import UTC, date, datetime, timedelta
from typing import Any

from redis.asyncio import Redis
from sqlalchemy import and_, exists, func, or_, select, union
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import aliased

from app.modules.content.models import ExamGoal, GoalSubject, Subject
from app.modules.leaderboards import keys
from app.modules.leaderboards.keys import ALL, VIEWS
from app.modules.matches.models import Match, MatchKind, MatchParticipant, MatchStatus
from app.modules.moderation.models import ModerationKind
from app.modules.moderation.service import in_force
from app.modules.progression.models import XpEvent
from app.modules.ratings import glicko2
from app.modules.ratings.models import OVERALL, Rating
from app.modules.ratings.service import SECONDS_PER_PERIOD, shown, to_glicko
from app.modules.users.models import HIDDEN_STATUSES, User, UserSettings, UserStatus

POINTS_KINDS = (
    MatchKind.QUICK_RATED.value,
    MatchKind.QUICK_CASUAL.value,
    MatchKind.TOURNAMENT.value,
)
CASUAL_PAIR_LIMIT = 3
CASUAL_WINDOW = timedelta(hours=24)
MILESTONES = (3, 10, 100)
CHUNK = 1000


@dataclass(frozen=True, slots=True)
class Entry:
    value: int
    reached_at: datetime

    @property
    def score(self) -> float:
        return keys.encode(self.value, self.reached_at)


@dataclass(frozen=True, slots=True)
class Target:
    """One stored board, in every view: ``xp`` (a week), ``wk`` (a subject and week) or ``r``
    (a rating scope)."""

    kind: str
    subject: str | None = None
    week: date | None = None

    def key(self, view: str) -> str:
        if self.kind == "xp" and self.week is not None:
            return keys.xp_key(view, self.week)
        if self.kind == "wk" and self.subject is not None and self.week is not None:
            return keys.subject_key(view, self.subject, self.week)
        if self.kind == "r" and self.subject is not None:
            return keys.rating_key(view, self.subject)
        raise ValueError(f"incomplete board target {self}")

    def board(self, current_week: date) -> keys.Board:
        last = self.week is not None and self.week < current_week
        if self.kind == "xp":
            return keys.Board(keys.Family.WEEKLY_XP, last=last)
        if self.kind == "wk":
            return keys.Board(keys.Family.WEEKLY_SUBJECT, self.subject, last=last)
        return keys.Board(keys.Family.RATING, self.subject)


@dataclass(frozen=True, slots=True)
class Catalog:
    """Subjects by slug (in display order) and the exams that include each."""

    names: dict[str, str]
    goals: dict[str, frozenset[str]]

    def allowed(self, subject: str | None, view: str) -> bool:
        """Whether a board about ``subject`` exists in ``view`` (NEET has no Maths)."""
        if view == ALL or subject is None or subject == OVERALL:
            return True
        return view in self.goals.get(subject, frozenset())

    def subjects_in(self, view: str) -> list[str]:
        return [slug for slug in self.names if self.allowed(slug, view)]


async def load_catalog(db: AsyncSession) -> Catalog:
    subjects = (await db.execute(select(Subject.slug, Subject.name).order_by(Subject.sort))).all()
    goals: dict[str, set[str]] = defaultdict(set)
    rows = await db.execute(
        select(Subject.slug, ExamGoal.slug)
        .join(GoalSubject, GoalSubject.subject_id == Subject.id)
        .join(ExamGoal, ExamGoal.id == GoalSubject.goal_id)
    )
    for subject, goal in rows:
        goals[subject].add(goal)
    return Catalog(
        names={row[0]: row[1] for row in subjects},
        goals={slug: frozenset(goals.get(slug, set())) for slug, _ in subjects},
    )


# --- Who is hidden ------------------------------------------------------------------------------


async def hidden_ids(
    db: AsyncSession, *, now: datetime, among: Collection[uuid.UUID] | None = None
) -> set[uuid.UUID]:
    """Players no board shows (``among`` limits the check to these ids)."""
    banned = and_(
        User.status == UserStatus.BANNED.value,
        or_(User.banned_until.is_(None), User.banned_until > now),
    )
    statuses = select(User.id).where(or_(User.status.in_(HIDDEN_STATUSES), banned))
    shadow = select(User.id).where(in_force(ModerationKind.SHADOW_POOL, User.id, now))
    opted_out = select(UserSettings.user_id).where(UserSettings.public_boards.is_(False))
    if among is not None:
        ids = list(among)
        if not ids:
            return set()
        statuses = statuses.where(User.id.in_(ids))
        shadow = shadow.where(User.id.in_(ids))
        opted_out = opted_out.where(UserSettings.user_id.in_(ids))
    return set(await db.scalars(union(statuses, shadow, opted_out)))


async def goals_of(
    db: AsyncSession, user_ids: Collection[uuid.UUID]
) -> dict[uuid.UUID, str | None]:
    found: dict[uuid.UUID, str | None] = {}
    ids = list(user_ids)
    for start in range(0, len(ids), CHUNK):
        rows = await db.execute(
            select(User.id, User.goal).where(User.id.in_(ids[start : start + CHUNK]))
        )
        found.update({row[0]: row[1] for row in rows})
    return found


# --- Entries from Postgres ----------------------------------------------------------------------


async def casual_excluded(
    db: AsyncSession, since: datetime, until: datetime, *, user_id: uuid.UUID | None = None
) -> set[uuid.UUID]:
    """Settled casual matches in ``[since, until)`` that don't count: the fourth and later game
    of the same pair within 24 hours (by finish time). A pair's games count or not for both."""
    humans = (
        select(MatchParticipant.match_id, func.array_agg(MatchParticipant.user_id).label("uids"))
        .where(MatchParticipant.user_id.is_not(None))
        .group_by(MatchParticipant.match_id)
        .subquery()
    )
    statement = (
        select(Match.id, Match.finished_at, humans.c.uids)
        .join(humans, humans.c.match_id == Match.id)
        .where(
            Match.kind == MatchKind.QUICK_CASUAL.value,
            Match.status == MatchStatus.SETTLED.value,
            Match.finished_at >= since - CASUAL_WINDOW,
            Match.finished_at < until,
        )
    )
    if user_id is not None:
        mine = aliased(MatchParticipant)
        statement = statement.where(
            exists().where(mine.match_id == Match.id, mine.user_id == user_id)
        )
    games: dict[tuple[uuid.UUID, ...], list[tuple[datetime, uuid.UUID]]] = defaultdict(list)
    for match_id, finished_at, uids in await db.execute(statement):
        if len(uids) == 2 and finished_at is not None:
            games[tuple(sorted(uids))].append((finished_at, match_id))
    excluded: set[uuid.UUID] = set()
    for played in games.values():
        played.sort()
        for index, (finished_at, match_id) in enumerate(played):
            earlier = sum(1 for other, _ in played[:index] if other > finished_at - CASUAL_WINDOW)
            if earlier >= CASUAL_PAIR_LIMIT and finished_at >= since:
                excluded.add(match_id)
    return excluded


def _week_bounds(week: date) -> tuple[datetime, datetime]:
    return keys.week_start(week), keys.week_start(week + timedelta(days=7))


async def weekly_xp(
    db: AsyncSession, week: date, *, user_id: uuid.UUID | None = None
) -> dict[uuid.UUID, Entry]:
    """XP per player in ``week`` (only players with some)."""
    start, end = _week_bounds(week)
    excluded = await casual_excluded(db, start, end, user_id=user_id)
    statement = (
        select(XpEvent.user_id, func.sum(XpEvent.amount), func.max(XpEvent.created_at))
        .where(
            XpEvent.ist_day >= week,
            XpEvent.ist_day < week + timedelta(days=7),
            XpEvent.amount > 0,
            XpEvent.game_kind.is_distinct_from(MatchKind.BOT.value),
        )
        .group_by(XpEvent.user_id)
    )
    if excluded:
        statement = statement.where(
            ~and_(
                XpEvent.game_kind == MatchKind.QUICK_CASUAL.value,
                XpEvent.ref_id.in_(list(excluded)),
            )
        )
    if user_id is not None:
        statement = statement.where(XpEvent.user_id == user_id)
    return {
        uid: Entry(int(total), reached_at)
        for uid, total, reached_at in await db.execute(statement)
        if total and total > 0
    }


async def weekly_points(
    db: AsyncSession,
    week: date,
    *,
    user_id: uuid.UUID | None = None,
    subject: str | None = None,
) -> dict[tuple[uuid.UUID, str], Entry]:
    """Battle points per player and subject in ``week``, from games against people."""
    start, end = _week_bounds(week)
    excluded = await casual_excluded(db, start, end, user_id=user_id)
    bot = aliased(MatchParticipant)
    statement = (
        select(
            MatchParticipant.user_id,
            Subject.slug,
            func.sum(MatchParticipant.score),
            func.max(Match.finished_at),
        )
        .join(Match, Match.id == MatchParticipant.match_id)
        .join(Subject, Subject.id == Match.subject_id)
        .where(
            MatchParticipant.user_id.is_not(None),
            Match.kind.in_(POINTS_KINDS),
            Match.status == MatchStatus.SETTLED.value,
            Match.finished_at >= start,
            Match.finished_at < end,
            ~exists().where(bot.match_id == Match.id, bot.is_bot.is_(True)),
        )
        .group_by(MatchParticipant.user_id, Subject.slug)
    )
    if excluded:
        statement = statement.where(Match.id.not_in(list(excluded)))
    if user_id is not None:
        statement = statement.where(MatchParticipant.user_id == user_id)
    if subject is not None:
        statement = statement.where(Subject.slug == subject)
    return {
        (uid, slug): Entry(max(0, int(points or 0)), finished_at or start)
        for uid, slug, points, finished_at in await db.execute(statement)
        if uid is not None
    }


def aged_rd(row: Rating, now: datetime) -> float:
    """The RD after growing for the idle time since the last rated game."""
    if row.last_played_at is None or row.games == 0:
        return row.rd
    periods = max(0.0, (now - row.last_played_at).total_seconds() / SECONDS_PER_PERIOD)
    return glicko2.age(to_glicko(row), periods).rd


def rating_eligible(row: Rating | None, now: datetime) -> bool:
    return (
        row is not None
        and row.games >= glicko2.RANKED_MIN_GAMES
        and aged_rd(row, now) <= glicko2.PROVISIONAL_RD
    )


def games_to_rank(row: Rating | None, now: datetime) -> int:
    """Rated games still needed to appear (at least 1 while off the board)."""
    games = row.games if row is not None else 0
    if rating_eligible(row, now):
        return 0
    return max(1, glicko2.RANKED_MIN_GAMES - games)


def rating_entry(row: Rating) -> Entry:
    """The board entry of a rating (reached when it last changed)."""
    return Entry(shown(row.rating), row.last_played_at or datetime.fromtimestamp(0, UTC))


async def rating_entries(
    db: AsyncSession, *, now: datetime, user_id: uuid.UUID | None = None
) -> dict[tuple[uuid.UUID, str], Entry]:
    """Eligible ratings per player and scope."""
    statement = select(Rating).where(
        Rating.games >= glicko2.RANKED_MIN_GAMES, Rating.last_played_at.is_not(None)
    )
    if user_id is not None:
        statement = statement.where(Rating.user_id == user_id)
    return {
        (row.user_id, row.scope): rating_entry(row)
        for row in await db.scalars(statement)
        if rating_eligible(row, now)
    }


# --- Writing ------------------------------------------------------------------------------------


def primary_view(goal: str | None) -> str:
    """The view a player sees by default (their exam, or All India without one)."""
    return goal if goal in VIEWS else ALL


async def position(redis: Redis, key: str, user_id: uuid.UUID) -> int | None:
    rank: Any = await redis.zrevrank(key, str(user_id))
    return None if rank is None else int(rank) + 1


@dataclass(frozen=True, slots=True)
class Move:
    """A player's position on one board before and after a write (their own view)."""

    target: Target
    before: int | None
    after: int | None

    def crossed(self) -> int | None:
        """The best milestone (top 3, 10 or 100) this move entered, if any."""
        if self.after is None:
            return None
        for threshold in MILESTONES:
            if self.after <= threshold and (self.before is None or self.before > threshold):
                return threshold
        return None


async def write_user(
    redis: Redis,
    user_id: uuid.UUID,
    entries: Mapping[Target, Entry | None],
    *,
    goal: str | None,
    hidden: bool,
    catalog: Catalog,
) -> list[Move]:
    """Put the player's ``entries`` on every view they belong to and take them off the rest;
    returns their moves on their own view."""
    uid = str(user_id)
    mine = keys.views_for(goal)
    primary = primary_view(goal)
    before = {target: await position(redis, target.key(primary), user_id) for target in entries}
    pipe = redis.pipeline(transaction=True)
    for target, entry in entries.items():
        for view in VIEWS:
            key = target.key(view)
            if (
                entry is not None
                and not hidden
                and view in mine
                and catalog.allowed(target.subject, view)
            ):
                pipe.zadd(key, {uid: entry.score})
                if target.week is not None:
                    pipe.expireat(key, keys.weekly_expiry(target.week))
            else:
                pipe.zrem(key, uid)
    await pipe.execute()
    return [
        Move(target, before[target], await position(redis, target.key(primary), user_id))
        for target in entries
    ]


async def rebuild_target(
    redis: Redis,
    target: Target,
    entries: Mapping[uuid.UUID, Entry],
    *,
    goals: Mapping[uuid.UUID, str | None],
    hidden: Collection[uuid.UUID],
    catalog: Catalog,
) -> dict[str, int]:
    """Replace the board in every view by ``entries``: written to ``{key}:tmp`` and renamed
    over the live key in one step (readers never see a half-built board). Returns sizes."""
    per_view: dict[str, list[tuple[str, float]]] = {view: [] for view in VIEWS}
    for user_id, entry in entries.items():
        if user_id in hidden:
            continue
        for view in keys.views_for(goals.get(user_id)):
            if catalog.allowed(target.subject, view):
                per_view[view].append((str(user_id), entry.score))
    sizes: dict[str, int] = {}
    for view, members in per_view.items():
        key = target.key(view)
        tmp = keys.tmp_key(key)
        await redis.delete(tmp)
        for chunk in _chunks(members, CHUNK):
            await redis.zadd(tmp, dict(chunk))
        if members:
            pipe = redis.pipeline(transaction=True)
            pipe.rename(tmp, key)
            if target.week is not None:
                pipe.expireat(key, keys.weekly_expiry(target.week))
            await pipe.execute()
        else:
            await redis.delete(key)
        sizes[view] = len(members)
    return sizes


def _chunks(items: list[tuple[str, float]], size: int) -> Iterable[list[tuple[str, float]]]:
    for start in range(0, len(items), size):
        yield items[start : start + size]
