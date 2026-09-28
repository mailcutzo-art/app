"""Worker jobs for the leaderboards (IST times, each once a day across replicas):

- **Snapshot** (from 00:00): every live board is copied to ``{key}:snap``; ``change_1d`` compares
  with it all day. A weekly board that hasn't started yet (Monday) has no snapshot.
- **Weekly rollover** (Mondays from 00:00): the week that just ended stays readable as
  ``:last`` (its keys simply stop being this week's). Every player on last week's XP board gets
  a ``weekly_result`` recap, and each weekly #1 per subject and exam a "Physics Champion ·
  Week 39" badge with an ``achievement`` inbox item.
- **Rebuild** (from 03:00): every board of this week and last week and every rating board is
  recomputed from Postgres into ``{key}:tmp`` and renamed into place. Stale ratings drop off
  here: RD grows for idle time (Glicko-2 fractional periods), and a player above 110 leaves the
  rating boards until they play again. Lifted bans, ended shadow-pool stays and exam changes
  are picked up too.
"""

import uuid
from datetime import date, datetime, timedelta
from typing import Any

import structlog
from redis.asyncio import Redis
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.core.clock import IST, Clock, utc_now
from app.core.jobs import once_per_day
from app.core.resources import Resources
from app.modules.leaderboards import boards, keys
from app.modules.leaderboards.boards import Catalog, Entry, Target
from app.modules.leaderboards.models import LeaderboardBadge
from app.modules.notifications.service import notify
from app.modules.ratings.models import OVERALL

log = structlog.stdlib.get_logger("app.worker")

REBUILD_HOUR_IST = 3
RECAP_BATCH = 500


def live_targets(catalog: Catalog, now: datetime, *, last: bool = True) -> list[Target]:
    """Every stored board: this week's (and last week's) and the ratings."""
    current = keys.week_of(now)
    weeks = [current, current - timedelta(days=7)] if last else [current]
    targets = [Target("xp", week=week) for week in weeks]
    targets += [Target("wk", subject, week) for week in weeks for subject in catalog.names]
    targets += [Target("r", scope) for scope in (OVERALL, *catalog.names)]
    return targets


async def snapshot_boards(redis: Redis, catalog: Catalog, *, now: datetime) -> int:
    """Copy this week's boards and the rating boards to ``:snap``; returns how many."""
    copied = 0
    for target in live_targets(catalog, now, last=False):
        for view in keys.VIEWS:
            key = target.key(view)
            snap = keys.snap_key(key)
            if await redis.copy(key, snap, replace=True):
                if target.week is not None:
                    await redis.expireat(snap, keys.weekly_expiry(target.week))
                copied += 1
            else:
                await redis.delete(snap)
    return copied


async def rebuild_boards(db: AsyncSession, redis: Redis, *, now: datetime) -> dict[str, int]:
    """Recompute every live board from Postgres; returns the All India sizes by key."""
    catalog = await boards.load_catalog(db)
    current = keys.week_of(now)
    per_target: dict[Target, dict[uuid.UUID, Entry]] = {}
    for week in (current, current - timedelta(days=7)):
        per_target[Target("xp", week=week)] = await boards.weekly_xp(db, week)
        points = await boards.weekly_points(db, week)
        for subject in catalog.names:
            per_target[Target("wk", subject, week)] = {
                uid: entry for (uid, slug), entry in points.items() if slug == subject
            }
    ratings = await boards.rating_entries(db, now=now)
    for scope in (OVERALL, *catalog.names):
        per_target[Target("r", scope)] = {
            uid: entry for (uid, found), entry in ratings.items() if found == scope
        }
    everyone = {uid for entries in per_target.values() for uid in entries}
    goals = await boards.goals_of(db, everyone)
    hidden = await boards.hidden_ids(db, now=now)
    await db.commit()
    sizes: dict[str, int] = {}
    for target, entries in per_target.items():
        built = await boards.rebuild_target(
            redis, target, entries, goals=goals, hidden=hidden, catalog=catalog
        )
        sizes[target.key(keys.ALL)] = built[keys.ALL]
    return sizes


async def _board_top(redis: Redis, key: str, count: int) -> list[tuple[str, int]]:
    found: list[Any] = await redis.zrevrange(key, 0, count - 1, withscores=True)
    return [(str(member), keys.decode(float(score))) for member, score in found]


