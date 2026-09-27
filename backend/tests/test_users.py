"""The player's own profile: onboarding, edits, handle availability and role grants."""

from typing import Any

import pytest
from httpx import AsyncClient
from redis.asyncio import Redis
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.clock import utc_now
from app.modules.system.models import AuditLog
from app.modules.users import service
from app.modules.users.models import Role, User
from tests.helpers import FakeClock, bearer, dev_login

THIS_YEAR = utc_now().year  # tests never straddle New Year in India closely enough to matter


def onboarding(**overrides: Any) -> dict[str, Any]:
    return {
        "display_name": "Asha Verma",
        "handle": "asha_v",
        "avatar": {"tone": "mint", "symbol": "dna"},
        "goal": "neet",
        "birth_year": THIS_YEAR - 17,
        **overrides,
    }


@pytest.fixture
async def asha(client: AsyncClient) -> dict[str, str]:
    return bearer((await dev_login(client, "asha@example.com"))["access_token"])


@pytest.fixture
async def ravi(client: AsyncClient) -> dict[str, str]:
    return bearer((await dev_login(client, "ravi@example.com"))["access_token"])


async def test_onboarding_completes_the_profile(client: AsyncClient, asha: dict[str, str]) -> None:
    response = await client.post(
        "/v1/me/onboarding", json=onboarding(handle="Asha_V"), headers=asha
    )

    assert response.status_code == 200
    me = response.json()
    assert me["handle"] == "asha_v"  # stored lowercase
    assert me["display_name"] == "Asha Verma"
    assert me["avatar"] == {"tone": "mint", "symbol": "dna"}
    assert me["goal"] == "neet"
    assert me["birth_year"] == THIS_YEAR - 17
    assert me["is_minor"] is True
    assert me["onboarding_completed"] is True
    assert (await client.get("/v1/me", headers=asha)).json() == me


async def test_minors_grow_up(client: AsyncClient, asha: dict[str, str], clock: FakeClock) -> None:
    await client.post("/v1/me/onboarding", json=onboarding(birth_year=THIS_YEAR - 17), headers=asha)

    clock.advance(days=366)  # the flag follows the birth year, not the day of onboarding
    asha = bearer((await dev_login(client, "asha@example.com"))["access_token"])
    me = (await client.get("/v1/me", headers=asha)).json()

    assert me["is_minor"] is False
    assert me["email"] == "asha@example.com"


@pytest.mark.parametrize(("age", "minor"), [(17, True), (18, False), (40, False)])
async def test_minors_are_flagged_by_birth_year(
    client: AsyncClient, asha: dict[str, str], age: int, minor: bool
) -> None:
    response = await client.post(
        "/v1/me/onboarding", json=onboarding(birth_year=THIS_YEAR - age), headers=asha
    )

    assert response.json()["is_minor"] is minor


async def test_onboarding_happens_once(client: AsyncClient, asha: dict[str, str]) -> None:
    await client.post("/v1/me/onboarding", json=onboarding(), headers=asha)

    again = await client.post("/v1/me/onboarding", json=onboarding(), headers=asha)

    assert again.status_code == 409
    assert again.json()["error"]["code"] == "ALREADY_ONBOARDED"


async def test_taken_handles_are_refused(
    client: AsyncClient, asha: dict[str, str], ravi: dict[str, str]
) -> None:
    await client.post("/v1/me/onboarding", json=onboarding(handle="topper"), headers=asha)

    response = await client.post(
        "/v1/me/onboarding", json=onboarding(handle="TOPPER"), headers=ravi
    )

    assert response.status_code == 409
    error = response.json()["error"]
    assert error["code"] == "HANDLE_TAKEN"
    assert error["details"] == {"fields": {"handle": "That username is taken"}}


