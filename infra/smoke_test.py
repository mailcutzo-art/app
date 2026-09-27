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
from datetime import UTC, datetime
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
    method: str,
    path: str,
    *,
    body: Any = None,
    token: str | None = None,
    expect: int = 200,
    headers: dict[str, str] | None = None,
) -> Any:
    request = urllib.request.Request(  # noqa: S310 - the URL is the stack under test
        BASE + path,
        method=method,
        data=None if body is None else json.dumps(body).encode(),
        headers={"Content-Type": "application/json", **(headers or {})},
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

    def catalog_lists_the_content() -> None:
        catalog = call("GET", "/v1/catalog", token=state["access"])
        subjects = {subject["slug"]: subject for subject in catalog["subjects"]}
        check({"physics", "chemistry", "biology"} <= set(subjects), f"subjects: {list(subjects)}")
        physics = subjects["physics"]
        check(physics["question_count"] > 0 and physics["chapters"], "physics has no questions")
        chapter = physics["chapters"][0]
        check(chapter["topics"] and chapter["question_count"] > 0, f"empty chapter: {chapter}")
        state["chapter"] = chapter

    def progress_starts_empty() -> None:
        progress = call("GET", "/v1/me/progress", token=state["access"])
        answered = sum(subject["answered"] for subject in progress["subjects"])
        check(answered == 0 and progress["continue"] is None, f"new player progress: {progress}")

    def practice_starts_once() -> None:
        body = {"mode": "chapter", "subject": "physics", "chapters": [state["chapter"]["slug"]]}
        key = {"Idempotency-Key": secrets.token_hex(8)}
        session = call(
            "POST",
            "/v1/practice/sessions",
            token=state["access"],
            body=body,
            expect=201,
            headers=key,
        )
        check(session["questions"], "the session has no questions")
        retry = call(
            "POST",
            "/v1/practice/sessions",
            token=state["access"],
            body=body,
            expect=201,
            headers=key,
        )
        check(retry["session_id"] == session["session_id"], "a retry created a second session")
        state["session"] = session

    def answers_count_once() -> None:
        session = state["session"]
        answers = [
            {
                "client_answer_id": secrets.token_hex(8),
                "ref": question["ref"],
                "position": question["position"],
                # Right on every question but the first.
                "selected_option": question["answer"]
                if question["position"] > 1
                else (question["answer"] + 1) % 4,
                "time_ms": 4000,
                "answered_at": datetime.now(UTC).isoformat(),
            }
            for question in session["questions"]
        ]
        path = f"/v1/practice/sessions/{session['session_id']}/answers"
        first = call("POST", path, token=state["access"], body={"answers": answers})
        statuses = [result["status"] for result in first["results"]]
        check(statuses == ["accepted"] * len(answers), f"first upload: {statuses}")
        again = call("POST", path, token=state["access"], body={"answers": answers[:1]})
        check(again["results"][0]["status"] == "duplicate", f"re-upload: {again['results']}")

    def finishing_shows_the_totals() -> None:
        session = state["session"]
        result = call(
            "POST",
            f"/v1/practice/sessions/{session['session_id']}/finish",
            token=state["access"],
        )
        count = len(session["questions"])
        check(
            result["answered"] == count and result["correct"] == count - 1,
            f"result: {result}",
        )
        # 2 XP for each right answer and 1 for the wrong one.
        check(result["xp"]["delta"] == 2 * count - 1, f"xp: {result['xp']}")

    def a_question_can_be_bookmarked() -> None:
        ref = state["session"]["questions"][0]["ref"]
        call("PUT", f"/v1/me/bookmarks/{ref}", token=state["access"], expect=204)
        bookmarks = call("GET", "/v1/me/bookmarks", token=state["access"])
        check([item["ref"] for item in bookmarks["items"]] == [ref], f"bookmarks: {bookmarks}")

    def progress_counts_the_answers() -> None:
        progress = call("GET", "/v1/me/progress", token=state["access"])
        physics = next(s for s in progress["subjects"] if s["slug"] == "physics")
        count = len(state["session"]["questions"])
        check(
            physics["answered"] == count and physics["correct"] == count - 1,
            f"physics progress: {physics}",
        )
        chapter = next(c for c in physics["chapters"] if c["slug"] == state["chapter"]["slug"])
        check(chapter["seen"] == count, f"chapter progress: {chapter}")

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
        ("The Learn catalog lists the loaded subjects and chapters", catalog_lists_the_content),
        ("Progress starts empty", progress_starts_empty),
        ("Chapter practice starts, and a retry returns the same session", practice_starts_once),
        ("Every answer counts once, even when uploaded twice", answers_count_once),
        ("Finishing the session shows the right totals", finishing_shows_the_totals),
        ("A question can be bookmarked", a_question_can_be_bookmarked),
        ("Progress now counts the answers", progress_counts_the_answers),
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
