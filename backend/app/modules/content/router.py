"""Learn: the catalog, search, single questions, question reports and Fun & Learn passages."""

from typing import Annotated, Literal

from fastapi import APIRouter, Depends, Query
from pydantic import StringConstraints
from starlette.requests import Request
from starlette.responses import Response

from app.core.clock import ClockDep
from app.core.db import SessionDep
from app.core.errors import NotFound
from app.core.ratelimit import rate_limit
from app.core.schemas import ApiModel
from app.core.security import CurrentAuth
from app.modules.content import reports
from app.modules.content.catalog import (
    build_catalog,
    catalog_etag,
    content_version,
    etag_matches,
    resolve_goal,
)
from app.modules.content.refs import parse_ref
from app.modules.content.schemas import CatalogOut, PassagesOut, QuestionOut, SearchOut
from app.modules.content.service import list_passages, search_questions, subject_id_for
from app.modules.content.views import bookmarked_ids, visible_view

router = APIRouter(tags=["learn"])

GoalQuery = Annotated[str | None, Query(max_length=32)]
SubjectQuery = Annotated[str | None, Query(max_length=64)]


@router.get(
    "/catalog",
    response_model=CatalogOut,
    responses={304: {"description": "Unchanged since the ETag sent in If-None-Match"}},
)
async def read_catalog(
    request: Request, auth: CurrentAuth, db: SessionDep, goal: GoalQuery = None
) -> Response:
    """Subjects, chapters and topics of one exam (default: the player's) with question counts.

    The same for every player of that exam: send the ``ETag`` back in ``If-None-Match`` to get
    ``304`` while nothing changed.
    """
    goal = await resolve_goal(db, auth.user_id, goal)
    version = await content_version(db)
    headers = {"ETag": catalog_etag(version, goal), "Cache-Control": "private, no-cache"}
    if etag_matches(request.headers.get("if-none-match"), headers["ETag"]):
        return Response(status_code=304, headers=headers)
    catalog = await build_catalog(db, goal, version)
    return Response(catalog.model_dump_json(), media_type="application/json", headers=headers)


@router.get(
    "/search",
    dependencies=[Depends(rate_limit("search", capacity=30, refill_per_sec=0.5, scope="user"))],
)
async def search(
    auth: CurrentAuth,
    db: SessionDep,
    q: Annotated[str, Query(max_length=100)],
    subject: SubjectQuery = None,
    limit: Annotated[int, Query(ge=1, le=50)] = 20,
) -> SearchOut:
    """Questions of the player's exam matching ``q`` (2+ characters). 30 searches a minute."""
    goal = await resolve_goal(db, auth.user_id, None)
    views = await search_questions(
        db, goal=goal, query=q, subject_id=await subject_id_for(db, subject), limit=limit
    )
    return SearchOut(items=[view.summary() for view in views])


@router.get(
    "/questions/{ref}",
    dependencies=[
        Depends(rate_limit("questions.read", capacity=60, refill_per_sec=1.0, scope="user"))
    ],
)
async def read_question(ref: str, auth: CurrentAuth, db: SessionDep) -> QuestionOut:
    """One question with its answer and explanation, as in a practice session."""
    question_id = parse_ref(ref)
    view = await visible_view(db, auth.user_id, question_id) if question_id else None
    if question_id is None or view is None:
        raise NotFound("This question doesn't exist.", code="QUESTION_NOT_FOUND")
    bookmarked = question_id in await bookmarked_ids(db, auth.user_id, [question_id])
    return view.out(bookmarked=bookmarked)


class ReportIn(ApiModel):
    reason: Literal["wrong_answer", "typo", "unclear", "other"]
    note: Annotated[str, StringConstraints(strip_whitespace=True, max_length=500)] | None = None


@router.post("/questions/{ref}/reports", status_code=202)
async def report_question(
    ref: str, body: ReportIn, auth: CurrentAuth, db: SessionDep, clock: ClockDep
) -> Response:
    """Tell the team a question looks wrong. ``202``; reporting again while the first report is
    open changes nothing. At most 20 reports a day."""
    question_id = parse_ref(ref)
    if question_id is None:
        raise NotFound("This question doesn't exist.", code="QUESTION_NOT_FOUND")
    await reports.report_question(
        db, auth.user_id, question_id, reason=body.reason, note=body.note or None, now=clock()
    )
    return Response(status_code=202)


@router.get("/passages")
async def passages(auth: CurrentAuth, db: SessionDep, subject: SubjectQuery = None) -> PassagesOut:
    """Fun & Learn passages of the player's exam, with ``done`` once every question is answered."""
    goal = await resolve_goal(db, auth.user_id, None)
    items = await list_passages(
        db, user_id=auth.user_id, goal=goal, subject_id=await subject_id_for(db, subject)
    )
    return PassagesOut(items=items)