async def test_a_handle_race_is_a_409_not_a_500(
    client: AsyncClient,
    asha: dict[str, str],
    ravi: dict[str, str],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    await client.post("/v1/me/onboarding", json=onboarding(handle="topper"), headers=asha)

    async def not_taken_yet(*_: object) -> None:
        return None  # the other player commits right after our availability check

    monkeypatch.setattr(service, "_handle_owner", not_taken_yet)
    response = await client.post(
        "/v1/me/onboarding", json=onboarding(handle="topper"), headers=ravi
    )

    assert response.status_code == 409
    assert response.json()["error"]["code"] == "HANDLE_TAKEN"
    assert response.json()["error"]["details"]["fields"] == {"handle": "That username is taken"}


@pytest.mark.parametrize(
    ("field", "value", "message"),
    [
        ("display_name", "A", "Use 2–30 characters."),
        ("display_name", "x" * 31, "Use 2–30 characters."),
        ("display_name", "  ", "Use 2–30 characters."),
        ("display_name", "Asha https://spam.example", "Names can't include links."),
        ("display_name", "Asha from quizhub.com", "Names can't include links."),
        ("display_name", "Hi @ravi", "Names can't include @mentions."),
        ("display_name", "Call 98765 43210", "Names can't include phone numbers."),
        ("display_name", "Asha\u200bVerma", "Remove hidden or special characters."),
        ("display_name", "Asha\u202eamreV", "Remove hidden or special characters."),
        ("display_name", "Sh1t Head", "That name isn't allowed. Please choose another."),
        ("display_name", "Quiz Admin", "That name isn't allowed. Please choose another."),
        ("display_name", 42, "Enter your name."),
        ("handle", "ab", "Use 3–20 letters, numbers or _"),
        ("handle", "asha.verma", "Use 3–20 letters, numbers or _"),
        ("handle", "a" * 21, "Use 3–20 letters, numbers or _"),
        ("handle", "admin", "That username isn't allowed"),
        ("handle", "official_asha", "That username isn't allowed"),
        ("handle", "b1tch_99", "That username isn't allowed"),
        ("avatar", {"tone": "black", "symbol": "dna"}, "Choose one of the avatar colours."),
        ("avatar", {"tone": "mint", "symbol": "skull"}, "Choose one of the avatar symbols."),
        ("avatar", "mint", "Enter a valid value."),
        ("goal", "upsc", "Choose NEET or JEE."),
        ("goal", "NEET", "Choose NEET or JEE."),
        ("birth_year", THIS_YEAR - 9, "You need to be at least 10 to play."),
        ("birth_year", THIS_YEAR - 101, "Enter the year you were born."),
        ("birth_year", THIS_YEAR + 1, "Enter the year you were born."),
        ("birth_year", "2008", "Enter the year you were born."),
        ("birth_year", True, "Enter the year you were born."),
    ],
)
async def test_field_problems_are_explained_per_field(
    client: AsyncClient, asha: dict[str, str], field: str, value: Any, message: str
) -> None:
    response = await client.post(
        "/v1/me/onboarding", json=onboarding(**{field: value}), headers=asha
    )

    assert response.status_code == 422
    error = response.json()["error"]
    assert error["code"] == "VALIDATION_FAILED"
    assert error["details"]["fields"] == {field: message}


async def test_every_problem_is_reported_at_once(client: AsyncClient, asha: dict[str, str]) -> None:
    body = onboarding(display_name="A", handle="!!", goal="x", extra="field")
    del body["birth_year"]

    response = await client.post("/v1/me/onboarding", json=body, headers=asha)

    assert response.json()["error"]["details"]["fields"] == {
        "display_name": "Use 2–30 characters.",
        "handle": "Use 3–20 letters, numbers or _",
        "goal": "Choose NEET or JEE.",
        "birth_year": "This field is required.",
        "extra": "This field isn't allowed here.",
    }


async def test_display_names_are_tidied(client: AsyncClient, asha: dict[str, str]) -> None:
    response = await client.post(
        "/v1/me/onboarding",
        json=onboarding(display_name="  Asha   Verma 👩\u200d🔬  "),
        headers=asha,
    )

    assert response.json()["display_name"] == "Asha Verma 👩\u200d🔬"


async def test_devanagari_names_are_welcome(client: AsyncClient, asha: dict[str, str]) -> None:
    response = await client.post(
        "/v1/me/onboarding", json=onboarding(display_name="आशा वर्मा"), headers=asha
    )

    assert response.json()["display_name"] == "आशा वर्मा"


async def test_profile_edits(client: AsyncClient, asha: dict[str, str]) -> None:
    await client.post("/v1/me/onboarding", json=onboarding(), headers=asha)

    response = await client.patch(
        "/v1/me",
        json={"display_name": "Asha V", "avatar": {"tone": "rose", "symbol": "star"}},
        headers=asha,
    )
    goal_only = await client.patch("/v1/me", json={"goal": "jee"}, headers=asha)

    assert response.status_code == 200
    assert response.json()["display_name"] == "Asha V"
    assert response.json()["avatar"] == {"tone": "rose", "symbol": "star"}
    assert goal_only.json()["goal"] == "jee"
    assert goal_only.json()["display_name"] == "Asha V"


async def test_profile_edits_are_validated(client: AsyncClient, asha: dict[str, str]) -> None:
    response = await client.patch(
        "/v1/me", json={"display_name": "x", "handle": "new_handle"}, headers=asha
    )

    assert response.status_code == 422
    assert response.json()["error"]["details"]["fields"] == {
        "display_name": "Use 2–30 characters.",
        "handle": "This field isn't allowed here.",
    }


async def test_me_requires_authentication(client: AsyncClient) -> None:
    for request in (
        client.get("/v1/me"),
        client.patch("/v1/me", json={}),
        client.post("/v1/me/onboarding", json=onboarding()),
        client.get("/v1/handles/check", params={"handle": "asha_v"}),
    ):
        assert (await request).status_code == 401


# --- Handle availability -----------------------------------------------------------------


async def check(client: AsyncClient, headers: dict[str, str], handle: str) -> Any:
    response = await client.get("/v1/handles/check", params={"handle": handle}, headers=headers)
    assert response.status_code == 200, response.text
    return response.json()


async def test_handle_check(
    client: AsyncClient, asha: dict[str, str], ravi: dict[str, str]
) -> None:
    await client.post("/v1/me/onboarding", json=onboarding(handle="topper"), headers=asha)

    assert await check(client, ravi, "neet_ace") == {"available": True}
    assert await check(client, ravi, "Neet_Ace") == {"available": True}
    assert await check(client, ravi, "topper") == {"available": False, "reason": "taken"}
    assert await check(client, ravi, "TOPPER") == {"available": False, "reason": "taken"}
    assert await check(client, asha, "topper") == {"available": True}  # it's hers already
    assert await check(client, ravi, "ab") == {"available": False, "reason": "invalid"}
    assert await check(client, ravi, "a b c") == {"available": False, "reason": "invalid"}
    assert await check(client, ravi, "support") == {"available": False, "reason": "reserved"}
    assert await check(client, ravi, "sh1t_head") == {"available": False, "reason": "reserved"}


async def test_handle_check_is_rate_limited_per_user(
    client: AsyncClient, asha: dict[str, str], ravi: dict[str, str]
) -> None:
    for _ in range(30):
        await check(client, asha, "neet_ace")

    limited = await client.get("/v1/handles/check", params={"handle": "x1y"}, headers=asha)
    someone_else = await client.get("/v1/handles/check", params={"handle": "x1y"}, headers=ravi)

    assert limited.status_code == 429
    assert someone_else.status_code == 200


# --- Roles (scripts/create_admin.py) -----------------------------------------------------


async def test_granting_a_role_is_audited_and_applies_at_once(
    client: AsyncClient, asha: dict[str, str], db_session: AsyncSession, redis: Redis
) -> None:
    await client.post("/v1/me/onboarding", json=onboarding(handle="asha_v"), headers=asha)
    await client.get("/v1/me", headers=asha)  # caches the user's roles
    user = await service.find_user(db_session, "@asha_v")
    assert user is not None
    assert await service.find_user(db_session, "ASHA@example.com") == user

    granted = await service.grant_role(db_session, redis, user, Role.ADMIN)
    cached_after_grant = await redis.get(f"authz:{user.id}")
    again = await service.grant_role(db_session, redis, user, Role.ADMIN)

    assert (granted, again) == (True, False)
    assert cached_after_grant is None  # dropped, so role checks see the grant immediately
    assert (await client.get("/v1/me", headers=asha)).json()["roles"] == ["admin", "user"]
    entry = await db_session.scalar(select(AuditLog).where(AuditLog.entity_id == str(user.id)))
    assert entry is not None
    assert entry.action == "user.role_granted"
    assert (entry.before, entry.after) == ({"roles": ["user"]}, {"roles": ["admin", "user"]})


async def test_finding_users(db_session: AsyncSession) -> None:
    db_session.add_all(
        [
            User(display_name="One", email="shared@example.com", handle="one"),
            User(display_name="Two", email="shared@example.com", handle="two"),
        ]
    )
    await db_session.flush()

    two = await service.find_user(db_session, "TWO")
    assert two is not None
    assert two.display_name == "Two"
    assert await service.find_user(db_session, "nobody") is None
    with pytest.raises(LookupError):
        await service.find_user(db_session, "shared@example.com")
