"""Admin writes: audited users, versioned questions, the report queue, app config, read-only
views."""

import uuid
from collections.abc import AsyncIterator
from typing import Any

import pytest
from httpx import AsyncClient
from redis.asyncio import Redis
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.modules.content.hooks import ReportResolved, on_report_resolved, report_outcome_notice
from app.modules.content.models import (
    ContentStatus,
    Question,
    QuestionReport,
    ReportResolution,
    WordPuzzle,
)
from app.modules.content.refs import question_ref
from app.modules.system.models import AppConfig
from tests.admin_helpers import (
    ORIGIN,
    admin_client,
    admin_settings,
    audit_rows,
    make_user,
    signed_in_admin,
    user_row,
)
from tests.helpers import FakeClock, bearer
from tests.learn_helpers import player
from tests.test_importer import GOOD, to_json


@pytest.fixture
async def admin(
    session_factory: async_sessionmaker[AsyncSession],
    db_session: AsyncSession,
    clock: FakeClock,
    redis: Redis,
) -> AsyncIterator[tuple[AsyncClient, uuid.UUID]]:
    """A client signed in to the panel as an admin, and the admin's id."""
    async with admin_client(admin_settings(), session_factory, clock) as client:
        admin_id = await signed_in_admin(client, db_session, "root@example.com")
        yield client, admin_id


async def _question(db: AsyncSession, external_id: str) -> Question:
    question = await db.scalar(
        select(Question)
        .where(Question.external_id == external_id, Question.status != ContentStatus.RETIRED.value)
        .execution_options(populate_existing=True)
    )
    assert question is not None
    return question


def _question_form(question: Question, **changes: Any) -> dict[str, Any]:
    form: dict[str, Any] = {
        "topic_id": str(question.topic_id),
        "category": question.category,
        "difficulty": str(question.difficulty),
        "exams": list(question.exams or []),
        "battle_pool": question.battle_pool,
        "status": question.status,
        "stem": question.stem,
        "option_a": question.options[0],
        "option_b": question.options[1],
        "option_c": question.options[2],
        "option_d": question.options[3],
        "answer": "ABCD"[question.answer],
        "explanation": question.explanation,
        "tags": ", ".join(question.tags),
        "save": "Save",
    }
    form.update(changes)
    return form


# --- Users -----------------------------------------------------------------------------------


async def test_banning_a_player_is_audited_and_ends_their_sessions(
    admin: tuple[AsyncClient, uuid.UUID], db_session: AsyncSession, clock: FakeClock
) -> None:
    client, admin_id = admin
    login = await make_user(client, db_session, "cheat@example.com", roles=("user",))
    player_id = uuid.UUID(login["user"]["id"])
    headers = bearer(login["access_token"])
    assert (await client.get("/v1/me", headers=headers)).status_code == 200

    page = await client.get(f"/admin/user/edit/{player_id}")
    response = await client.post(
        f"/admin/user/edit/{player_id}",
        data={"status": "banned", "roles": ["user"], "ban_reason": "cheating", "save": "Save"},
        headers=ORIGIN,
    )

    assert page.status_code == 200
    assert response.status_code == 302, response.text
    user = await user_row(db_session, player_id)
    assert (user.status, user.ban_reason, user.banned_until) == ("banned", "cheating", None)
    assert user.token_version == 1
    me = await client.get("/v1/me", headers=headers)
    assert me.status_code == 403
    assert me.json()["error"]["code"] == "ACCOUNT_BANNED"
    refresh = await client.post("/v1/auth/refresh", json={"refresh_token": login["refresh_token"]})
    assert refresh.status_code == 403
    assert refresh.json()["error"]["code"] == "ACCOUNT_BANNED"
    [entry] = await audit_rows(db_session, action="user.updated")
    assert entry.actor_id == admin_id
    assert entry.entity_id == str(player_id)
    assert entry.before["status"] == "active"
    assert entry.before["token_version"] == 0
    assert entry.after["status"] == "banned"
    assert entry.after["token_version"] == 1
    assert entry.ip == "127.0.0.1"


