"""The signed-in player's profile: ``/v1/me``, onboarding and handle availability."""

from typing import Annotated

from fastapi import APIRouter, Depends, Query

from app.core.clock import ClockDep
from app.core.db import SessionDep
from app.core.ratelimit import rate_limit
from app.core.security import CurrentAuth
from app.modules.users import service
from app.modules.users.schemas import HandleCheckOut, MeOut, OnboardingIn, ProfilePatchIn

router = APIRouter(tags=["users"])


@router.get("/me")
async def read_me(auth: CurrentAuth, db: SessionDep) -> MeOut:
    return MeOut.from_user(await service.get_user(db, auth.user_id))


@router.patch("/me")
async def update_me(body: ProfilePatchIn, auth: CurrentAuth, db: SessionDep) -> MeOut:
    return MeOut.from_user(await service.update_profile(db, auth.user_id, body))


@router.post("/me/onboarding")
async def complete_onboarding(
    body: OnboardingIn, auth: CurrentAuth, db: SessionDep, clock: ClockDep
) -> MeOut:
    """Name, handle, avatar, goal and birth year, once. 409 ``ALREADY_ONBOARDED`` afterwards;
    409 ``HANDLE_TAKEN`` if the handle belongs to someone else."""
    user = await service.complete_onboarding(db, auth.user_id, body, now=clock())
    return MeOut.from_user(user)


@router.get(
    "/handles/check",
    response_model_exclude_none=True,
    dependencies=[
        Depends(rate_limit("handles.check", capacity=30, refill_per_sec=0.5, scope="user"))
    ],
)
async def check_handle(
    handle: Annotated[str, Query(max_length=64)], auth: CurrentAuth, db: SessionDep
) -> HandleCheckOut:
    """``{"available": true}``, or ``false`` with a reason: invalid, reserved or taken."""
    problem = await service.handle_availability(db, handle, user_id=auth.user_id)
    return HandleCheckOut(available=problem is None, reason=problem)
