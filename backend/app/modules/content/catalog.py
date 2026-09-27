"""The catalog of one exam: subjects, chapters and topics with question counts.

It is the same for every player of that exam and only changes when content is loaded, so it is
served with an ETag built from the content version the seed records.
"""

import uuid
from collections import defaultdict

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.errors import ValidationFailed
from app.modules.content.models import (
    BattlePool,
    Chapter,
    ContentStatus,
    ExamGoal,
    GoalSubject,
    Question,
    QuestionKind,
    Subject,
    Topic,
)
from app.modules.content.queries import suits_goal
from app.modules.content.schemas import CatalogOut, ChapterOut, SubjectOut, TopicOut
from app.modules.system.models import AppConfig
from app.modules.users.models import User
from app.modules.users.validation import GOAL_MESSAGE

CONTENT_VERSION_KEY = "content_version"  # app_config key written by the seed
DEFAULT_GOAL = "neet"  # for players who haven't picked one yet
# A chapter can host a Quick Battle (7 questions) once it has this many battle questions.
MIN_BATTLE_QUESTIONS = 7


async def content_version(db: AsyncSession) -> str:
    value = await db.scalar(select(AppConfig.value).where(AppConfig.key == CONTENT_VERSION_KEY))
    version = value.get("version") if isinstance(value, dict) else None
    return version if isinstance(version, str) else "none"


async def resolve_goal(db: AsyncSession, user_id: uuid.UUID, requested: str | None) -> str:
    """The exam to show: the one asked for (422 if unknown), else the player's own."""
    if requested is not None:
        if await db.scalar(select(ExamGoal.id).where(ExamGoal.slug == requested)) is None:
            raise ValidationFailed(details={"fields": {"goal": GOAL_MESSAGE}})
        return requested
    goal = await db.scalar(select(User.goal).where(User.id == user_id))
    return goal or DEFAULT_GOAL


def catalog_etag(version: str, goal: str) -> str:
    return f'"{version}-{goal}"'


def etag_matches(if_none_match: str | None, etag: str) -> bool:
    """Whether an ``If-None-Match`` header covers ``etag`` (weak comparison, as for GET)."""
    if not if_none_match:
        return False
    tags = [tag.strip() for tag in if_none_match.split(",")]
    return "*" in tags or etag in (tag.removeprefix("W/") for tag in tags)


async def goal_subjects(db: AsyncSession, goal: str) -> list[Subject]:
    """The exam's subjects in display order."""
    rows = await db.scalars(
        select(Subject)
        .join(GoalSubject, GoalSubject.subject_id == Subject.id)
        .join(ExamGoal, ExamGoal.id == GoalSubject.goal_id)
        .where(ExamGoal.slug == goal)
        .order_by(Subject.sort, Subject.id)
    )
    return list(rows)


async def build_catalog(db: AsyncSession, goal: str, version: str) -> CatalogOut:
    subjects = await goal_subjects(db, goal)
    subject_ids = [subject.id for subject in subjects]
    chapters = (
        await db.scalars(
            select(Chapter)
            .where(Chapter.subject_id.in_(subject_ids), Chapter.is_active)
            .order_by(Chapter.sort, Chapter.id)
        )
    ).all()
    topics = (
        await db.scalars(
            select(Topic)
            .where(Topic.chapter_id.in_([chapter.id for chapter in chapters]), Topic.is_active)
            .order_by(Topic.sort, Topic.id)
        )
    ).all()
    # Questions this exam's players can get in practice, and the battle pool per chapter.
    counts = await db.execute(
        select(
            Question.topic_id,
            func.count().filter(Question.battle_pool != BattlePool.RESERVED.value),
            func.count().filter(Question.battle_pool != BattlePool.NONE.value),
        )
        .where(
            Question.status == ContentStatus.PUBLISHED.value,
            Question.kind == QuestionKind.MCQ_SINGLE.value,
            suits_goal(goal),
        )
        .group_by(Question.topic_id)
    )
    practice_by_topic: dict[int, int] = {}
    battle_by_topic: dict[int, int] = {}
    for topic_id, practice, battle in counts:
        if topic_id is None:  # chapter questions always have a topic; this is for mypy
            continue
        practice_by_topic[topic_id] = practice
        battle_by_topic[topic_id] = battle

    topics_by_chapter: dict[int, list[Topic]] = defaultdict(list)
    for topic in topics:
        topics_by_chapter[topic.chapter_id].append(topic)
    chapters_by_subject: dict[int, list[ChapterOut]] = defaultdict(list)
    for chapter in chapters:
        chapter_topics = topics_by_chapter[chapter.id]
        chapters_by_subject[chapter.subject_id].append(
            ChapterOut(
                slug=chapter.slug,
                name=chapter.name,
                order=chapter.sort,
                question_count=sum(practice_by_topic.get(t.id, 0) for t in chapter_topics),
                battle_ready=sum(battle_by_topic.get(t.id, 0) for t in chapter_topics)
                >= MIN_BATTLE_QUESTIONS,
                topics=[
                    TopicOut(
                        slug=topic.slug,
                        name=topic.name,
                        question_count=practice_by_topic.get(topic.id, 0),
                    )
                    for topic in chapter_topics
                ],
            )
        )
    return CatalogOut(
        goal=goal,
        version=version,
        subjects=[
            SubjectOut(
                slug=subject.slug,
                name=subject.name,
                tone=subject.tone,
                icon=subject.icon,
                question_count=sum(c.question_count for c in chapters_by_subject[subject.id]),
                chapters=chapters_by_subject[subject.id],
            )
            for subject in subjects
        ],
    )