async def test_a_temporary_ban_and_a_role_grant(
    admin: tuple[AsyncClient, uuid.UUID], db_session: AsyncSession, clock: FakeClock
) -> None:
    client, _ = admin
    login = await make_user(client, db_session, "mod@example.com", roles=("user",))
    player_id = uuid.UUID(login["user"]["id"])

    until = (clock.now.replace(microsecond=0, second=0)).strftime("%Y-%m-%dT%H:%M")
    past = await client.post(
        f"/admin/user/edit/{player_id}",
        data={"status": "banned", "roles": ["user"], "ban_reason": "abuse", "banned_until": until},
        headers=ORIGIN,
    )
    no_reason = await client.post(
        f"/admin/user/edit/{player_id}",
        data={"status": "banned", "roles": ["user"]},
        headers=ORIGIN,
    )
    promote = await client.post(
        f"/admin/user/edit/{player_id}",
        data={"status": "active", "roles": ["moderator"], "save": "Save"},
        headers=ORIGIN,
    )

    assert past.status_code == 400
    assert "must end in the future" in past.text
    assert no_reason.status_code == 400
    assert "needs a reason" in no_reason.text
    assert promote.status_code == 302
    user = await user_row(db_session, player_id)
    assert user.roles == ["moderator", "user"]
    assert user.token_version == 1  # a role change reissues tokens
    assert len(await audit_rows(db_session, action="user.updated")) == 1


async def test_admins_cannot_lock_themselves_out(
    admin: tuple[AsyncClient, uuid.UUID], db_session: AsyncSession
) -> None:
    client, admin_id = admin

    response = await client.post(
        f"/admin/user/edit/{admin_id}",
        data={"status": "active", "roles": ["user"], "save": "Save"},
        headers=ORIGIN,
    )

    assert response.status_code == 400
    assert "demote yourself" in response.text
    assert "admin" in (await user_row(db_session, admin_id)).roles


async def test_users_cannot_be_created_or_deleted(admin: tuple[AsyncClient, uuid.UUID]) -> None:
    client, admin_id = admin

    create = await client.get("/admin/user/create")
    delete = await client.delete(f"/admin/user/delete?pks={admin_id}", headers=ORIGIN)

    assert create.status_code == 403
    assert delete.status_code == 403


# --- Questions --------------------------------------------------------------------------------


async def test_the_question_list_searches_and_filters(
    admin: tuple[AsyncClient, uuid.UUID], db_session: AsyncSession
) -> None:
    client, _ = admin
    question = await _question(db_session, "phy-kin-001")

    search = await client.get("/admin/question/list", params={"search": "phy-kin-001"})
    by_subject = await client.get(
        "/admin/question/list", params={"subject": str(question.subject_id)}
    )
    by_chapter = await client.get(
        "/admin/question/list",
        params={"subject": str(question.subject_id), "chapter": str(question.chapter_id)},
    )
    by_status = await client.get("/admin/question/list", params={"status": "retired"})
    details = await client.get(f"/admin/question/details/{question.id}")

    assert search.status_code == 200
    assert "phy-kin-001" in search.text
    assert "phy-kin-001" in by_chapter.text
    assert "phy-lom-001" not in by_chapter.text
    assert by_subject.status_code == 200
    assert "Motion in a Straight Line" in by_chapter.text  # the chapter filter's choices
    assert "phy-kin-001" not in by_status.text
    assert "✓" in details.text


