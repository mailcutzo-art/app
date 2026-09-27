"""Request and response bodies for sign-in, token refresh and device sessions."""

import re
import uuid
from datetime import datetime
from typing import Annotated, Any

from pydantic import BeforeValidator, Field, StringConstraints

from app.core.schemas import ApiModel, field_error
from app.modules.users.schemas import MeOut, parse_display_name

_EMAIL = re.compile(r"[^@\s]+@[^@\s]+\.[^@\s]+")
_MAX_EMAIL_LENGTH = 254


class DeviceIn(ApiModel):
    """The app installation signing in (one device session per installation)."""

    install_id: Annotated[str, StringConstraints(pattern=r"^[A-Za-z0-9._:-]{1,64}$")]
    platform: Annotated[str, StringConstraints(min_length=1, max_length=20)]
    app_version: Annotated[str, StringConstraints(min_length=1, max_length=32)]
    build: Annotated[int, Field(ge=0, le=2_147_483_647)]


class GoogleSignInIn(ApiModel):
    id_token: Annotated[str, StringConstraints(min_length=1, max_length=8192)]
    device: DeviceIn


def _email(value: Any) -> str:
    if (
        not isinstance(value, str)
        or len(value) > _MAX_EMAIL_LENGTH
        or not _EMAIL.fullmatch(value.strip())
    ):
        raise field_error("Enter a valid email address.")
    return value.strip().lower()


def _optional_display_name(value: Any) -> str | None:
    """Blank means "not given": the dev-login form sends an empty name field."""
    if value is None or (isinstance(value, str) and not value.strip()):
        return None
    return parse_display_name(value)


class DevLoginIn(ApiModel):
    email: Annotated[str, BeforeValidator(_email)]
    display_name: Annotated[str | None, BeforeValidator(_optional_display_name)] = None
    device: DeviceIn


class RefreshIn(ApiModel):
    refresh_token: Annotated[str, StringConstraints(min_length=1, max_length=256)]


class TokensOut(ApiModel):
    access_token: str
    access_expires_in: int
    refresh_token: str


class SignInOut(TokensOut):
    user: MeOut
    is_new_user: bool


class SessionOut(ApiModel):
    id: uuid.UUID
    platform: str
    app_version: str
    created_at: datetime
    last_seen_at: datetime
    current: bool
