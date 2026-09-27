"""Loading the question bank: validation, idempotency and new versions of changed questions."""

import shutil
from collections.abc import Callable
from pathlib import Path
from typing import Any

import pytest
import yaml
from sqlalchemy import func, select, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.clock import utc_now
from app.core.config import Settings
from app.modules.content import seed as seed_module
from app.modules.content.catalog import content_version
from app.modules.content.loader import ContentProblems, load_content
from app.modules.content.markup import plain_text
from app.modules.content.models import (
    BattlePool,
    Chapter,
    ContentStatus,
    Passage,
    Question,
    QuestionKind,
    Topic,
    WordPuzzle,
)
from app.modules.content.seed import main, seed_content
from tests.helpers import CONTENT_DIR


@pytest.fixture
def content(tmp_path: Path) -> Path:
    """A private copy of the repository's content, to edit."""
    root = tmp_path / "content"
    shutil.copytree(CONTENT_DIR, root, ignore=shutil.ignore_patterns("__pycache__"))
    return root


def edit_chapter(root: Path, subject: str, chapter: str, change: Callable[[Any], None]) -> None:
    path = root / "questions" / subject / f"{chapter}.yaml"
    data = yaml.safe_load(path.read_text(encoding="utf-8"))
    change(data)
    path.write_text(yaml.safe_dump(data, allow_unicode=True, sort_keys=False), encoding="utf-8")


async def live_question(db: AsyncSession, external_id: str) -> Question:
    return await db.scalar(
        select(Question).where(
            Question.external_id == external_id, Question.status != ContentStatus.RETIRED.value
        )
    )


async def seed(db: AsyncSession, root: Path) -> seed_module.SeedReport:
    return await seed_content(db, load_content(root), now=utc_now())


async def test_the_database_holds_the_repository_content(db_session: AsyncSession) -> None:
    counts = dict(
        (
            await db_session.execute(
                select(Question.kind, func.count())
                .where(Question.status == ContentStatus.PUBLISHED.value)
                .group_by(Question.kind)
            )
        ).all()
    )

    assert counts == {QuestionKind.MCQ_SINGLE: 64, QuestionKind.PASSAGE_MCQ: 12}
    assert await db_session.scalar(select(func.count()).select_from(Chapter)) == 8
    assert await db_session.scalar(select(func.count()).select_from(Topic)) == 16
    assert await db_session.scalar(select(func.count()).select_from(Passage)) == 4
    assert await db_session.scalar(select(func.count()).select_from(WordPuzzle)) == 20
    question = await live_question(db_session, "phy-kin-001")
    assert question.battle_pool == BattlePool.SHARED
    assert question.options[question.answer] == "Zero"
    assert "Motion in a Straight Line" in question.search_text
    assert "kinematics" in question.search_text


async def test_a_second_run_changes_nothing(db_session: AsyncSession) -> None:
    version = await content_version(db_session)

    report = await seed(db_session, CONTENT_DIR)

    assert not report.changed
    assert report.summary() == f"Content is up to date (version {version}); nothing changed."
    assert await content_version(db_session) == version


async def test_a_changed_question_becomes_a_new_version(
    db_session: AsyncSession, content: Path
) -> None:
    old = await live_question(db_session, "phy-kin-001")
    version = await content_version(db_session)

    def reword(data: Any) -> None:
        data["questions"][0]["stem"] = (
            "A runner completes one full lap and stops at the start. Displacement?"
        )

    edit_chapter(content, "physics", "kinematics", reword)
    report = await seed(db_session, content)

    assert report.superseded == 1
    assert (report.inserted, report.retired, report.updated) == ({}, {}, {})
    new = await live_question(db_session, "phy-kin-001")
    assert new.id != old.id
    assert new.supersedes_id == old.id
    assert new.stem.endswith("Displacement?")
    assert (new.topic_id, new.chapter_id, new.category) == (
        old.topic_id,
        old.chapter_id,
        old.category,
    )
    assert new.seq > old.seq
    await db_session.refresh(old)
    assert old.status == ContentStatus.RETIRED
    assert await content_version(db_session) != version
    # And again: the new version is now the one in the files.
    assert not (await seed(db_session, content)).changed


