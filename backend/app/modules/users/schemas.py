"""Request and response bodies for the player's own profile."""

import uuid
from datetime import datetime
from typing import Annotated, Any

from pydantic import BeforeValidator

from app.core.clock import utc_now
from app.core.schemas import ApiModel, field_error
from app.modules.users import validation as rules
from app.modules.users.models import Goal, User


def parse_display_name(value: Any) -> str:
    """Validator for display names: cleaned, then checked against the profile rules."""
    if not isinstance(value, str):
        raise field_error("Enter your name.")
    name = rules.clean_display_name(value)
    problem = rules.display_name_problem(name)
    if problem is not None:
        raise field_error(problem)
    return name


def _handle(value: Any) -> str:
    if not isinstance(value, str):
        raise field_error(rules.HANDLE_MESSAGES[rules.HandleProblem.INVALID])
    handle = rules.normalize_handle(value)
    problem = rules.handle_problem(handle)
    if problem is not None:
        raise field_error(rules.HANDLE_MESSAGES[problem])
    return handle


def _goal(value: Any) -> str:
    if value not in {goal.value for goal in Goal}:
        raise field_error(rules.GOAL_MESSAGE)
    return str(value)


def _birth_year(value: Any) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise field_error("Enter the year you were born.")
    problem = rules.birth_year_problem(value, this_year=rules.current_year(utc_now()))
    if problem is not None:
        raise field_error(problem)
    return value


def _tone(value: Any) -> str:
    if value not in rules.AVATAR_TONES:
        raise field_error(rules.TONE_MESSAGE)
    return str(value)


def _symbol(value: Any) -> str:
    if value not in rules.AVATAR_SYMBOLS:
        raise field_error(rules.SYMBOL_MESSAGE)
    return str(value)


DisplayName = Annotated[str, BeforeValidator(parse_display_name)]
Handle = Annotated[str, BeforeValidator(_handle)]
GoalName = Annotated[str, BeforeValidator(_goal)]
BirthYear = Annotated[int, BeforeValidator(_birth_year)]


class AvatarIn(ApiModel):
    tone: Annotated[str, BeforeValidator(_tone)]
    symbol: Annotated[str, BeforeValidator(_symbol)]


class OnboardingIn(ApiModel):
    display_name: DisplayName
    handle: Handle
    avatar: AvatarIn
    goal: GoalName
    birth_year: BirthYear


class ProfilePatchIn(ApiModel):
    """Any subset of the editable fields. Handle changes come in a later phase."""

    display_name: DisplayName | None = None
    avatar: AvatarIn | None = None
    goal: GoalName | None = None


class AvatarOut(ApiModel):
    tone: str
    symbol: str


class MeOut(ApiModel):
    """The signed-in player's own profile. Private: ``email`` must never appear in public
    profiles or cards."""

    id: uuid.UUID
    handle: str | None
    display_name: str
    # The account's email, so onboarding can say which Google account is signed in.
    email: str | None
    avatar: AvatarOut
    goal: str | None
    birth_year: int | None
    is_minor: bool
    onboarding_completed: bool
    roles: list[str]
    created_at: datetime

    @classmethod
    def from_user(cls, user: User, *, now: datetime) -> "MeOut":
        return cls(
            id=user.id,
            handle=user.handle,
            display_name=user.display_name,
            email=user.email,
            avatar=AvatarOut(tone=user.avatar_tone, symbol=user.avatar_symbol),
            goal=user.goal,
            birth_year=user.birth_year,
            is_minor=rules.minor_now(user.birth_year, stored=user.is_minor, now=now),
            onboarding_completed=user.onboarding_completed_at is not None,
            roles=sorted(user.roles),
            created_at=user.created_at,
        )


class HandleCheckOut(ApiModel):
    available: bool
    reason: rules.HandleProblem | None = None