async def crown_champions(
    sessionmaker: async_sessionmaker[AsyncSession], redis: Redis, week: date, *, now: datetime
) -> int:
    """A badge and an inbox item for each #1 of ``week``'s subject boards, per exam."""
    crowned = 0
    async with sessionmaker() as db:
        catalog = await boards.load_catalog(db)
    number = keys.week_number(week)
    for goal in ("neet", "jee"):
        for subject in catalog.subjects_in(goal):
            top = await _board_top(redis, keys.subject_key(goal, subject, week), 1)
            if not top:
                continue
            member, value = top[0]
            user_id = uuid.UUID(member)
            title = f"{catalog.names[subject]} Champion · Week {number}"
            async with sessionmaker() as db:
                inserted = await db.scalar(
                    insert(LeaderboardBadge)
                    .values(
                        user_id=user_id,
                        board=f"weekly:{subject}",
                        goal=goal,
                        week=week,
                        title=title,
                        value=value,
                        created_at=now,
                    )
                    .on_conflict_do_nothing()
                    .returning(LeaderboardBadge.id)
                )
                if inserted is not None:
                    await notify(
                        db,
                        user_id,
                        kind="achievement",
                        title=title,
                        body=(
                            f"You finished #1 in {catalog.names[subject]} last week "
                            f"({goal.upper()}) with {value} points."
                        ),
                        icon="trophy",
                        action={
                            "route": "/leaderboards",
                            "params": {"board": f"weekly:{subject}:last", "goal": goal},
                        },
                        key=f"champion:{subject}:{goal}:{week.isoformat()}",
                    )
                    crowned += 1
                await db.commit()
    return crowned


async def send_recaps(
    sessionmaker: async_sessionmaker[AsyncSession], redis: Redis, week: date
) -> int:
    """``weekly_result`` for everyone on ``week``'s All India XP board."""
    key = keys.xp_key(keys.ALL, week)
    number = keys.week_number(week)
    sent = 0
    start = 0
    while True:
        found: list[Any] = await redis.zrevrange(
            key, start, start + RECAP_BATCH - 1, withscores=True
        )
        if not found:
            break
        async with sessionmaker() as db:
            for offset, (member, score) in enumerate(found):
                position = start + offset + 1
                created = await notify(
                    db,
                    uuid.UUID(str(member)),
                    kind="weekly_result",
                    title=f"Week {number}: you finished #{position}",
                    body=f"{keys.decode(float(score))} XP last week. A fresh week starts now.",
                    icon="trophy",
                    action={"route": "/leaderboards", "params": {"board": "weekly_xp:last"}},
                    key=f"weekly_result:{week.isoformat()}",
                )
                sent += created is not None
            await db.commit()
        start += RECAP_BATCH
    return sent


async def leaderboards_job(resources: Resources, *, clock: Clock = utc_now) -> None:
    now = clock()
    local = now.astimezone(IST)
    today = local.date()

    async def snapshot() -> None:
        async with resources.sessionmaker() as db:
            catalog = await boards.load_catalog(db)
        copied = await snapshot_boards(resources.redis, catalog, now=now)
        log.info("leaderboards.snapshot", boards=copied)

    async def rollover() -> None:
        ended = keys.week_of(now) - timedelta(days=7)
        crowned = await crown_champions(resources.sessionmaker, resources.redis, ended, now=now)
        sent = await send_recaps(resources.sessionmaker, resources.redis, ended)
        log.info("leaderboards.rollover", week=ended.isoformat(), champions=crowned, recaps=sent)

    async def rebuild() -> None:
        async with resources.sessionmaker() as db:
            sizes = await rebuild_boards(db, resources.redis, now=now)
        log.info("leaderboards.rebuilt", boards=len(sizes), players=sum(sizes.values()))

    await once_per_day(resources.redis, "lb_snapshot", today, snapshot, lease_ttl_s=600)
    if today.weekday() == 0:
        await once_per_day(resources.redis, "lb_rollover", today, rollover, lease_ttl_s=1800)
    if local.hour >= REBUILD_HOUR_IST:
        await once_per_day(resources.redis, "lb_rebuild", today, rebuild, lease_ttl_s=1800)
