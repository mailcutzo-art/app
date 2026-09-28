"""Request and response bodies for rooms and invites (``docs/api-play.md``, "Rooms and
invites")."""

import uuid
from datetime import datetime
from typing import Literal

from pydantic import Field

from app.core.schemas import ApiModel, Lax
from app.modules.social.cards import UserCard

Difficulty = Literal["mixed", "easy", "medium", "hard"]
JoinRule = Literal["friends", "anyone"]


class RoomSettingsIn(ApiModel):
    """What the host picks; anything left out takes the kind's default. A friend duel takes
    ``chapter`` (or ``chapters`` with at most one), a group ``chapters``; null or empty means
    all chapters."""

    subject: str = Field(min_length=1, max_length=64)
    chapter: str | None = Field(default=None, max_length=64)
    chapters: list[str] | None = Field(default=None, max_length=12)
    questions: int | None = None
    seconds: int | None = None
    difficulty: Difficulty | None = None
    late_join: bool | None = None
    leaderboard: bool | None = None
    join: JoinRule | None = None


class RoomIn(ApiModel):
    kind: Literal["friend", "group"]
    settings: RoomSettingsIn


class RoomCreatedOut(ApiModel):
    room_id: uuid.UUID
    code: str
    link: str
    expires_at: datetime


class RoomPreviewOut(ApiModel):
    room_id: uuid.UUID
    kind: str
    code: str
    host: UserCard | None
    subject: str
    chapters: list[str] | None
    questions: int
    seconds: int
    members: int
    capacity: int
    joinable: bool
    reason: Literal["locked", "full", "started", "blocked", "friends_only", "kicked"] | None


class InviteIn(ApiModel):
    to_user_id: Lax[uuid.UUID]
    room_id: Lax[uuid.UUID]


class InviteCreatedOut(ApiModel):
    invite_id: uuid.UUID
    expires_at: datetime


class InviteOut(ApiModel):
    invite_id: uuid.UUID
    from_: UserCard | None = Field(default=None, serialization_alias="from")
    to: UserCard | None = None
    room_id: uuid.UUID
    kind: str
    subject: str
    expires_at: datetime


class InvitesOut(ApiModel):
    incoming: list[InviteOut]
    outgoing: list[InviteOut]


class InviteAcceptedOut(ApiModel):
    room_id: uuid.UUID
    code: str
