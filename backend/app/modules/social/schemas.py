"""Request and response bodies for friends, blocks, search, profiles and privacy."""

import uuid
from datetime import datetime
from enum import StrEnum
from typing import Any

from app.core.schemas import ApiModel, Lax
from app.modules.social.cards import UserCard
from app.modules.social.presence import Presence
from app.modules.social.privacy import ChallengesFrom, FriendRequestsFrom, PresenceTo
from app.modules.social.relations import Relationship


class UserIdIn(ApiModel):
    user_id: Lax[uuid.UUID]


class FriendOut(UserCard):
    presence: Presence
    friends_since: datetime
    can_challenge: bool


class FriendsOut(ApiModel):
    items: list[FriendOut]
    next_cursor: str | None


class Direction(StrEnum):
    INCOMING = "incoming"
    OUTGOING = "outgoing"


class FriendRequestOut(ApiModel):
    id: uuid.UUID
    # The other player: the sender of an incoming request, the recipient of an outgoing one.
    user: UserCard
    direction: Direction
    status: str
    created_at: datetime


class FriendRequestsOut(ApiModel):
    incoming: list[FriendRequestOut]
    outgoing: list[FriendRequestOut]


class BlockOut(ApiModel):
    user: UserCard
    created_at: datetime


class BlocksOut(ApiModel):
    items: list[BlockOut]
    next_cursor: str | None


class SearchResultOut(UserCard):
    relationship: Relationship


class SearchOut(ApiModel):
    items: list[SearchResultOut]


class ActivityOut(ApiModel):
    id: uuid.UUID
    user: UserCard
    kind: str
    payload: dict[str, Any]
    created_at: datetime


class ActivityFeedOut(ApiModel):
    items: list[ActivityOut]
    next_cursor: str | None


class PendingRequestOut(ApiModel):
    id: uuid.UUID
    direction: Direction


class ProfileOut(UserCard):
    """A public profile. ``limited`` profiles (a minor seen by a non-friend) carry only the
    card: ``ratings`` and ``form`` are empty and ``h2h`` is null."""

    relationship: Relationship
    can_challenge: bool
    limited: bool
    # The pending friend request between the viewer and this player, so the app can offer
    # Accept (incoming) or Cancel (outgoing).
    friend_request: PendingRequestOut | None
    ratings: list[Any]
    form: list[Any]
    h2h: Any


class PrivacyIn(ApiModel):
    friend_requests: Lax[FriendRequestsFrom]
    challenges: Lax[ChallengesFrom]
    presence: Lax[PresenceTo]
    public_boards: bool


class PrivacyOut(ApiModel):
    friend_requests: FriendRequestsFrom
    challenges: ChallengesFrom
    presence: PresenceTo
    public_boards: bool
    # Whether the minors' defaults apply (the app explains them).
    is_minor: bool