async def test_explanations_and_tags_are_edited_in_place(
    db_session: AsyncSession, content: Path
) -> None:
    old = await live_question(db_session, "phy-kin-002")

    def edit(data: Any) -> None:
        data["questions"][1]["explanation"] = "Average speed is total distance over total time."
        data["questions"][1]["tags"] = ["average-speed"]

    edit_chapter(content, "physics", "kinematics", edit)
    report = await seed(db_session, content)

    assert report.updated == {"questions": 1}
    assert not report.superseded
    question = await live_question(db_session, "phy-kin-002")
    assert question.id == old.id
    assert question.explanation.startswith("Average speed is total")
    assert question.tags == ["average-speed"]
    assert "average speed" in question.search_text


async def test_questions_removed_from_the_files_are_retired(
    db_session: AsyncSession, content: Path
) -> None:
    edit_chapter(content, "physics", "kinematics", lambda data: data["questions"].pop())

    report = await seed(db_session, content)

    assert report.retired == {"questions": 1}
    assert await live_question(db_session, "phy-kin-008") is None


async def test_questions_reserved_for_battles_stay_reserved(
    db_session: AsyncSession, content: Path
) -> None:
    await db_session.execute(
        update(Question)
        .where(Question.external_id == "phy-kin-003")
        .values(battle_pool=BattlePool.RESERVED.value)
    )

    report = await seed(db_session, content)

    assert not report.changed
    assert (await live_question(db_session, "phy-kin-003")).battle_pool == BattlePool.RESERVED


async def test_invalid_content_is_refused_with_every_problem(content: Path) -> None:
    def break_it(data: Any) -> None:
        data["questions"][0]["options"] = ["One", "Two", "Three"]
        data["questions"][1]["answer"] = 7

    edit_chapter(content, "physics", "kinematics", break_it)

    with pytest.raises(ContentProblems) as refused:
        load_content(content)

    problems = " ".join(refused.value.problems)
    assert "expected 4 options" in problems
    assert "answer" in problems


async def test_a_topic_slug_belongs_to_one_chapter_of_a_subject(content: Path) -> None:
    def reuse_slug(data: Any) -> None:
        old = data["chapter"]["topics"][0]["slug"]
        data["chapter"]["topics"][0]["slug"] = "speed-velocity"  # a Kinematics topic
        for question in data["questions"]:
            if question["topic"] == old:
                question["topic"] = "speed-velocity"

    edit_chapter(content, "physics", "laws-of-motion", reuse_slug)

    with pytest.raises(ContentProblems) as refused:
        load_content(content)

    assert refused.value.problems == [
        "questions/physics: topic speed-velocity is used by several chapters "
        "(kinematics, laws-of-motion)"
    ]


def test_a_directory_without_content_is_refused(tmp_path: Path) -> None:
    with pytest.raises(ContentProblems) as refused:
        load_content(tmp_path)

    assert "no catalog.yaml" in refused.value.problems[0]


def test_the_command_reports_problems_and_loads_nothing(
    content: Path, capsys: pytest.CaptureFixture[str]
) -> None:
    edit_chapter(
        content, "physics", "kinematics", lambda data: data["questions"][0].pop("explanation")
    )

    assert main([str(content)]) == 1
    error = capsys.readouterr().err
    assert "was not loaded; fix these problems first" in error
    assert "explanation" in error


def test_the_command_loads_the_content(
    settings: Settings, monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str]
) -> None:
    monkeypatch.setattr(seed_module, "get_settings", lambda: settings)

    assert main([str(CONTENT_DIR)]) == 0
    assert "nothing changed" in capsys.readouterr().out


def test_the_command_takes_one_directory(capsys: pytest.CaptureFixture[str]) -> None:
    assert main(["one", "two"]) == 2
    assert "usage" in capsys.readouterr().err


@pytest.mark.parametrize(
    ("markup", "plain"),
    [
        ("H_2SO_4 in m s^{-2}", "H2SO4 in m s-2"),
        ("x^{n+1} and a_{max}", "xn+1 and amax"),
        ("*Escherichia coli* is **not** a virus", "Escherichia coli is not a virus"),
        ("  spaced\n out  ", "spaced out"),
    ],
)
def test_markup_is_stripped_for_search(markup: str, plain: str) -> None:
    assert plain_text(markup) == plain