async def test_editing_a_published_question_makes_a_new_version(
    admin: tuple[AsyncClient, uuid.UUID], db_session: AsyncSession
) -> None:
    client, admin_id = admin
    old = await _question(db_session, "phy-kin-001")
    last_seq = await db_session.scalar(
        select(func.max(Question.seq)).where(Question.subject_id == old.subject_id)
    )
    stem = old.stem.replace("runner", "sprinter")

    page = await client.get(f"/admin/question/edit/{old.id}")
    response = await client.post(
        f"/admin/question/edit/{old.id}",
        data=_question_form(old, stem=stem, answer="A", save="Save and continue editing"),
        headers=ORIGIN,
    )

    assert page.status_code == 200
    assert "A runner completes one full lap" in page.text
    assert response.status_code == 302, response.text
    new = await _question(db_session, "phy-kin-001")
    assert new.id != old.id
    assert response.headers["location"].endswith(f"/admin/question/edit/{new.id}")
    await db_session.refresh(old)
    assert old.status == "retired"
    assert old.stem != stem  # the old row is never changed beyond its retirement
    assert (new.stem, new.status, new.supersedes_id) == (stem, "published", old.id)
    assert new.seq == last_seq + 1
    assert new.content_hash != old.content_hash
    assert "sprinter" in new.search_text
    superseded, created = await audit_rows(db_session, entity_type="question")
    assert (superseded.action, superseded.entity_id) == ("question.superseded", str(old.id))
    assert superseded.before["status"] == "published"
    assert superseded.after["status"] == "retired"
    assert (created.action, created.entity_id) == ("question.created", str(new.id))
    assert created.after["supersedes_id"] == str(old.id)
    assert created.actor_id == superseded.actor_id == admin_id


async def test_reserving_a_question_for_battles_changes_it_in_place(
    admin: tuple[AsyncClient, uuid.UUID], db_session: AsyncSession
) -> None:
    client, _ = admin
    question = await _question(db_session, "phy-kin-002")

    response = await client.post(
        f"/admin/question/edit/{question.id}",
        data=_question_form(question, battle_pool="reserved"),
        headers=ORIGIN,
    )

    assert response.status_code == 302, response.text
    same = await _question(db_session, "phy-kin-002")
    assert (same.id, same.battle_pool) == (question.id, "reserved")
    [entry] = await audit_rows(db_session, action="question.updated")
    assert (entry.before["battle_pool"], entry.after["battle_pool"]) == ("shared", "reserved")


async def test_a_draft_question_is_edited_in_place(
    admin: tuple[AsyncClient, uuid.UUID], db_session: AsyncSession
) -> None:
    client, _ = admin
    question = await _question(db_session, "phy-kin-003")
    question.status = "review"
    await db_session.commit()

    response = await client.post(
        f"/admin/question/edit/{question.id}",
        data=_question_form(question, explanation="A clearer explanation of the slope."),
        headers=ORIGIN,
    )

    assert response.status_code == 302, response.text
    same = await _question(db_session, "phy-kin-003")
    assert same.id == question.id
    assert same.explanation == "A clearer explanation of the slope."


@pytest.mark.parametrize(
    ("changes", "message"),
    [
        ({"option_b": "zero"}, "options must all be different"),
        ({"option_c": "All of the above"}, "refers to other options"),
        ({"stem": "Too short"}, "stem must be 10–700 characters"),
        ({"stem": "What is \\frac{1}{2} of the track?"}, "LaTeX is not supported"),
        ({"topic_id": "999999"}, "There is no topic 999999"),
        ({"exams": ["neet", "neet"]}, "exams must not repeat"),
    ],
)
async def test_invalid_question_edits_change_nothing(
    admin: tuple[AsyncClient, uuid.UUID],
    db_session: AsyncSession,
    changes: dict[str, Any],
    message: str,
) -> None:
    client, _ = admin
    question = await _question(db_session, "phy-kin-001")

    response = await client.post(
        f"/admin/question/edit/{question.id}",
        data=_question_form(question, **changes),
        headers=ORIGIN,
    )

    assert response.status_code == 400
    assert message.replace("'", "&#39;") in response.text
    same = await _question(db_session, "phy-kin-001")
    assert (same.id, same.stem, same.status) == (question.id, question.stem, "published")
    assert not await audit_rows(db_session, entity_type="question")


async def test_a_topic_of_another_subject_is_refused(
    admin: tuple[AsyncClient, uuid.UUID], db_session: AsyncSession
) -> None:
    client, _ = admin
    question = await _question(db_session, "phy-kin-001")
    chemistry = await _question(db_session, "che-atom-001")

    response = await client.post(
        f"/admin/question/edit/{question.id}",
        data=_question_form(question, topic_id=str(chemistry.topic_id)),
        headers=ORIGIN,
    )

    assert response.status_code == 400
    assert "chapter of the question" in response.text


