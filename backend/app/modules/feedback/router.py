"""``POST /v1/feedback``: "Report a problem", ideas, coin questions and appeals."""

import re
from typing import Annotated

from fastapi import APIRouter, Depends
from pydantic import Field, field_validator
from starlette.requests import Request

from app.core.db import SessionDep
from app.core.ratelimit import rate_limit
from app.core.schemas import ApiModel, Lax, field_error
from app.core.security import CurrentAuth
from app.modules.feedback.models import MAX_MESSAGE, Feedback, FeedbackKind
from app.modules.system.runtime import APP_BUILD_HEADER

router = APIRouter(tags=["feedback"])

_REQUEST_ID = re.compile(r"[A-Za-z0-9._-]{8,128}")


class FeedbackIn(ApiModel):
    kind: Lax[FeedbackKind]
    message: Annotated[str, Field(max_length=MAX_MESSAGE)]
    # The last error's reference (``X-Request-ID``), attached by the app.
    request_id: str | None = None

    @field_validator("message")
    @classmethod
    def _not_blank(cls, value: str) -> str:
        value = value.strip()
        if not value:
            raise field_error("Tell us a little more.")
        return value

    @field_validator("request_id")
    @classmethod
    def _request_id(cls, value: str | None) -> str | None:
        if value is not None and not _REQUEST_ID.fullmatch(value):
            raise field_error("This isn't a valid reference.")
        return value


@router.post(
    "/feedback",
    status_code=202,
    dependencies=[
        # 5 an hour: enough for a follow-up, not for flooding the support queue.
        Depends(rate_limit("feedback", capacity=5, refill_per_sec=5 / 3600, scope="user"))
    ],
)
async def send_feedback(
    body: FeedbackIn, request: Request, auth: CurrentAuth, db: SessionDep
) -> None:
    """Stored for the support team; answered by email or in the inbox."""
    build = request.headers.get(APP_BUILD_HEADER, "")
    db.add(
        Feedback(
            user_id=auth.user_id,
            kind=body.kind.value,
            message=body.message,
            request_id=body.request_id,
            app_build=int(build) if build.isdigit() and len(build) < 10 else None,
        )
    )
