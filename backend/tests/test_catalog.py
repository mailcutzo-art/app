"""The catalog, the exam filter and battle-only questions."""

from typing import Any

import pytest
from httpx import AsyncClient
from sqlalchemy import func, select, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.modules.content.catalog import CONTENT_VERSION_KEY, content_version
from app.modules.content.models import BattlePool, Chapter, Question, Topic
from app.modules.content.refs import question_ref
from app.modules.system.models import AppConfig
from tests.learn_helpers import player, start


@pytest.fixture
async def asha(client: AsyncClient) -> dict[str, str]:
    return await player(client, "asha", goal="neet")


@pytest.fixture
async def arjun(client: AsyncClient) -> dict[str, str]:
    return await player(client, "arjun", goal="jee")


async def jee_only_question(db: AsyncSession) -> Question:
    """A Kinematics question that suits JEE only (the repository content has none)."""
    chapter = await db.scalar(select(Chapter).where(Chapter.slug == "kinematics"))
    topic = await db.scalar(
        select(Topic).where(Topic.chapter_id == chapter.id, Topic.slug == "equations-of-motion")
    )
    last_seq = await db.scalar(
        select(func.max(Question.seq)).where(Question.subject_id == chapter.subject_id)
    )
    question = Question(
        external_id="phy-kin-901",
        subject_id=chapter.subject_id,
        chapter_id=chapter.id,
        topic_id=topic.id,
        kind="mcq_single",
        category="numerical",
        exams=["jee"],
        difficulty=3,
        battle_pool="shared",
        status="published",
        stem="A boomerang is thrown up at 20 m/s. When does it return?",
        options=["2 s", "4 s", "6 s", "8 s"],
        answer=1,
        explanation="Time of flight is 2u/g = 4 s.",
        tags=[],
        search_text="A boomerang is thrown up at 20 m/s. When does it return?",
        content_hash="test",
        seq=last_seq + 1,
        source="import",
    )
    db.add(question)
    await db.flush()
    return question


def chapter_of(catalog: dict[str, Any], subject: str, chapter: str) -> dict[str, Any]:
    by_subject = {s["slug"]: s for s in catalog["subjects"]}
    return next(c for c in by_subject[subject]["chapters"] if c["slug"] == chapter)


async def test_the_catalog_of_the_players_exam(
    client: AsyncClient, asha: dict[str, str], db_session: AsyncSession
) -> None:
    response = await client.get("/v1/catalog", headers=asha)

    assert response.status_code == 200
    catalog = response.json()
    assert catalog["goal"] == "neet"
    assert catalog["version"] == await content_version(db_session)
    assert [(s["slug"], s["name"], s["tone"], s["icon"]) for s in catalog["subjects"]] == [
        ("physics", "Physics", "sky", "physics"),
        ("chemistry", "Chemistry", "lavender", "chemistry"),
        ("biology", "Biology", "mint", "biology"),
    ]
    physics = catalog["subjects"][0]
    assert physics["question_count"] == 16  # chapter questions only, not Fun & Learn ones
    assert physics["chapters"][0] == {
        "slug": "kinematics",
        "name": "Motion in a Straight Line",
        "order": 1,
        "question_count": 8,
        "battle_ready": True,
        "topics": [
            {"slug": "speed-velocity", "name": "Speed and velocity", "question_count": 4},
            {"slug": "equations-of-motion", "name": "Equations of motion", "question_count": 4},
        ],
    }


async def test_the_catalog_defaults_to_each_players_exam(
    client: AsyncClient, asha: dict[str, str], arjun: dict[str, str]
) -> None:
    jee = (await client.get("/v1/catalog", headers=arjun)).json()
    other = (await client.get("/v1/catalog?goal=jee", headers=asha)).json()

    assert jee["goal"] == "jee"
    assert [s["slug"] for s in jee["subjects"]] == ["physics", "chemistry", "maths"]
    assert other == jee


async def test_an_unknown_exam_is_a_field_error(client: AsyncClient, asha: dict[str, str]) -> None:
    response = await client.get("/v1/catalog?goal=upsc", headers=asha)

    assert response.status_code == 422
    assert response.json()["error"]["details"] == {"fields": {"goal": "Choose NEET or JEE."}}


