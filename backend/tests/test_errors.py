"""Every failure is rendered as the standard error envelope."""

import logging
import uuid
from typing import Any

import pytest
from fastapi import APIRouter, FastAPI, HTTPException
from httpx import AsyncClient
from redis.exceptions import ConnectionError as RedisConnectionError

from app.core.errors import Conflict, RateLimited, Unauthorized
from app.core.schemas import ApiModel, Lax
from tests.helpers import log_events

router = APIRouter(prefix="/test")


class Payload(ApiModel):
    count: int
    user_id: Lax[uuid.UUID]


@router.post("/validate")
async def validate(payload: Payload) -> dict[str, Any]:
    return {"count": payload.count, "user_id": str(payload.user_id)}


@router.get("/conflict")
async def conflict() -> None:
    raise Conflict("Handle already taken.", code="HANDLE_TAKEN", details={"handle": "neet_ace"})


@router.get("/unauthorized")
async def unauthorized() -> None:
    raise Unauthorized()


@router.get("/rate-limited")
async def rate_limited() -> None:
    raise RateLimited(retry_after=7)


@router.get("/http-exception")
async def http_exception() -> None:
    raise HTTPException(status_code=403, detail="Nope.")


@router.get("/redis-down")
async def redis_down() -> None:
    raise RedisConnectionError("Error 111 connecting to redis:6379. Connection refused.")


@router.get("/crash")
async def crash() -> None:
    secret = "hunter2"  # must never reach the client
    raise RuntimeError(f"database password is {secret}")


@pytest.fixture
def app(app: FastAPI) -> FastAPI:
    app.include_router(router)
    return app


def assert_envelope(body: dict[str, Any], *, code: str, request_id: str) -> dict[str, Any]:
    assert set(body) == {"error"}
    error: dict[str, Any] = body["error"]
    assert set(error) == {"code", "message", "details", "request_id"}
    assert error["code"] == code
    assert isinstance(error["message"], str)
    assert error["message"]
    assert error["request_id"] == request_id
    return error


async def test_unknown_route_is_404(client: AsyncClient) -> None:
    response = await client.get("/nope")

    assert response.status_code == 404
    assert_envelope(response.json(), code="NOT_FOUND", request_id=response.headers["X-Request-ID"])


async def test_wrong_method_is_405_with_allow_header(client: AsyncClient) -> None:
    response = await client.delete("/healthz")

    assert response.status_code == 405
    assert response.headers["Allow"] == "GET"
    assert_envelope(
        response.json(), code="METHOD_NOT_ALLOWED", request_id=response.headers["X-Request-ID"]
    )


async def test_validation_error_is_422_without_echoing_input(client: AsyncClient) -> None:
    response = await client.post(
        "/test/validate", json={"count": "3", "user_id": "not-a-uuid", "password": "hunter2"}
    )

    assert response.status_code == 422
    error = assert_envelope(
        response.json(), code="VALIDATION_FAILED", request_id=response.headers["X-Request-ID"]
    )
    problems = {tuple(item["loc"]): item["type"] for item in error["details"]["errors"]}
    assert problems == {
        ("body", "count"): "int_type",  # strict: no "3" -> 3 coercion
        ("body", "user_id"): "uuid_parsing",
        ("body", "password"): "extra_forbidden",
    }
    assert all(set(item) == {"loc", "msg", "type"} for item in error["details"]["errors"])
    # A flat map the app shows next to each field.
    assert error["details"]["fields"] == {
        "count": "Enter a whole number.",
        "user_id": "This isn't a valid ID.",
        "password": "This field isn't allowed here.",
    }
    assert "hunter2" not in response.text


async def test_lax_fields_accept_json_strings(client: AsyncClient) -> None:
    user_id = uuid.uuid4()

    response = await client.post("/test/validate", json={"count": 3, "user_id": str(user_id)})

    assert response.status_code == 200
    assert response.json() == {"count": 3, "user_id": str(user_id)}


async def test_malformed_json_is_422(client: AsyncClient) -> None:
    response = await client.post(
        "/test/validate", content=b"{", headers={"Content-Type": "application/json"}
    )

    assert response.status_code == 422
    assert response.json()["error"]["code"] == "VALIDATION_FAILED"
    assert response.json()["error"]["details"]["fields"] == {}


async def test_app_error_carries_code_message_and_details(client: AsyncClient) -> None:
    response = await client.get("/test/conflict")

    assert response.status_code == 409
    error = assert_envelope(
        response.json(), code="HANDLE_TAKEN", request_id=response.headers["X-Request-ID"]
    )
    assert error["message"] == "Handle already taken."
    assert error["details"] == {"handle": "neet_ace"}


async def test_unauthorized_advertises_bearer_auth(client: AsyncClient) -> None:
    response = await client.get("/test/unauthorized")

    assert response.status_code == 401
    assert response.headers["WWW-Authenticate"] == "Bearer"
    assert response.json()["error"]["code"] == "UNAUTHORIZED"


async def test_rate_limited_sets_retry_after(client: AsyncClient) -> None:
    response = await client.get("/test/rate-limited")

    assert response.status_code == 429
    assert response.headers["Retry-After"] == "7"
    error = response.json()["error"]
    assert error["code"] == "RATE_LIMITED"
    assert error["details"] == {"retry_after": 7}


async def test_http_exception_is_wrapped(client: AsyncClient) -> None:
    response = await client.get("/test/http-exception")

    assert response.status_code == 403
    error = assert_envelope(
        response.json(), code="FORBIDDEN", request_id=response.headers["X-Request-ID"]
    )
    assert error["message"] == "Nope."


async def test_unreachable_dependency_is_503(client: AsyncClient) -> None:
    response = await client.get("/test/redis-down")

    assert response.status_code == 503
    assert response.headers["Retry-After"] == "1"
    error = response.json()["error"]
    assert error["code"] == "SERVICE_UNAVAILABLE"
    assert "6379" not in response.text


async def test_unhandled_exception_is_500_without_internals(
    client: AsyncClient, caplog: pytest.LogCaptureFixture
) -> None:
    caplog.set_level(logging.INFO)

    response = await client.get("/test/crash")

    assert response.status_code == 500
    request_id = response.headers["X-Request-ID"]
    assert_envelope(response.json(), code="INTERNAL_ERROR", request_id=request_id)
    assert "hunter2" not in response.text
    assert "Traceback" not in response.text
    assert "RuntimeError" not in response.text
    [logged] = log_events(caplog, "http.unhandled_error")
    assert logged["request_id"] == request_id
    assert logged["exc_info"] is True
