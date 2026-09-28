"""User search and public profiles (docs/api-play.md, "Social" and "Profiles and stats").

A profile's ``ratings``, ``form`` and ``h2h`` come from the features that own them (ratings and
matches), which plug in with ``register_profile_section``; until they do, the sections are
empty. A minor seen by someone who isn't their friend shows only the card (name, avatar,
level), and players who blocked each other don't exist for one another (404).
"""

import re
import uuid
from collections.abc import Awaitable, Callable
from datetime import datetime
from typing import Any

from redis.asyncio import Redis
from sqlalchemy import Text, and_, cast, func, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.errors import NotFound, ValidationFailed
from app.modules.social.cards import cards_for
from app.modules.social.models import FriendRequest, RequestStatus
from app.modules.social.privacy import challenge_allowed, is_minor_user, privacy_of
from app.modules.social.relations import (
    Relationship,
    are_blocked,
    not_blocked_with,
    relationships,
)
from app.modules.social.schemas import (
    Direction,
    PendingRequestOut,
    ProfileOut,
    SearchOut,
    SearchResultOut,
)
from app.modules.users.models import HIDDEN_STATUSES, User, UserStatus
from app.modules.users.validation import normalize_handle

SEARCH_RESULTS = 20
_QUERY = re.compile(r"[a-z0-9_]{3,20}")
QUERY_MESSAGE = "Type at least 3 letters, numbers or _ of their username."

# (db, viewer_id, target_id) -> the section's value.
ProfileSection = Callable[[AsyncSession, uuid.UUID, uuid.UUID], Awaitable[Any]]

# Section name -> the value used when no provider is registered (or the profile is limited).
SECTION_DEFAULTS: dict[str, Callable[[], Any]] = {
    "ratings": list,  # [{"scope", "rating", "position"}]
    "form": list,  # the last 5 results, newest first: ["win", "loss", "draw", ...]
    "h2h": lambda: None,  # {"wins", "draws", "losses"} against the viewer
}

_SECTIONS: dict[str, ProfileSection] = {}

# (db, redis, target, ratings) -> the ratings with leaderboard positions filled in.
RatingPositions = Callable[[AsyncSession, Redis, uuid.UUID, list[Any]], Awaitable[list[Any]]]
_rating_positions: RatingPositions | None = None


def register_rating_positions(provider: RatingPositions) -> None:
    """Fill ``ratings[].position`` from the leaderboards."""
    global _rating_positions
    _rating_positions = provider


def register_profile_section(name: str, provider: ProfileSection) -> None:
    """Supply one of the profile's sections (``ratings``, ``form`` or ``h2h``)."""
    if name not in SECTION_DEFAULTS:
        raise ValueError(f"unknown profile section {name!r}")
    _SECTIONS[name] = provider


async def provided_section(
    db: AsyncSession, viewer_id: uuid.UUID, target_id: uuid.UUID, name: str
) -> Any | None:
    """One section from its provider, or None while no provider is registered."""
    provider = _SECTIONS.get(name)
    return None if provider is None else await provider(db, viewer_id, target_id)


async def _sections(
    db: AsyncSession, viewer_id: uuid.UUID, target_id: uuid.UUID, *, limited: bool
) -> dict[str, Any]:
    values = {}
    for name, default in SECTION_DEFAULTS.items():
        provider = _SECTIONS.get(name)
        values[name] = (
            default() if limited or provider is None else await provider(db, viewer_id, target_id)
        )
    return values


def search_query(raw: str) -> str:
    """The handle prefix to look for; 422 unless it has 3+ handle characters."""
    query = normalize_handle(raw.strip().removeprefix("@"))
    if not _QUERY.fullmatch(query):
        raise ValidationFailed(QUERY_MESSAGE, details={"fields": {"q": QUERY_MESSAGE}})
    return query


def _visible_player(now: datetime) -> Any:
    """Accounts others can find: onboarded, not closing, not suspended."""
    return and_(
        User.handle.is_not(None),
        User.status.not_in(HIDDEN_STATUSES),
        or_(
            User.status != UserStatus.BANNED.value,
            and_(User.banned_until.is_not(None), User.banned_until <= now),
        ),
    )


async def search_users(
    db: AsyncSession, viewer_id: uuid.UUID, raw_query: str, *, now: datetime
) -> SearchOut:
    """Players whose handle starts with the query: exact match first, then shortest."""
    query = search_query(raw_query)
    handle = cast(User.handle, Text)
    users = list(
        await db.scalars(
            select(User)
            .where(
                handle.startswith(query, autoescape=True),
                User.id != viewer_id,
                _visible_player(now),
                not_blocked_with(viewer_id, User.id),
            )
            .order_by((handle == query).desc(), func.length(handle), handle)
            .limit(SEARCH_RESULTS)
        )
    )
    card_of = await cards_for(db, users)
    relationship = await relationships(db, viewer_id, [user.id for user in users])
    return SearchOut(
        items=[
            SearchResultOut(**card_of[user.id].model_dump(), relationship=relationship[user.id])
            for user in users
        ]
    )


def profile_not_found() -> NotFound:
    return NotFound("That player was not found.", code="USER_NOT_FOUND")


async def public_profile(
    db: AsyncSession,
    viewer_id: uuid.UUID,
    raw_handle: str,
    *,
    now: datetime,
    redis: Redis | None = None,
) -> ProfileOut:
    handle = normalize_handle(raw_handle.removeprefix("@"))
    target = await db.scalar(select(User).where(User.handle == handle))
    if (
        target is None
        or target.status in HIDDEN_STATUSES
        or await are_blocked(db, viewer_id, target.id)
    ):
        raise profile_not_found()
    viewer = await db.get_one(User, viewer_id)
    is_self = target.id == viewer_id
    relationship = (await relationships(db, viewer_id, [target.id]))[target.id]
    limited = not is_self and relationship != Relationship.FRIEND and is_minor_user(target, now)
    can_challenge = (
        not is_self
        and viewer.status not in (UserStatus.RESTRICTED, *HIDDEN_STATUSES)
        and not target.ban_in_force(now)
        and await challenge_allowed(db, viewer_id, target, await privacy_of(db, target, now=now))
    )
    card = (await cards_for(db, [target]))[target.id]
    sections = await _sections(db, viewer_id, target.id, limited=limited or is_self)
    if redis is not None and _rating_positions is not None and sections.get("ratings"):
        sections["ratings"] = await _rating_positions(db, redis, target.id, sections["ratings"])
    return ProfileOut(
        **card.model_dump(),
        relationship=relationship,
        can_challenge=can_challenge,
        limited=limited,
        friend_request=await _pending_between(db, viewer_id, target.id),
        **sections,
    )


async def _pending_between(
    db: AsyncSession, viewer_id: uuid.UUID, target_id: uuid.UUID
) -> PendingRequestOut | None:
    request = await db.scalar(
        select(FriendRequest).where(
            FriendRequest.status == RequestStatus.PENDING.value,
            or_(
                and_(FriendRequest.from_id == viewer_id, FriendRequest.to_id == target_id),
                and_(FriendRequest.from_id == target_id, FriendRequest.to_id == viewer_id),
            ),
        )
    )
    if request is None:
        return None
    direction = Direction.OUTGOING if request.from_id == viewer_id else Direction.INCOMING
    return PendingRequestOut(id=request.id, direction=direction)
