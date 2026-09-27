"""Helpers for the Learn and practice tests (the content is the repository's question bank)."""

import secrets
import uuid
from datetime import datetime
from typing import Any

from httpx import AsyncClient

from tests.helpers import bearer, dev_login


async def player(client: AsyncClient, name: str = "asha", *, goal: str = "neet") -> dict[str, str]:
    """A signed-in, onboarded player; returns the auth headers."""
    login = await dev_login(client, f"{name}@example.com", install_id=f"install-{name}")
    headers = bearer(login["access_token"])
    response = await client.post(
        "/v1/me/onboarding",
        headers=headers,
        json={
            "display_name": name.title(),
            "handle": f"{name}_{secrets.token_hex(3)}",
            "avatar": {"tone": "mint", "symbol": "dna"},
            "goal": goal,
            "birth_year": 2000,
        },
    )
    assert response.status_code == 200, response.text
    return headers


async def signin(client: AsyncClient, name: str = "asha") -> dict[str, str]:
    """Fresh auth headers for an existing player (after moving the clock past token expiry)."""
    login = await dev_login(client, f"{name}@example.com", install_id=f"install-{name}")
    return bearer(login["access_token"])


async def start(
    client: AsyncClient, headers: dict[str, str], *, expect: int = 201, **body: Any
) -> dict[str, Any]:
    """Create a practice session (chapter practice of Kinematics unless told otherwise)."""
    payload = {"mode": "chapter", "subject": "physics", "chapters": ["kinematics"], **body}
    response = await client.post(
        "/v1/practice/sessions",
        json=payload,
        headers={**headers, "Idempotency-Key": secrets.token_hex(8)},
    )
    assert response.status_code == expect, response.text
    data: dict[str, Any] = response.json()
    return data


def answer(
    question: dict[str, Any],
    *,
    correct: bool = True,
    at: datetime,
    time_ms: int = 5000,
    **overrides: Any,
) -> dict[str, Any]:
    """An answer to a session question, right or wrong."""
    choice = question["answer"] if correct else (question["answer"] + 1) % 4
    return {
        "client_answer_id": str(uuid.uuid4()),
        "ref": question["ref"],
        "position": question["position"],
        "selected_option": choice,
        "time_ms": time_ms,
        "answered_at": at.isoformat(),
        **overrides,
    }


async def upload(
    client: AsyncClient,
    headers: dict[str, str],
    session_id: str,
    answers: list[dict[str, Any]],
    *,
    expect: int = 200,
) -> dict[str, Any]:
    response = await client.post(
        f"/v1/practice/sessions/{session_id}/answers", json={"answers": answers}, headers=headers
    )
    assert response.status_code == expect, response.text
    data: dict[str, Any] = response.json()
    return data


def statuses(result: dict[str, Any]) -> list[str]:
    return [item["status"] for item in result["results"]]
