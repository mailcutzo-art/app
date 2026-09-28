"""``POST /v1/reports``: reporting a player (cheating, an offensive name, harassment...)."""

import uuid
from typing import Annotated

from fastapi import APIRouter, Depends
from pydantic import Field, field_validator

from app.core.clock import ClockDep
from app.core.db import SessionDep
from app.core.ratelimit import rate_limit
from app.core.schemas import ApiModel, Lax
from app.core.security import CurrentAuth
from app.modules.moderation.models import MAX_NOTE, ReportReason
from app.modules.moderation.service import file_report

router = APIRouter(tags=["moderation"])


class ReportIn(ApiModel):
    user_id: Lax[uuid.UUID]
    match_id: Lax[uuid.UUID] | None = None
    reason: Lax[ReportReason]
    note: Annotated[str | None, Field(max_length=MAX_NOTE)] = None

    @field_validator("note")
    @classmethod
    def _blank_is_none(cls, value: str | None) -> str | None:
        return value.strip() or None if value is not None else None


@router.post(
    "/reports",
    status_code=202,
    dependencies=[
        # 10 an hour: enough to report everyone in a group battle, not to flood the queue.
        Depends(rate_limit("reports", capacity=10, refill_per_sec=10 / 3600, scope="user"))
    ],
)
async def report_user(body: ReportIn, auth: CurrentAuth, db: SessionDep, clock: ClockDep) -> None:
    """Queued for the moderators; the reporter isn't told the outcome."""
    await file_report(
        db,
        auth.user_id,
        reported_id=body.user_id,
        reason=body.reason,
        match_id=body.match_id,
        note=body.note,
        now=clock(),
    )
