"""The signed-in player's profile: onboarding, edits, handle availability and roles."""

import uuid
from datetime import datetime

from redis.asyncio import Redis
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.db import violated_constraint
from app.core.errors import Conflict, Unauthorized
from app.modules.system.models import AuditLog
from app.modules.users.authz import invalidate_authz
from app.modules.users.models import Role, User
from app.modules.users.schemas import OnboardingIn, ProfilePatchIn
from app.modules.users.validation import (
    HANDLE_MESSAGES,
    HandleProblem,
    current_year,
    handle_problem,
    is_minor,
    normalize_handle,
)

_HANDLE_CONSTRAINT = "uq_users_handle"


async def get_user(db: AsyncSession, user_id: uuid.UUID) -> User:
    user = await db.get(User, user_id)
    if user is None:
        raise Unauthorized("Your session is not valid.", code="INVALID_ACCESS_TOKEN")
    return user


async def complete_onboarding(
    db: AsyncSession, user_id: uuid.UUID, data: OnboardingIn, *, now: datetime
) -> User:
    user = await db.get_one(User, user_id, with_for_update=True)
    if user.onboarding_completed_at is not None:
        raise Conflict("Your profile is already set up.", code="ALREADY_ONBOARDED")
    if await _handle_owner(db, data.handle) not in (None, user_id):
        raise _handle_taken()
    user.display_name = data.display_name
    user.handle = data.handle
    user.avatar_tone = data.avatar.tone
    user.avatar_symbol = data.avatar.symbol
    user.goal = data.goal
    user.birth_year = data.birth_year
    user.is_minor = is_minor(data.birth_year, this_year=current_year(now))
    user.onboarding_completed_at = now
    try:
        await db.flush()
    except IntegrityError as exc:
        # Someone claimed the handle between the check above and this write.
        if violated_constraint(exc) == _HANDLE_CONSTRAINT:
            raise _handle_taken() from exc
        raise
    return user


async def update_profile(db: AsyncSession, user_id: uuid.UUID, data: ProfilePatchIn) -> User:
    user = await get_user(db, user_id)
    if data.display_name is not None:
        user.display_name = data.display_name
    if data.avatar is not None:
        user.avatar_tone = data.avatar.tone
        user.avatar_symbol = data.avatar.symbol
    if data.goal is not None:
        user.goal = data.goal
    await db.flush()
    return user


async def handle_availability(
    db: AsyncSession, raw_handle: str, *, user_id: uuid.UUID
) -> HandleProblem | None:
    """Why ``raw_handle`` can't be taken by the user, or ``None`` if it can (their own counts)."""
    handle = normalize_handle(raw_handle)
    problem = handle_problem(handle)
    if problem is not None:
        return problem
    if await _handle_owner(db, handle) not in (None, user_id):
        return HandleProblem.TAKEN
    return None


async def find_user(db: AsyncSession, identifier: str) -> User | None:
    """Look a user up by handle ("neet_ace" or "@neet_ace") or by email."""
    identifier = identifier.strip()
    if "@" in identifier[1:]:
        users = list(await db.scalars(select(User).where(User.email == identifier).limit(2)))
        if len(users) > 1:
            raise LookupError("several accounts use that email; use the handle instead")
        return users[0] if users else None
    handle = normalize_handle(identifier.removeprefix("@"))
    return await db.scalar(select(User).where(User.handle == handle))


async def grant_role(db: AsyncSession, redis: Redis, user: User, role: Role) -> bool:
    """Give ``user`` the role (audit-logged); ``False`` if they already had it."""
    if role in user.roles:
        return False
    before = sorted(user.roles)
    user.roles = sorted({*user.roles, role.value})
    db.add(
        AuditLog(
            action="user.role_granted",
            entity_type="user",
            entity_id=str(user.id),
            before={"roles": before},
            after={"roles": user.roles},
        )
    )
    await db.commit()
    await invalidate_authz(redis, user.id)
    return True


async def _handle_owner(db: AsyncSession, handle: str) -> uuid.UUID | None:
    return await db.scalar(select(User.id).where(User.handle == handle))


def _handle_taken() -> Conflict:
    message = HANDLE_MESSAGES[HandleProblem.TAKEN]
    return Conflict(message, code="HANDLE_TAKEN", details={"fields": {"handle": message}})
