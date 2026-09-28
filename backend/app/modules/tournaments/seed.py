"""Starter recurring tournaments, so the Arena is never empty in a fresh environment.

``python -m app.modules.tournaments.seed`` adds the templates below (by title; existing ones
are left alone) and creates their instances for the next 7 days. The worker keeps extending
them from then on.
"""

import asyncio
from dataclasses import dataclass

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.clock import utc_now
from app.core.config import get_settings
from app.core.db import create_engine, create_sessionmaker
from app.modules.content.models import Subject
from app.modules.tournaments.lifecycle import expand_templates
from app.modules.tournaments.models import TournamentTemplate


@dataclass(frozen=True, slots=True)
class Starter:
    title: str
    subject: str | None
    goal: str
    rrule: str
    entry_fee: int
    prize_pool: int
    rounds: int = 5
    capacity: int = 64
    description: str = ""


STARTERS: tuple[Starter, ...] = (
    Starter(
        "Physics Evening Cup",
        "physics",
        "any",
        "FREQ=DAILY;BYHOUR=19;BYMINUTE=0",
        10,
        500,
        description="A quick Swiss cup every evening for NEET and JEE aspirants.",
    ),
    Starter(
        "Chemistry Evening Cup",
        "chemistry",
        "any",
        "FREQ=DAILY;BYHOUR=20;BYMINUTE=30",
        10,
        500,
        description="Every evening: five rounds of 10 chemistry questions.",
    ),
    Starter(
        "Biology Sunday Open",
        "biology",
        "neet",
        "FREQ=WEEKLY;BYDAY=SU;BYHOUR=18;BYMINUTE=0",
        25,
        2500,
        rounds=6,
        capacity=128,
        description="The weekly NEET Biology open.",
    ),
    Starter(
        "Maths Saturday Open",
        "maths",
        "jee",
        "FREQ=WEEKLY;BYDAY=SA;BYHOUR=18;BYMINUTE=0",
        25,
        2500,
        rounds=6,
        capacity=128,
        description="The weekly JEE Maths open.",
    ),
    Starter(
        "NEET Free Warm-up",
        None,
        "neet",
        "FREQ=DAILY;BYHOUR=17;BYMINUTE=0",
        0,
        0,
        rounds=3,
        description="Free to enter: one round each of Physics, Chemistry and Biology.",
    ),
    Starter(
        "JEE Free Warm-up",
        None,
        "jee",
        "FREQ=DAILY;BYHOUR=17;BYMINUTE=30",
        0,
        0,
        rounds=3,
        description="Free to enter: one round each of Physics, Chemistry and Maths.",
    ),
)


async def seed_templates(db: AsyncSession) -> int:
    """Add the missing starter templates; returns how many were added."""
    subjects = {s.slug: s.id for s in await db.scalars(select(Subject))}
    existing = set(await db.scalars(select(TournamentTemplate.title)))
    added = 0
    for starter in STARTERS:
        if starter.title in existing or (starter.subject and starter.subject not in subjects):
            continue
        db.add(
            TournamentTemplate(
                title=starter.title,
                description=starter.description,
                subject_id=subjects[starter.subject] if starter.subject else None,
                goal=starter.goal,
                rounds=starter.rounds,
                entry_fee=starter.entry_fee,
                prize_pool=starter.prize_pool,
                capacity=starter.capacity,
                min_players=8,
                rrule=starter.rrule,
                reg_opens_before_min=24 * 60,
            )
        )
        added += 1
    await db.flush()
    return added


async def main() -> None:
    settings = get_settings()
    engine = create_engine(settings, application_name="quiz-tournament-seed")
    try:
        async with create_sessionmaker(engine)() as db:
            added = await seed_templates(db)
            created = await expand_templates(db, now=utc_now(), days=settings.tournament_days_ahead)
            await db.commit()
        print(f"templates added: {added}, tournaments created: {created}")  # noqa: T201
    finally:
        await engine.dispose()


if __name__ == "__main__":
    asyncio.run(main())
