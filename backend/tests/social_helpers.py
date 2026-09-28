"""Helpers for the social and account tests: signed-in, onboarded players."""

import uuid
from dataclasses import dataclass
from typing import Any

from httpx import AsyncClient

from app.core.clock import utc_now
from tests.helpers import bearer, dev_login

THIS_YEAR = utc_now().year
ADULT = THIS_YEAR - 30
MINOR = THIS_YEAR - 16


@dataclass
class Player:
    id: uuid.UUID
    handle: str
    headers: dict[str, str]
    login: dict[str, Any]

    @property
    def uid(self) -> str:
        return str(self.id)


async def player(
    client: AsyncClient, name: str, *, birth_year: int = ADULT, handle: str | None = None
) -> Player:
    """Sign in with dev login as ``{name}@example.com`` and finish onboarding."""
    login = await dev_login(client, f"{name}@example.com", install_id=f"install-{name}")
    headers = bearer(login["access_token"])
    handle = handle or f"{name}_{uuid.uuid4().hex[:6]}"
    response = await client.post(
        "/v1/me/onboarding",
        headers=headers,
        json={
            "display_name": name.title(),
            "handle": handle,
            "avatar": {"tone": "sky", "symbol": "atom"},
            "goal": "neet",
            "birth_year": birth_year,
        },
    )
    assert response.status_code == 200, response.text
    return Player(uuid.UUID(login["user"]["id"]), handle, headers, login)


async def befriend(client: AsyncClient, a: Player, b: Player) -> None:
    sent = await client.post("/v1/friend-requests", json={"user_id": b.uid}, headers=a.headers)
    assert sent.status_code == 201, sent.text
    accepted = await client.post(
        f"/v1/friend-requests/{sent.json()['id']}/accept", headers=b.headers
    )
    assert accepted.status_code == 200, accepted.text


async def friend_ids(client: AsyncClient, who: Player) -> list[str]:
    response = await client.get("/v1/me/friends", headers=who.headers)
    assert response.status_code == 200, response.text
    return [item["id"] for item in response.json()["items"]]