async def test_retired_questions_cannot_be_edited(
    admin: tuple[AsyncClient, uuid.UUID], db_session: AsyncSession
) -> None:
    client, _ = admin
    question = await _question(db_session, "phy-kin-004")
    question.status = "retired"
    await db_session.commit()

    response = await client.post(
        f"/admin/question/edit/{question.id}",
        data=_question_form(question, stem="What is the SI unit of speed, exactly?"),
        headers=ORIGIN,
    )

    assert response.status_code == 400
    assert "retired questions are history" in response.text


# --- The report queue -------------------------------------------------------------------------


@pytest.fixture
def resolved_events() -> Any:
    events: list[ReportResolved] = []

    async def hook(db: AsyncSession, event: ReportResolved) -> None:
        assert db.in_transaction()
        events.append(event)

    on_report_resolved.register(hook)
    yield events
    on_report_resolved.unregister(hook)


async def _report(client: AsyncClient, name: str, question: Question, reason: str) -> None:
    headers = await player(client, name)
    response = await client.post(
        f"/v1/questions/{question_ref(question.id)}/reports",
        json={"reason": reason, "note": f"{name} thinks so"},
        headers=headers,
    )
    assert response.status_code == 202, response.text


async def test_the_queue_lists_open_reports_and_closes_them_together(
    admin: tuple[AsyncClient, uuid.UUID],
    db_session: AsyncSession,
    resolved_events: list[ReportResolved],
) -> None:
    client, admin_id = admin
    question = await _question(db_session, "phy-kin-005")
    other = await _question(db_session, "phy-kin-006")
    await _report(client, "asha", question, "wrong_answer")
    await _report(client, "ravi", question, "typo")
    await _report(client, "meera", other, "unclear")
    reports = list(
        await db_session.scalars(
            select(QuestionReport)
            .where(QuestionReport.question_id == question.id)
            .order_by(QuestionReport.created_at)
        )
    )

    queue = await client.get("/admin/question-report/list")
    page = await client.get(f"/admin/question-report/resolve/{reports[1].id}")
    missing = await client.post(
        f"/admin/question-report/resolve/{reports[1].id}", data={}, headers=ORIGIN
    )
    response = await client.post(
        f"/admin/question-report/resolve/{reports[1].id}",
        data={"resolution": "rejected", "note": "Checked against NCERT."},
        headers=ORIGIN,
    )
    again = await client.post(
        f"/admin/question-report/resolve/{reports[0].id}",
        data={"resolution": "fixed"},
        headers=ORIGIN,
    )

    assert queue.status_code == 200
    assert queue.text.count(">Review</a>") == 3
    assert page.status_code == 200
    assert question.stem in page.text
    assert "Close 2 report(s)" in page.text
    assert missing.status_code == 400
    assert response.status_code == 302
    assert again.status_code == 400
    assert "already closed" in again.text
    for report in reports:
        await db_session.refresh(report)
        assert (report.status, report.resolution) == ("dismissed", "rejected")
        assert report.resolution_note == "Checked against NCERT."
        assert report.resolved_by == admin_id
    still_open = await db_session.scalar(
        select(QuestionReport.status).where(QuestionReport.question_id == other.id)
    )
    assert still_open == "open"
    assert {event.user_id for event in resolved_events} == {r.user_id for r in reports}
    assert {event.resolution for event in resolved_events} == {ReportResolution.REJECTED}
    assert resolved_events[0].question_ref == question_ref(question.id)
    entries = await audit_rows(db_session, action="question_report.resolved")
    assert {entry.entity_id for entry in entries} == {str(r.id) for r in reports}
    assert all(entry.before["status"] == "open" for entry in entries)
    queue_after = await client.get("/admin/question-report/list")
    assert queue_after.text.count(">Review</a>") == 1


