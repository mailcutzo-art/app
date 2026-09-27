"""Log rendering and redaction of secrets and personal data."""

import logging

import orjson
import pytest
import structlog

from app.core.logging import REDACTED, configure_logging, redact_sensitive
from tests.helpers import make_settings


def test_redacts_sensitive_keys_at_any_depth() -> None:
    event = {
        "event": "auth.google",
        "password": "hunter2",
        "Authorization": "Bearer abc",
        "refresh_token": "rt",
        "user_email": "a@b.c",
        "headers": {"cookie": "sid=1", "set-cookie": "sid=2", "accept": "json"},
        "attempts": [{"id_token": "jwt", "status": 401}],
        "user_id": "u1",
    }

    redacted = redact_sensitive(None, "info", event)

    assert redacted == {
        "event": "auth.google",
        "password": REDACTED,
        "Authorization": REDACTED,
        "refresh_token": REDACTED,
        "user_email": REDACTED,
        "headers": {"cookie": REDACTED, "set-cookie": REDACTED, "accept": "json"},
        "attempts": [{"id_token": REDACTED, "status": 401}],
        "user_id": "u1",
    }


def test_json_lines_are_redacted_and_tracebacks_have_no_locals(
    capsys: pytest.CaptureFixture[str],
) -> None:
    configure_logging(make_settings())
    log = structlog.stdlib.get_logger("tests.logging")

    log.info("signed_in", email="a@b.c", phone="+911234567890", user_id="u1")
    try:
        ticket = "super-secret-ticket"
        raise ValueError(f"bad ticket length {len(ticket)}")
    except ValueError:
        log.exception("ws.handshake_failed")
    logging.getLogger("thirdparty").warning("stdlib %s", "works", extra={"token": "t0k"})

    lines = [orjson.loads(line) for line in capsys.readouterr().out.splitlines()]
    signed_in, failure, foreign = lines[-3:]
    assert signed_in["email"] == REDACTED
    assert signed_in["phone"] == REDACTED
    assert signed_in["user_id"] == "u1"
    assert signed_in["level"] == "info"
    assert "timestamp" in signed_in
    assert failure["exception"][0]["exc_type"] == "ValueError"
    assert "super-secret-ticket" not in orjson.dumps(failure).decode()
    assert foreign["event"] == "stdlib works"
    assert foreign["logger"] == "thirdparty"


def test_uvicorn_websocket_lines_with_client_addresses_are_dropped(
    caplog: pytest.LogCaptureFixture,
) -> None:
    configure_logging(make_settings())
    caplog.set_level(logging.INFO)
    uvicorn_log = logging.getLogger("uvicorn.error")

    uvicorn_log.info('%s - "WebSocket %s" [accepted]', "203.0.113.9:5555", "/v1/ws?ticket=abc")
    uvicorn_log.info("connection open")
    uvicorn_log.info("Application startup complete.")

    assert [record.getMessage() for record in caplog.records] == ["Application startup complete."]
