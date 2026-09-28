"""``POST /v1/events`` (the app's few screen events) and the analytics toggle in Settings."""

import re
from datetime import datetime
from typing import Annotated, Any

from fastapi import APIRouter, Depends
from pydantic import Field, field_validator

from app.core.clock import ClockDep
from app.core.db import SessionDep
from app.core.ratelimit import rate_limit
from app.core.schemas import ApiModel, Lax, field_error
from app.core.security import CurrentAuth
from app.modules.analytics.service import (
    MAX_PROPS,
    MAX_STRING,
    ClientEvent,
    Scalar,
    record_client_events,
)
from app.modules.users.settings import locked_settings, read_settings

router = APIRouter(tags=["analytics"])

MAX_EVENTS = 20
_NAME = re.compile(r"[a-z][a-z0-9_]{0,47}")
_PROP_KEY = re.compile(r"[a-z][a-z0-9_]{0,31}")


class EventIn(ApiModel):
    name: Annotated[str, Field(max_length=48)]
    props: dict[str, Scalar] = Field(default_factory=dict)
    at: Lax[datetime]

    @field_validator("name")
    @classmethod
    def _name(cls, value: str) -> str:
        if not _NAME.fullmatch(value):
            raise field_error("Event names are lowercase words joined by underscores.")
        return value

    @field_validator("props")
    @classmethod
    def _small_scalars(cls, value: dict[str, Any]) -> dict[str, Any]:
        if len(value) > MAX_PROPS:
            raise field_error(f"Send at most {MAX_PROPS} properties.")
        for key, item in value.items():
            if not _PROP_KEY.fullmatch(key):
                raise field_error("Property names are lowercase words joined by underscores.")
            if isinstance(item, str) and len(item) > MAX_STRING:
                raise field_error(f"Property values are at most {MAX_STRING} characters.")
        return value

    @field_validator("at")
    @classmethod
    def _aware(cls, value: datetime) -> datetime:
        if value.tzinfo is None:
            raise field_error("Include the time zone.")
        return value


class EventsIn(ApiModel):
    events: Annotated[list[EventIn], Field(min_length=1, max_length=MAX_EVENTS)]


class EventsOut(ApiModel):
    accepted: int


class AppSettings(ApiModel):
    analytics: bool


@router.post(
    "/events",
    status_code=202,
    dependencies=[
        Depends(rate_limit("analytics.events", capacity=30, refill_per_sec=0.5, scope="user"))
    ],
)
async def post_events(
    body: EventsIn, auth: CurrentAuth, db: SessionDep, clock: ClockDep
) -> EventsOut:
    """Up to 20 allowlisted events. Unknown names, and times more than 7 days old or in the
    future, are dropped; nothing is stored for players who turned analytics off."""
    accepted = await record_client_events(
        db,
        user_id=auth.user_id,
        session_id=auth.session_id,
        events=[ClientEvent(event.name, dict(event.props), event.at) for event in body.events],
        now=clock(),
    )
    return EventsOut(accepted=accepted)


@router.get("/me/settings/app")
async def read_app_settings(auth: CurrentAuth, db: SessionDep) -> AppSettings:
    prefs = await read_settings(db, auth.user_id)
    return AppSettings(analytics=prefs.analytics_enabled)


@router.put(
    "/me/settings/app",
    dependencies=[
        Depends(rate_limit("settings.write", capacity=30, refill_per_sec=0.5, scope="user"))
    ],
)
async def update_app_settings(body: AppSettings, auth: CurrentAuth, db: SessionDep) -> AppSettings:
    """The analytics toggle: off stops recording anything about the player."""
    row = await locked_settings(db, auth.user_id)
    row.analytics_enabled = body.analytics
    await db.flush()
    return AppSettings(analytics=row.analytics_enabled)
