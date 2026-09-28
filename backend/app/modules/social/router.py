"""Friends, requests, blocks, activity, search, public profiles and privacy settings
(docs/api-play.md, "Social" and "Profiles and stats").

Every query is scoped to the caller: a request id or user id that isn't theirs answers 404.
"""

import uuid
from typing import Annotated

from fastapi import APIRouter, Depends, Path, Query

from app.core.clock import ClockDep
from app.core.db import SessionDep
from app.core.ratelimit import rate_limit
from app.core.redis import RedisDep
from app.core.security import CurrentAuth
from app.modules.social import activity, blocks, friends, profiles
from app.modules.social.privacy import Privacy, is_minor_user, privacy_of, save_privacy
from app.modules.social.schemas import (
    ActivityFeedOut,
    BlocksOut,
    FriendRequestOut,
    FriendRequestsOut,
    FriendsOut,
    PrivacyIn,
    PrivacyOut,
    ProfileOut,
    SearchOut,
    UserIdIn,
)
from app.modules.users.models import User

router = APIRouter(tags=["social"])

CursorQuery = Annotated[str | None, Query(max_length=512)]
LimitQuery = Annotated[int, Query(ge=1, le=100)]

# Bursts only; the daily cap of 20 requests is a product rule (LIMIT_REACHED).
_request_limit = rate_limit("friends.request", capacity=10, refill_per_sec=10 / 60, scope="user")
_search_limit = rate_limit("users.search", capacity=30, refill_per_sec=0.5, scope="user")
_profile_limit = rate_limit("users.profile", capacity=60, refill_per_sec=1, scope="user")
_block_limit = rate_limit("blocks.write", capacity=20, refill_per_sec=20 / 60, scope="user")
_settings_limit = rate_limit("settings.write", capacity=30, refill_per_sec=30 / 60, scope="user")


# --- Friends and requests ----------------------------------------------------------------------


@router.get("/me/friends")
async def list_friends(
    auth: CurrentAuth,
    db: SessionDep,
    redis: RedisDep,
    clock: ClockDep,
    cursor: CursorQuery = None,
    limit: LimitQuery = 50,
) -> FriendsOut:
    """Friends by name, each with ``presence`` (``offline`` unless they share it)."""
    return await friends.list_friends(
        db, redis, auth.user_id, cursor=cursor, limit=limit, now=clock()
    )


@router.delete("/me/friends/{user_id}", status_code=204)
async def remove_friend(user_id: uuid.UUID, auth: CurrentAuth, db: SessionDep) -> None:
    await friends.remove_friend(db, auth.user_id, user_id)


@router.post("/friend-requests", status_code=201, dependencies=[Depends(_request_limit)])
async def send_friend_request(
    body: UserIdIn, auth: CurrentAuth, db: SessionDep, clock: ClockDep
) -> FriendRequestOut:
    """Ask a player to be friends; asking again returns the same pending request, and asking
    someone who asked you makes you friends (``status: accepted``). 403 ``NOT_ALLOWED`` (their
    privacy setting, or your account is restricted), 409 ``LIMIT_REACHED`` or
    ``ALREADY_FRIENDS``, 404 ``USER_NOT_FOUND``."""
    request = await friends.send_request(db, auth.user_id, body.user_id, now=clock())
    return await friends.request_out(db, auth.user_id, request)


@router.get("/me/friend-requests")
async def list_friend_requests(auth: CurrentAuth, db: SessionDep) -> FriendRequestsOut:
    return await friends.list_requests(db, auth.user_id)


@router.post("/friend-requests/{request_id}/accept")
async def accept_friend_request(
    request_id: uuid.UUID, auth: CurrentAuth, db: SessionDep, clock: ClockDep
) -> FriendRequestOut:
    request = await friends.accept_request(db, auth.user_id, request_id, now=clock())
    return await friends.request_out(db, auth.user_id, request)


@router.post("/friend-requests/{request_id}/decline")
async def decline_friend_request(
    request_id: uuid.UUID, auth: CurrentAuth, db: SessionDep, clock: ClockDep
) -> FriendRequestOut:
    request = await friends.decline_request(db, auth.user_id, request_id, now=clock())
    return await friends.request_out(db, auth.user_id, request)