async def test_retiring_a_reported_question(
    admin: tuple[AsyncClient, uuid.UUID],
    db_session: AsyncSession,
    resolved_events: list[ReportResolved],
) -> None:
    client, _ = admin
    question = await _question(db_session, "phy-kin-007")
    await _report(client, "asha", question, "wrong_answer")
    report_id = await db_session.scalar(
        select(QuestionReport.id).where(QuestionReport.question_id == question.id)
    )
    version = await db_session.scalar(
        select(AppConfig.value).where(AppConfig.key == "content_version")
    )

    response = await client.post(
        f"/admin/question-report/resolve/{report_id}",
        data={"resolution": "retired"},
        headers=ORIGIN,
    )

    assert response.status_code == 302
    await db_session.refresh(question)
    assert question.status == "retired"
    [event] = resolved_events
    assert event.resolution is ReportResolution.RETIRED
    notice = report_outcome_notice(event)
    assert notice.key == f"question_report:{report_id}"
    assert "removed" in notice.title
    [retired] = await audit_rows(db_session, action="question.retired")
    assert retired.after["status"] == "retired"
    db_session.expire_all()
    new_version = await db_session.scalar(
        select(AppConfig.value).where(AppConfig.key == "content_version")
    )
    assert new_version["version"] != version["version"]
    assert new_version["hash"] == version["hash"]


async def test_a_failing_hook_rolls_the_resolution_back(
    admin: tuple[AsyncClient, uuid.UUID], db_session: AsyncSession
) -> None:
    client, _ = admin
    question = await _question(db_session, "phy-kin-008")
    await _report(client, "asha", question, "typo")
    report_id = await db_session.scalar(
        select(QuestionReport.id).where(QuestionReport.question_id == question.id)
    )

    async def broken(db: AsyncSession, event: ReportResolved) -> None:
        raise RuntimeError("inbox down")

    on_report_resolved.register(broken)
    try:
        # The panel answers 500; the in-process transport re-raises the error.
        with pytest.raises(RuntimeError, match="inbox down"):
            await client.post(
                f"/admin/question-report/resolve/{report_id}",
                data={"resolution": "fixed"},
                headers=ORIGIN,
            )
    finally:
        on_report_resolved.unregister(broken)

    db_session.expire_all()
    status = await db_session.scalar(
        select(QuestionReport.status).where(QuestionReport.id == report_id)
    )
    assert status == "open"


# --- App config, words, read-only views ------------------------------------------------------


async def test_app_config_values_are_validated_and_audited(
    admin: tuple[AsyncClient, uuid.UUID], db_session: AsyncSession
) -> None:
    client, _ = admin

    bad_json = await client.post(
        "/admin/app-config/create", data={"key": "min_build", "value": "{"}, headers=ORIGIN
    )
    bad_value = await client.post(
        "/admin/app-config/create", data={"key": "min_build", "value": "-3"}, headers=ORIGIN
    )
    created = await client.post(
        "/admin/app-config/create",
        data={"key": "min_build", "value": "42", "save": "Save"},
        headers=ORIGIN,
    )
    edited = await client.post(
        "/admin/app-config/edit/min_build",
        data={"key": "min_build", "value": "43", "save": "Save"},
        headers=ORIGIN,
    )
    config = await client.get("/v1/config")
    maintenance = await client.post(
        "/admin/app-config/create",
        data={"key": "maintenance", "value": "true", "save": "Save"},
        headers=ORIGIN,
    )
    deleted = await client.delete("/admin/app-config/delete?pks=maintenance", headers=ORIGIN)

    assert bad_json.status_code == 400
    assert "Not valid JSON" in bad_json.text
    assert bad_value.status_code == 400
    assert "min_build" in bad_value.text
    assert created.status_code == edited.status_code == maintenance.status_code == 302
    assert config.json()["min_build"] == 43
    assert deleted.status_code == 200
    assert await db_session.get(AppConfig, "maintenance") is None
    actions = [entry.action for entry in await audit_rows(db_session, entity_type="app_config")]
    assert actions == [
        "app_config.created",
        "app_config.updated",
        "app_config.created",
        "app_config.deleted",
    ]
    [update] = await audit_rows(db_session, action="app_config.updated")
    assert (update.before["value"], update.after["value"]) == (42, 43)


