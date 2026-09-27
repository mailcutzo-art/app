"""Request ids and the access log."""

import logging
import re

import pytest
from httpx import AsyncClient

from tests.helpers import log_events


async def test_generates_a_request_id_when_none_is_sent(client: AsyncClient) -> None:
    first = await client.get("/v1/config")
    second = await client.get("/v1/config")

    assert re.fullmatch(r"[0-9a-f]{32}", first.headers["X-Request-ID"])
    assert first.headers["X-Request-ID"] != second.headers["X-Request-ID"]


async def test_echoes_a_safe_incoming_request_id(client: AsyncClient) -> None:
    response = await client.get("/nope", headers={"X-Request-ID": "mobile-7f3a.9c_01"})

    assert response.headers["X-Request-ID"] == "mobile-7f3a.9c_01"
    assert response.json()["error"]["request_id"] == "mobile-7f3a.9c_01"


@pytest.mark.parametrize(
    "incoming",
    ["short", "x" * 129, "has spaces in it", "quote\"injection'", "semi;colon=value"],
)
async def test_replaces_an_unsafe_incoming_request_id(client: AsyncClient, incoming: str) -> None:
    response = await client.get("/v1/config", headers={"X-Request-ID": incoming})

    assert re.fullmatch(r"[0-9a-f]{32}", response.headers["X-Request-ID"])


async def test_access_log_has_no_query_string(
    client: AsyncClient, caplog: pytest.LogCaptureFixture
) -> None:
    caplog.set_level(logging.INFO)

    response = await client.get("/v1/config?token=secret-value")

    [entry] = log_events(caplog, "http.request")
    assert entry["method"] == "GET"
    assert entry["path"] == "/v1/config"
    assert entry["status"] == 200
    assert entry["duration_ms"] >= 0
    assert entry["request_id"] == response.headers["X-Request-ID"]
    assert "secret-value" not in caplog.text


async def test_successful_probes_are_not_access_logged(
    client: AsyncClient, caplog: pytest.LogCaptureFixture
) -> None:
    caplog.set_level(logging.INFO)

    await client.get("/healthz")

    assert log_events(caplog, "http.request") == []
