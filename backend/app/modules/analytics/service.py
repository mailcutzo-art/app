"""Recording analytics events, for the app (``record_client_events``) and the server (``track``).

Server events are inserted directly in the caller's transaction rather than through the
outbox: they have no external effect to deliver, and writing them with the action means an
event exists exactly when the action committed.

Privacy rules, applied to both:
- a player who turned analytics off is not recorded at all;
- minors (from the birth year, each time) are stored without ``user_id``. Their events carry
  only ``session_key``, an HMAC of the device session id under a random salt for the IST day.
  Salts are deleted after two days, after which nobody can link the key to a session;
- ``props`` hold at most ``MAX_PROPS`` small scalars.
"""

import hashlib
import hmac
import math
import secrets
import uuid
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from datetime import date, datetime, timedelta
from typing import Any

from sqlalchemy import delete, insert, select
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.clock import IST
from app.core.ids import new_id
from app.modules.analytics.events import CLIENT_EVENTS, SERVER_EVENTS
from app.modules.analytics.models import AnalyticsEvent, EventSource
from app.modules.system.models import AppConfig
from app.modules.users.models import User, UserSettings
from app.modules.users.validation import minor_now

RETENTION = timedelta(days=180)
MAX_PROPS = 10
MAX_STRING = 64
# Client timestamps outside this window around the server's clock are not believed.
MAX_EVENT_AGE = timedelta(days=7)
MAX_CLOCK_SKEW = timedelta(minutes=10)
SALT_PREFIX = "analytics.salt."
# Salts of today and yesterday are kept (uploads straddle midnight); older ones are deleted.
SALT_KEEP_DAYS = 2

Scalar = str | int | float | bool | None


@dataclass(frozen=True, slots=True)
class Subject:
    """Who an event is about, as far as analytics may know."""

    enabled: bool
    is_minor: bool


async def _subject(db: AsyncSession, user_id: uuid.UUID, *, now: datetime) -> Subject:
    row = (
        await db.execute(
            select(User.birth_year, User.is_minor, UserSettings.analytics_enabled)
            .outerjoin(UserSettings, UserSettings.user_id == User.id)
            .where(User.id == user_id)
        )
    ).first()
    if row is None:
        return Subject(enabled=False, is_minor=False)
    birth_year, stored_minor, enabled = row
    return Subject(
        enabled=enabled is not False,
        is_minor=minor_now(birth_year, stored=stored_minor, now=now),
    )


def clean_props(props: Mapping[str, Any] | None) -> dict[str, Scalar]:
    """Small scalars only: other values are dropped, strings cut to ``MAX_STRING``."""
    cleaned: dict[str, Scalar] = {}
    for key, value in (props or {}).items():
        if len(cleaned) >= MAX_PROPS:
            break
        if not isinstance(key, str) or not key or len(key) > 32:
            continue
        if isinstance(value, float) and not math.isfinite(value):
            continue
        if isinstance(value, str):
            cleaned[key] = value[:MAX_STRING]
        elif value is None or isinstance(value, bool | int | float):
            cleaned[key] = value
    return cleaned


async def _daily_salt(db: AsyncSession, day: date) -> bytes:
    """The random salt for ``day`` (created on first use, shared by every process)."""
    key = f"{SALT_PREFIX}{day.isoformat()}"
    await db.execute(
        pg_insert(AppConfig)
        .values(key=key, value=secrets.token_hex(32))
        .on_conflict_do_nothing(index_elements=[AppConfig.key])
    )
    value = await db.scalar(select(AppConfig.value).where(AppConfig.key == key))
    return bytes.fromhex(str(value))


async def session_key(db: AsyncSession, session_id: uuid.UUID | None, day: date) -> str | None:
    if session_id is None:
        return None
    salt = await _daily_salt(db, day)
    return hmac.new(salt, session_id.bytes, hashlib.sha256).hexdigest()[:24]


async def track(
    db: AsyncSession,
    name: str,
    user_id: uuid.UUID | None,
    props: Mapping[str, Any] | None = None,
    *,
    now: datetime,
    session_id: uuid.UUID | None = None,
) -> bool:
    """Record a server-side funnel event in the caller's transaction; ``False`` if the player
    opted out. ``name`` must be in ``SERVER_EVENTS``."""
    if name not in SERVER_EVENTS:
        raise ValueError(f"unknown analytics event {name!r}")
    subject = Subject(enabled=True, is_minor=False)
    if user_id is not None:
        subject = await _subject(db, user_id, now=now)
        if not subject.enabled:
            return False
    day = now.astimezone(IST).date()
    await db.execute(
        insert(AnalyticsEvent).values(
            id=new_id(),
            name=name,
            props=clean_props(props),
            user_id=None if subject.is_minor else user_id,
            session_key=await session_key(db, session_id, day),
            is_minor=subject.is_minor,
            source=EventSource.SERVER.value,
            at=now,
            ist_day=day,
        )
    )
    return True


@dataclass(frozen=True, slots=True)
class ClientEvent:
    name: str
    props: dict[str, Scalar]
    at: datetime


async def record_client_events(
    db: AsyncSession,
    *,
    user_id: uuid.UUID,
    session_id: uuid.UUID,
    events: Sequence[ClientEvent],
    now: datetime,
) -> int:
    """Store the app's events; unknown names and implausible times are dropped. Returns how
    many were stored."""
    subject = await _subject(db, user_id, now=now)
    if not subject.enabled:
        return 0
    rows: list[dict[str, Any]] = []
    keys: dict[date, str | None] = {}
    for event in events:
        if event.name not in CLIENT_EVENTS:
            continue
        if not now - MAX_EVENT_AGE <= event.at <= now + MAX_CLOCK_SKEW:
            continue
        at = min(event.at, now)
        day = at.astimezone(IST).date()
        if day not in keys:
            keys[day] = await session_key(db, session_id, day)
        rows.append(
            {
                "id": new_id(),
                "name": event.name,
                "props": clean_props(event.props),
                "user_id": None if subject.is_minor else user_id,
                "session_key": keys[day],
                "is_minor": subject.is_minor,
                "source": EventSource.CLIENT.value,
                "at": at,
                "ist_day": day,
            }
        )
    if rows:
        await db.execute(insert(AnalyticsEvent), rows)
    return len(rows)


async def purge_analytics(db: AsyncSession, *, now: datetime, batch: int = 10_000) -> int:
    """Delete events older than 180 days, and the session salts of days before yesterday."""
    today = now.astimezone(IST).date()
    old_salts = [
        key
        for key in await db.scalars(
            select(AppConfig.key).where(AppConfig.key.startswith(SALT_PREFIX))
        )
        if key.removeprefix(SALT_PREFIX) < (today - timedelta(days=SALT_KEEP_DAYS - 1)).isoformat()
    ]
    if old_salts:
        await db.execute(delete(AppConfig).where(AppConfig.key.in_(old_salts)))
        await db.commit()
    total = 0
    while True:
        old = select(AnalyticsEvent.id).where(AnalyticsEvent.at < now - RETENTION).limit(batch)
        result = await db.execute(
            delete(AnalyticsEvent).where(AnalyticsEvent.id.in_(old.scalar_subquery()))
        )
        count = int(getattr(result, "rowcount", 0) or 0)
        await db.commit()
        total += count
        if count < batch:
            return total