@router.delete("/friend-requests/{request_id}", status_code=204)
async def cancel_friend_request(
    request_id: uuid.UUID, auth: CurrentAuth, db: SessionDep, clock: ClockDep
) -> None:
    """Withdraw a request you sent."""
    await friends.cancel_request(db, auth.user_id, request_id, now=clock())


@router.get("/me/activity")
async def friends_activity(
    auth: CurrentAuth,
    db: SessionDep,
    clock: ClockDep,
    cursor: CursorQuery = None,
    limit: LimitQuery = 30,
) -> ActivityFeedOut:
    """Friends' achievements, podiums, level-ups, streaks and new friends from 7 days."""
    return await activity.friends_activity(
        db, auth.user_id, cursor=cursor, limit=limit, now=clock()
    )


# --- Blocks ------------------------------------------------------------------------------------


@router.post("/blocks", status_code=204, dependencies=[Depends(_block_limit)])
async def block_user(body: UserIdIn, auth: CurrentAuth, db: SessionDep, clock: ClockDep) -> None:
    """Ends the friendship and pending requests; the two can't find or pair with each other."""
    await blocks.block_user(db, auth.user_id, body.user_id, now=clock())


@router.delete("/blocks/{user_id}", status_code=204, dependencies=[Depends(_block_limit)])
async def unblock_user(user_id: uuid.UUID, auth: CurrentAuth, db: SessionDep) -> None:
    await blocks.unblock_user(db, auth.user_id, user_id)


@router.get("/me/blocks")
async def list_blocks(
    auth: CurrentAuth, db: SessionDep, cursor: CursorQuery = None, limit: LimitQuery = 50
) -> BlocksOut:
    return await blocks.list_blocks(db, auth.user_id, cursor=cursor, limit=limit)


# --- Search and profiles -------------------------------------------------------------------------


@router.get("/users/search", dependencies=[Depends(_search_limit)])
async def search_users(
    q: Annotated[str, Query(max_length=64)], auth: CurrentAuth, db: SessionDep, clock: ClockDep
) -> SearchOut:
    """Handles starting with ``q`` (3+ characters), with your relationship to each."""
    return await profiles.search_users(db, auth.user_id, q, now=clock())


@router.get("/users/{handle}", dependencies=[Depends(_profile_limit)])
async def public_profile(
    handle: Annotated[str, Path(max_length=64)], auth: CurrentAuth, db: SessionDep, clock: ClockDep
) -> ProfileOut:
    """404 ``USER_NOT_FOUND`` if there is no such player or either of you blocked the other."""
    return await profiles.public_profile(db, auth.user_id, handle, now=clock())


# --- Privacy ------------------------------------------------------------------------------------


@router.get("/me/settings/privacy")
async def read_privacy(auth: CurrentAuth, db: SessionDep, clock: ClockDep) -> PrivacyOut:
    """The player's choices, with the defaults for their age filled in."""
    now = clock()
    user = await db.get_one(User, auth.user_id)
    privacy = await privacy_of(db, user, now=now)
    return _privacy_out(privacy, minor=is_minor_user(user, now))


@router.put("/me/settings/privacy", dependencies=[Depends(_settings_limit)])
async def save_privacy_settings(
    body: PrivacyIn, auth: CurrentAuth, db: SessionDep, clock: ClockDep
) -> PrivacyOut:
    """All four fields. Under-18s can't take requests from ``everyone`` (422)."""
    now = clock()
    user = await db.get_one(User, auth.user_id)
    privacy = Privacy(body.friend_requests, body.challenges, body.presence, body.public_boards)
    await save_privacy(db, user, privacy, now=now)
    return _privacy_out(privacy, minor=is_minor_user(user, now))


def _privacy_out(privacy: Privacy, *, minor: bool) -> PrivacyOut:
    return PrivacyOut(
        friend_requests=privacy.friend_requests,
        challenges=privacy.challenges,
        presence=privacy.presence,
        public_boards=privacy.public_boards,
        is_minor=minor,
    )
