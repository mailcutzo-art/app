"""The signed-in player's profile: ``/v1/me``, onboarding, handle availability, and deleting
or restoring the account."""

from typing import Annotated

from fastapi import APIRouter, Depends, Query

from app.core.clock import ClockDep
from app.core.config import SettingsDep
from app.core.db import SessionDep
from app.core.ratelimit import rate_limit
from app.core.redis import RedisDep
from app.core.security import CurrentAuth, CurrentAuthClosing
from app.modules.auth.google import GoogleVerifierDep
from app.modules.users import deletion, service
from app.modules.users.schemas import (
    DeleteAccountIn,
    DeletionOut,
    HandleCheckOut,
    MeOut,
    OnboardingIn,
    ProfilePatchIn,
)

router = APIRouter(tags=["users"])


@router.get("/me")
async def read_me(auth: CurrentAuthClosing, db: SessionDep, clock: ClockDep) -> MeOut:
    """Also answers a deleted account's restricted session (``status: pending_deletion``)."""
    return MeOut.from_user(await service.get_user(db, auth.user_id), now=clock())


@router.patch("/me")
async def update_me(
    body: ProfilePatchIn, auth: CurrentAuth, db: SessionDep, clock: ClockDep
) -> MeOut:
    """409 ``HANDLE_CHANGE_TOO_SOON`` (with ``details.next_change_at``) or ``HANDLE_TAKEN``."""
    now = clock()
    return MeOut.from_user(await service.update_profile(db, auth.user_id, body, now=now), now=now)


@router.post("/me/onboarding")
async def complete_onboarding(
    body: OnboardingIn, auth: CurrentAuth, db: SessionDep, clock: ClockDep
) -> MeOut:
    """Name, handle, avatar, goal and birth year, once. 409 ``ALREADY_ONBOARDED`` afterwards;
    409 ``HANDLE_TAKEN`` if the handle belongs to someone else."""
    now = clock()
    user = await service.complete_onboarding(db, auth.user_id, body, now=now)
    return MeOut.from_user(user, now=now)


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


# Per IP: a deleted account's restricted session can't use per-user buckets.
_account_limit = rate_limit("account.lifecycle", capacity=10, refill_per_sec=10 / 3600)


@router.post("/me/delete", status_code=202, dependencies=[Depends(_account_limit)])
async def delete_account(
    body: DeleteAccountIn,
    auth: CurrentAuth,
    db: SessionDep,
    redis: RedisDep,
    settings: SettingsDep,
    verifier: GoogleVerifierDep,
    clock: ClockDep,
) -> DeletionOut:
    """Needs ``{"confirm": "DELETE", "proof": {...}}``, a fresh sign-in for this account.
    Every session ends, this one included; the account can be restored for 7 days.
    403 ``REAUTH_REQUIRED`` when the proof is missing, stale, replayed or for another account."""
    now = clock()
    await deletion.check_proof(
        db,
        redis,
        settings,
        verifier,
        auth.user_id,
        provider=deletion.ProofProvider(body.proof.provider),
        id_token=body.proof.id_token,
        now=now,
    )
    user = await deletion.request_deletion(db, redis, auth.user_id, now=now)
    return DeletionOut(status=user.status, restore_until=user.restore_until)


@router.post("/me/restore", dependencies=[Depends(_account_limit)])
async def restore_account(
    auth: CurrentAuthClosing, db: SessionDep, redis: RedisDep, clock: ClockDep
) -> MeOut:
    """Within 7 days of a delete: everything comes back as it was. 409 ``RESTORE_EXPIRED``."""
    now = clock()
    user = await deletion.restore_account(db, redis, auth.user_id, now=now)
    return MeOut.from_user(user, now=now)
