"""Firebase Cloud Messaging (HTTP v1) over the shared ``httpx`` client.

Enabled only when ``APP_FCM_SERVICE_ACCOUNT_FILE`` points at a Google service-account JSON key
(the project id comes from the file unless ``APP_FCM_PROJECT_ID`` is set). The sender signs a
short JWT with the account's key, exchanges it for an OAuth access token (cached until shortly
before it expires) and posts one message per device token.
"""

import functools
import json
from dataclasses import dataclass
from datetime import datetime, timedelta
from enum import StrEnum
from pathlib import Path
from typing import Any

import httpx
import jwt

from app.core.config import Settings

FCM_SCOPE = "https://www.googleapis.com/auth/firebase.messaging"
DEFAULT_TOKEN_URI = "https://oauth2.googleapis.com/token"  # noqa: S105 - a URL
SEND_URL = "https://fcm.googleapis.com/v1/projects/{project}/messages:send"
ASSERTION_LIFETIME = timedelta(minutes=60)
# Renew the access token this long before Google says it expires.
TOKEN_MARGIN = timedelta(minutes=5)


class PushError(Exception):
    """A failure worth retrying later (network, 429, 5xx, rejected credentials)."""


class SendOutcome(StrEnum):
    SENT = "sent"
    INVALID_TOKEN = "invalid_token"  # noqa: S105 - the app was uninstalled, or the token rotated


@dataclass(frozen=True, slots=True)
class ServiceAccount:
    project_id: str
    client_email: str
    private_key: str
    token_uri: str


@functools.cache
def _load_account(path: str, project_override: str | None) -> ServiceAccount:
    data = json.loads(Path(path).read_text(encoding="utf-8"))
    project_id = project_override or data.get("project_id")
    if not project_id or not data.get("client_email") or not data.get("private_key"):
        raise ValueError("the FCM service account file needs project_id, client_email, private_key")
    return ServiceAccount(
        project_id=project_id,
        client_email=data["client_email"],
        private_key=data["private_key"],
        token_uri=data.get("token_uri") or DEFAULT_TOKEN_URI,
    )


def service_account(settings: Settings) -> ServiceAccount | None:
    """The configured account, or ``None`` when push is off."""
    if not settings.fcm_service_account_file:
        return None
    return _load_account(settings.fcm_service_account_file, settings.fcm_project_id)


# client_email -> (access token, renew after)
_tokens: dict[str, tuple[str, datetime]] = {}


def forget_access_tokens() -> None:
    _tokens.clear()


async def access_token(http: httpx.AsyncClient, account: ServiceAccount, *, now: datetime) -> str:
    cached = _tokens.get(account.client_email)
    if cached is not None and cached[1] > now:
        return cached[0]
    assertion = jwt.encode(
        {
            "iss": account.client_email,
            "scope": FCM_SCOPE,
            "aud": account.token_uri,
            "iat": int(now.timestamp()),
            "exp": int((now + ASSERTION_LIFETIME).timestamp()),
        },
        account.private_key,
        algorithm="RS256",
    )
    try:
        response = await http.post(
            account.token_uri,
            data={
                "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
                "assertion": assertion,
            },
        )
    except httpx.HTTPError as exc:
        raise PushError(f"token request failed: {type(exc).__name__}") from exc
    if response.status_code != 200:
        raise PushError(f"token request answered {response.status_code}")
    body = response.json()
    token = body.get("access_token")
    if not isinstance(token, str):
        raise PushError("token response has no access_token")
    expires_in = int(body.get("expires_in", 3600))
    _tokens[account.client_email] = (token, now + timedelta(seconds=expires_in) - TOKEN_MARGIN)
    return token


async def send(
    http: httpx.AsyncClient, account: ServiceAccount, message: dict[str, Any], *, now: datetime
) -> SendOutcome:
    """Send one message (``{"token": ..., "notification": ..., ...}``)."""
    token = await access_token(http, account, now=now)
    try:
        response = await http.post(
            SEND_URL.format(project=account.project_id),
            json={"message": message},
            headers={"Authorization": f"Bearer {token}"},
        )
    except httpx.HTTPError as exc:
        raise PushError(f"send failed: {type(exc).__name__}") from exc
    if response.status_code == 200:
        return SendOutcome.SENT
    if response.status_code == 401:
        _tokens.pop(account.client_email, None)  # try a fresh access token next time
    if response.status_code in (400, 404) and _is_bad_token(response):
        return SendOutcome.INVALID_TOKEN
    raise PushError(f"send answered {response.status_code}")


def _is_bad_token(response: httpx.Response) -> bool:
    """404 ``UNREGISTERED``, or 400 ``INVALID_ARGUMENT`` about the token."""
    try:
        error = response.json().get("error", {})
    except ValueError:
        return False
    codes = {
        detail.get("errorCode") for detail in error.get("details", []) if isinstance(detail, dict)
    }
    if "UNREGISTERED" in codes or error.get("status") == "NOT_FOUND":
        return True
    return error.get("status") == "INVALID_ARGUMENT" and "token" in str(error.get("message", ""))
