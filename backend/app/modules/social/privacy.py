"""Privacy settings: who may send friend requests, who may challenge, who sees presence, and
whether the player appears on public boards (docs/api-play.md, "Social").

The stored columns are ``NULL`` until the player picks something, and the defaults depend on
whether they are a minor *today* (from the birth year, each time it is read), so a minor's
safer defaults lift on their own at 18 (docs/plan.md, "Privacy for minors").

"Played with" is decided by the realtime engine, which owns matches: it registers a predicate
with ``register_have_played``. Until then nobody has played anybody.
"""

import uuid
from collections.abc import Awaitable, Callable, Collection
from dataclasses import dataclass
from datetime import datetime
from enum import StrEnum

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.clock import utc_now
from app.core.errors import ValidationFailed
from app.modules.social.relations import are_blocked, are_friends
from app.modules.users.models import HIDDEN_STATUSES, User, UserStatus
from app.modules.users.settings import Preferences, locked_settings, read_many, read_settings
from app.modules.users.validation import minor_now


class FriendRequestsFrom(StrEnum):
    EVERYONE = "everyone"
    PLAYED_WITH = "played_with"
    NOBODY = "nobody"


class ChallengesFrom(StrEnum):
    FRIENDS = "friends"
    EVERYONE = "everyone"
    NOBODY = "nobody"


class PresenceTo(StrEnum):
    FRIENDS = "friends"
    NOBODY = "nobody"


@dataclass(frozen=True, slots=True)
class Privacy:
    friend_requests: FriendRequestsFrom
    challenges: ChallengesFrom
    presence: PresenceTo
    public_boards: bool


ADULT_DEFAULTS = Privacy(
    FriendRequestsFrom.EVERYONE, ChallengesFrom.EVERYONE, PresenceTo.FRIENDS, True
)
MINOR_DEFAULTS = Privacy(
    FriendRequestsFrom.PLAYED_WITH, ChallengesFrom.FRIENDS, PresenceTo.FRIENDS, True
)


def resolve(preferences: Preferences, *, minor: bool) -> Privacy:
    """The stored choices, with the right defaults filled in."""
    defaults = MINOR_DEFAULTS if minor else ADULT_DEFAULTS
    friend_requests = (
        FriendRequestsFrom(preferences.friend_requests)
        if preferences.friend_requests is not None
        else defaults.friend_requests
    )
    if minor and friend_requests == FriendRequestsFrom.EVERYONE:
        friend_requests = FriendRequestsFrom.PLAYED_WITH  # never wider than the minors' rule
    return Privacy(
        friend_requests=friend_requests,
        challenges=ChallengesFrom(preferences.challenges)
        if preferences.challenges is not None
        else defaults.challenges,
        presence=PresenceTo(preferences.presence)
        if preferences.presence is not None
        else defaults.presence,
        public_boards=preferences.public_boards
        if preferences.public_boards is not None
        else defaults.public_boards,
    )


def is_minor_user(user: User, now: datetime) -> bool:
    return minor_now(user.birth_year, stored=user.is_minor, now=now)


async def privacy_of(db: AsyncSession, user: User, *, now: datetime) -> Privacy:
    return resolve(await read_settings(db, user.id), minor=is_minor_user(user, now))


async def privacy_many(
    db: AsyncSession, users: Collection[User], *, now: datetime
) -> dict[uuid.UUID, Privacy]:
    preferences = await read_many(db, [user.id for user in users])
    return {
        user.id: resolve(preferences[user.id], minor=is_minor_user(user, now)) for user in users
    }


MINOR_REQUESTS_MESSAGE = "Players under 18 can only get requests from people they've played."


async def save_privacy(db: AsyncSession, user: User, privacy: Privacy, *, now: datetime) -> None:
    """Store every choice explicitly (a full replace, as ``PUT`` sends them all). Minors can
    narrow their requests to ``played_with`` or ``nobody``, never widen them to everyone."""
    if privacy.friend_requests == FriendRequestsFrom.EVERYONE and is_minor_user(user, now):
        raise ValidationFailed(
            MINOR_REQUESTS_MESSAGE, details={"fields": {"friend_requests": MINOR_REQUESTS_MESSAGE}}
        )
    row = await locked_settings(db, user.id)
    row.friend_requests = privacy.friend_requests.value
    row.challenges = privacy.challenges.value
    row.presence = privacy.presence.value
    row.public_boards = privacy.public_boards
    await db.flush()


async def public_boards_allowed(db: AsyncSession, user_id: uuid.UUID, *, now: datetime) -> bool:
    """Whether the player appears on public leaderboards (minors can opt out)."""
    user = await db.get(User, user_id)
    return user is not None and (await privacy_of(db, user, now=now)).public_boards


# --- "Played with" ---------------------------------------------------------------------------

HavePlayed = Callable[[AsyncSession, uuid.UUID, uuid.UUID], Awaitable[bool]]


async def _never_played(_db: AsyncSession, _a: uuid.UUID, _b: uuid.UUID) -> bool:
    return False


_have_played: HavePlayed = _never_played


def register_have_played(check: HavePlayed) -> None:
    """Tell social features how to decide whether two players have played each other."""
    global _have_played
    _have_played = check


async def have_played(db: AsyncSession, a: uuid.UUID, b: uuid.UUID) -> bool:
    return await _have_played(db, a, b)


# --- Challenges ------------------------------------------------------------------------------


def can_be_reached(user: User | None, now: datetime) -> bool:
    """Visible and not suspended: someone others can befriend or challenge."""
    return (
        user is not None
        and user.status not in HIDDEN_STATUSES
        and not user.ban_in_force(now)
        and user.handle is not None
    )


async def can_challenge(
    db: AsyncSession,
    viewer_id: uuid.UUID,
    target_id: uuid.UUID,
    *,
    now: datetime | None = None,
) -> bool:
    """Whether ``viewer_id`` may send ``target_id`` a friend-duel invite: the target's
    ``challenges`` setting allows it, neither blocked the other, and the viewer's social
    features aren't restricted by moderation."""
    if viewer_id == target_id:
        return False
    now = now or utc_now()
    viewer = await db.get(User, viewer_id)
    target = await db.get(User, target_id)
    if not can_be_reached(target, now) or viewer is None or target is None:
        return False
    if viewer.status == UserStatus.RESTRICTED or viewer.status in HIDDEN_STATUSES:
        return False
    return await challenge_allowed(db, viewer_id, target, await privacy_of(db, target, now=now))


async def challenge_allowed(
    db: AsyncSession, viewer_id: uuid.UUID, target: User, privacy: Privacy
) -> bool:
    """The target's setting and blocks (the players' own states are checked by the caller)."""
    if privacy.challenges == ChallengesFrom.NOBODY or await are_blocked(db, viewer_id, target.id):
        return False
    if privacy.challenges == ChallengesFrom.FRIENDS:
        return await are_friends(db, viewer_id, target.id)
    return True


async def users_by_id(db: AsyncSession, user_ids: Collection[uuid.UUID]) -> dict[uuid.UUID, User]:
    rows = await db.scalars(select(User).where(User.id.in_(list(user_ids))))
    return {user.id: user for user in rows}