async def test_words_can_be_added_and_edited(
    admin: tuple[AsyncClient, uuid.UUID], db_session: AsyncSession
) -> None:
    client, _ = admin
    question = await _question(db_session, "phy-kin-001")

    created = await client.post(
        "/admin/word-puzzle/create",
        data={
            "external_id": "phy-word-900",
            "subject_id": str(question.subject_id),
            "word": "vector",
            "clue": "A quantity with both size and direction.",
            "difficulty": "2",
            "status": "published",
            "save": "Save",
        },
        headers=ORIGIN,
    )
    duplicate = await client.post(
        "/admin/word-puzzle/create",
        data={
            "external_id": "phy-word-900",
            "subject_id": str(question.subject_id),
            "word": "SCALAR",
            "clue": "A quantity with size only.",
            "difficulty": "2",
            "status": "published",
        },
        headers=ORIGIN,
    )

    assert created.status_code == 302, created.text
    assert duplicate.status_code == 400
    word = await db_session.scalar(
        select(WordPuzzle).where(WordPuzzle.external_id == "phy-word-900")
    )
    assert word is not None
    assert (word.word, word.source) == ("VECTOR", "import")
    [entry] = await audit_rows(db_session, action="word_puzzle.created")
    assert entry.after["word"] == "VECTOR"


@pytest.mark.parametrize(
    "path",
    [
        "/admin/audit-log/list",
        "/admin/subject/list",
        "/admin/chapter/list",
        "/admin/topic/list",
        "/admin/exam-goal/list",
        "/admin/passage/list",
        "/admin/word-puzzle/list",
        "/admin/app-config/list",
        "/admin/import-questions",
    ],
)
async def test_every_page_opens(admin: tuple[AsyncClient, uuid.UUID], path: str) -> None:
    client, _ = admin

    response = await client.get(path)

    assert response.status_code == 200, response.text


async def test_the_audit_log_and_catalog_are_read_only(
    admin: tuple[AsyncClient, uuid.UUID], db_session: AsyncSession
) -> None:
    client, admin_id = admin
    [entry] = await audit_rows(db_session, action="admin.signed_in")

    edit = await client.get(f"/admin/audit-log/edit/{entry.id}")
    delete = await client.delete(f"/admin/audit-log/delete?pks={entry.id}", headers=ORIGIN)
    create = await client.get("/admin/subject/create")
    details = await client.get(f"/admin/audit-log/details/{entry.id}")

    assert edit.status_code == delete.status_code == create.status_code == 403
    assert details.status_code == 200
    assert str(admin_id) in details.text


# --- The import page --------------------------------------------------------------------------


async def test_the_upload_page_checks_then_imports(
    admin: tuple[AsyncClient, uuid.UUID], db_session: AsyncSession
) -> None:
    client, admin_id = admin
    data = to_json(GOOD, {**GOOD, "options": ["1 m", "1 m", "2 m", "3 m"], "stem": "Bad row?"})

    dry = await client.post(
        "/admin/import-questions",
        files={"file": ("bank.json", data, "application/json")},
        data={"dry_run": "on", "status": "review"},
        headers=ORIGIN,
    )
    blocked = await client.post(
        "/admin/import-questions",
        files={"file": ("bank.json", data, "application/json")},
        data={"status": "published"},
        headers=ORIGIN,
    )
    done = await client.post(
        "/admin/import-questions",
        files={"file": ("bank.json", data, "application/json")},
        data={"status": "published", "skip_invalid": "on"},
        headers=ORIGIN,
    )
    no_file = await client.post("/admin/import-questions", data={}, headers=ORIGIN)
    cross_site = await client.post(
        "/admin/import-questions", files={"file": ("bank.json", data, "application/json")}
    )

    assert dry.status_code == 200
    assert "Dry run, nothing written. 2 rows: ok 1, error 1" in dry.text
    assert "options must all be different" in dry.text
    assert "Nothing imported" in blocked.text
    assert "Imported 1 questions." in done.text
    assert no_file.status_code == 400
    assert cross_site.status_code == 403
    question = await db_session.scalar(select(Question).where(Question.source == "import"))
    assert question is not None
    assert question.status == "published"
    [audit] = await audit_rows(db_session, action="questions.imported")
    assert audit.actor_id == admin_id
    assert audit.after["file"] == "bank.json"