async def test_the_catalog_is_revalidated_with_its_etag(
    client: AsyncClient, asha: dict[str, str], db_session: AsyncSession
) -> None:
    first = await client.get("/v1/catalog", headers=asha)
    etag = first.headers["ETag"]
    version = first.json()["version"]

    same = await client.get("/v1/catalog", headers={**asha, "If-None-Match": etag})
    weak = await client.get("/v1/catalog", headers={**asha, "If-None-Match": f'"x", W/{etag}'})
    other_exam = await client.get("/v1/catalog?goal=jee", headers={**asha, "If-None-Match": etag})

    assert etag == f'"{version}-neet"'
    assert first.headers["Cache-Control"] == "private, no-cache"
    assert same.status_code == 304
    assert same.content == b""
    assert same.headers["ETag"] == etag
    assert weak.status_code == 304
    assert other_exam.status_code == 200

    # Loading new content changes the version, so the old ETag no longer matches.
    await db_session.execute(
        update(AppConfig)
        .where(AppConfig.key == CONTENT_VERSION_KEY)
        .values(value={"hash": "h", "version": "0123456789ab"})
    )
    changed = await client.get("/v1/catalog", headers={**asha, "If-None-Match": etag})
    assert changed.status_code == 200
    assert changed.headers["ETag"] == '"0123456789ab-neet"'


async def test_questions_for_one_exam_reach_only_its_players(
    client: AsyncClient,
    asha: dict[str, str],
    arjun: dict[str, str],
    db_session: AsyncSession,
) -> None:
    question = await jee_only_question(db_session)
    ref = question_ref(question.id)

    neet = (await client.get("/v1/catalog", headers=asha)).json()
    jee = (await client.get("/v1/catalog", headers=arjun)).json()
    neet_session = await start(client, asha, count=50)
    jee_session = await start(client, arjun, count=50)
    neet_search = (await client.get("/v1/search?q=boomerang", headers=asha)).json()
    jee_search = (await client.get("/v1/search?q=boomerang", headers=arjun)).json()

    assert chapter_of(neet, "physics", "kinematics")["question_count"] == 8
    assert chapter_of(jee, "physics", "kinematics")["question_count"] == 9
    assert ref not in {q["ref"] for q in neet_session["questions"]}
    assert len(neet_session["questions"]) == 8
    assert ref in {q["ref"] for q in jee_session["questions"]}
    assert neet_search["items"] == []
    assert [item["ref"] for item in jee_search["items"]] == [ref]


async def test_battle_only_questions_never_reach_practice(
    client: AsyncClient, asha: dict[str, str], db_session: AsyncSession
) -> None:
    reserved = list(
        await db_session.scalars(
            select(Question.id)
            .where(Question.external_id.in_(["phy-kin-001", "phy-kin-002"]))
            .order_by(Question.external_id)
        )
    )
    await db_session.execute(
        update(Question)
        .where(Question.id.in_(reserved))
        .values(battle_pool=BattlePool.RESERVED.value)
    )

    catalog = (await client.get("/v1/catalog", headers=asha)).json()
    session = await start(client, asha, count=50)
    look = await client.get(f"/v1/questions/{question_ref(reserved[0])}", headers=asha)
    search = (await client.get("/v1/search?q=runner", headers=asha)).json()

    kinematics = chapter_of(catalog, "physics", "kinematics")
    assert kinematics["question_count"] == 6
    assert kinematics["battle_ready"] is True  # reserved questions still serve battles
    assert {question_ref(q) for q in reserved}.isdisjoint(q["ref"] for q in session["questions"])
    assert look.status_code == 404
    assert search["items"] == []


async def test_a_chapter_needs_seven_battle_questions_for_battles(
    client: AsyncClient, asha: dict[str, str], db_session: AsyncSession
) -> None:
    await db_session.execute(
        update(Question)
        .where(Question.external_id.in_(["phy-kin-001", "phy-kin-002"]))
        .values(battle_pool=BattlePool.NONE.value)
    )

    catalog = (await client.get("/v1/catalog", headers=asha)).json()

    kinematics = chapter_of(catalog, "physics", "kinematics")
    assert kinematics["battle_ready"] is False
    assert kinematics["question_count"] == 8


async def test_learn_needs_a_signed_in_player(client: AsyncClient) -> None:
    for path in ("/v1/catalog", "/v1/me/progress", "/v1/search?q=kine", "/v1/passages"):
        response = await client.get(path)
        assert response.status_code == 401, path
