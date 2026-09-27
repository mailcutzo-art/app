#!/usr/bin/env python3
"""End-to-end journey check against a running stack.

    python3 infra/smoke_test.py http://localhost:8080

It walks the steps a new player takes, through the same front door the app uses, and stops at
the first step that breaks. It needs a stack started with ``./init-env.sh lan`` (developer
login on). CI runs it after ``docker compose up`` (see .github/workflows/infra.yml). Standard
library only, so it runs anywhere Python 3.11+ is installed.
"""

import json
import secrets
import sys
import urllib.error
import urllib.request
from collections.abc import Callable
from typing import Any

BASE = (sys.argv[1] if len(sys.argv) > 1 else "http://localhost:8080").rstrip("/")
DEVICE = {
    "install_id": f"smoke-{secrets.token_hex(6)}",
    "platform": "android",
    "app_version": "1.0.0",
    "build": 1,
}


class StepFailed(Exception):
    pass


def call(
    method: str, path: str, *, body: Any = None, token: str | None = None, expect: int = 200
) -> Any:
    request = urllib.request.Request(  # noqa: S310 - the URL is the stack under test
        BASE + path,
        method=method,
        data=None if body is None else json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
    )
    if token:
        request.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(request, timeout=15) as response:  # noqa: S310
            status, raw = response.status, response.read()
    except urllib.error.HTTPError as error:
        status, raw = error.code, error.read()
    data = json.loads(raw) if raw else None
    if status != expect:
        raise StepFailed(f"{method} {path}: expected {expect}, got {status}: {data}")
    return data


def error_code(data: Any) -> str | None:
    return data.get("error", {}).get("code") if isinstance(data, dict) else None


def check(condition: bool, message: str) -> None:
    if not condition:
        raise StepFailed(message)


def main() -> int:
    state: dict[str, Any] = {}
    suffix = secrets.token_hex(3)

    def service_is_up() -> None:
        call("GET", "/healthz")
        ready = call("GET", "/readyz")
        check(ready["status"] == "ok", f"not ready: {ready}")
        config = call("GET", "/v1/config")
        check("min_build" in config and "maintenance" in config, f"bad config: {config}")

    def new_player_signs_in() -> None:
        data = call(
            "POST",
            "/v1/auth/dev-login",
            body={"email": f"smoke-{suffix}@example.com", "display_name": "", "device": DEVICE},
        )
        check(data["is_new_user"] is True, "a fresh email should create a new player")
        check(data["user"]["onboarding_completed"] is False, "new players start onboarding")
        state.update(access=data["access_token"], refresh=data["refresh_token"])

    def profile_loads() -> None:
        me = call("GET", "/v1/me", token=state["access"])
        check(me["handle"] is None, "no username before onboarding")

    def username_check_works() -> None:
        handle = f"smoke_{suffix}"
        free = call("GET", f"/v1/handles/check?handle={handle}", token=state["access"])
        check(free == {"available": True}, f"{handle} should be free: {free}")
        taken = call("GET", "/v1/handles/check?handle=admin", token=state["access"])
        check(taken["available"] is False, "reserved names must not be available")
        state["handle"] = handle

    def onboarding_completes() -> None:
        me = call(
            "POST",
            "/v1/me/onboarding",
            token=state["access"],
            body={
                "display_name": "Smoke Tester",
                "handle": state["handle"],
                "avatar": {"tone": "sky", "symbol": "atom"},
                "goal": "neet",
                "birth_year": 2007,
            },
        )
        check(me["onboarding_completed"] is True and me["handle"] == state["handle"], str(me))
        again = call(
            "POST",
            "/v1/me/onboarding",
            token=state["access"],
            expect=409,
            body={
                "display_name": "Smoke Tester",
                "handle": state["handle"],
                "avatar": {"tone": "sky", "symbol": "atom"},
                "goal": "neet",
                "birth_year": 2007,
            },
        )
        check(error_code(again) == "ALREADY_ONBOARDED", f"repeat onboarding: {again}")

    def tokens_refresh_safely() -> None:
        first = call("POST", "/v1/auth/refresh", body={"refresh_token": state["refresh"]})
        # The app may crash before saving the new pair: the old token then gets the same pair.
        retry = call("POST", "/v1/auth/refresh", body={"refresh_token": state["refresh"]})
        check(retry["refresh_token"] == first["refresh_token"], "crash retry got a different pair")
        state.update(access=first["access_token"], refresh=first["refresh_token"])

    def device_list_shows_this_phone() -> None:
        sessions = call("GET", "/v1/me/sessions", token=state["access"])
        check(len(sessions) == 1 and sessions[0]["current"] is True, f"sessions: {sessions}")

    def sign_out_ends_the_session() -> None:
        call("POST", "/v1/auth/logout", token=state["access"], expect=204)
        after = call("GET", "/v1/me", token=state["access"], expect=401)
        check(error_code(after) == "SESSION_REVOKED", f"after logout: {after}")
        stale = call(
            "POST", "/v1/auth/refresh", body={"refresh_token": state["refresh"]}, expect=401
        )
        check(error_code(stale) is not None, "a signed-out refresh token must be rejected")

    steps: list[tuple[str, Callable[[], None]]] = [
        ("Service is up and serves its config", service_is_up),
        ("A new player signs in", new_player_signs_in),
        ("Their profile loads", profile_loads),
        ("The username check answers", username_check_works),
        ("Onboarding completes, and a repeat is recognised", onboarding_completes),
        ("Tokens refresh, and a crash retry gets the same pair", tokens_refresh_safely),
        ("The device list shows this phone", device_list_shows_this_phone),
        ("Signing out ends the session everywhere", sign_out_ends_the_session),
    ]
    for name, run in steps:
        try:
            run()
        except (StepFailed, KeyError, TypeError, urllib.error.URLError) as problem:
            print(f"✗ {name}\n  {problem}")  # noqa: T201 - this is a CLI report
            return 1
        print(f"✓ {name}")  # noqa: T201
    print(f"All {len(steps)} journey steps passed against {BASE}.")  # noqa: T201
    return 0


if __name__ == "__main__":
    sys.exit(main())
