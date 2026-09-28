"""Changing questions outside the seed: admin edits, and the helpers the importer shares.

Published questions are immutable. Editing one adds a new row with the same ``external_id``
that points back through ``supersedes_id``, gets the subject's next ``seq``, and retires the old
row, so past answers keep pointing at exactly what was asked. Only two things change on a
published row in place, because neither changes what a student is asked: retiring it, and its
``battle_pool`` (reserving it for battles or taking it out of them).

Rows from ``content/`` (``source = 'content'``) keep their source when an admin edits them; the
files stay their source of truth, so a correction must also be made there or the next seed run
restores the file's version.
"""

import hashlib
import json
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from datetime import datetime
from typing import Any

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.modules.content.catalog import CONTENT_VERSION_KEY
from app.modules.content.markup import plain_text
from app.modules.content.models import (
    BattlePool,
    Category,
    Chapter,
    ContentStatus,
    ExamGoal,
    GoalSubject,
    Passage,
    Question,
    QuestionKind,
    Topic,
)
from app.modules.content.rules import question_problems
from app.modules.system.models import AppConfig

# pg_advisory_xact_lock key shared with the seed: seeds, imports and edits never interleave, so
# the per-subject ``seq`` can be handed out as max + 1.
CONTENT_LOCK = 0x5EED_C0DE

# Fields an edit may change; everything else (subject, kind, external id...) is fixed.
EDITABLE_FIELDS = (
    "chapter_id",
    "topic_id",
    "category",
    "exams",
    "difficulty",
    "battle_pool",
    "status",
    "stem",
    "options",
    "answer",
    "explanation",
    "tags",
)
# Changes allowed on a published row without making a new version.
_IN_PLACE_ON_PUBLISHED = frozenset({"status", "battle_pool"})


class InvalidEdit(ValueError):
    """The edit breaks a content rule; ``problems`` lists each one."""

    def __init__(self, problems: Sequence[str]) -> None:
        super().__init__("; ".join(problems))
        self.problems = list(problems)


def content_hash(stem: str, options: Sequence[str], answer: int) -> str:
    """SHA-256 of what the student is asked, as the seed computes it (``QuestionSpec``)."""
    canonical = json.dumps(
        {"stem": stem, "options": list(options), "answer": answer},
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    )
    return hashlib.sha256(canonical.encode()).hexdigest()


def search_text(
    stem: str,
    options: Sequence[str],
    tags: Sequence[str],
    *,
    topic_name: str | None,
    chapter: Chapter | None,
    passage_title: str | None = None,
) -> str:
    """The searchable text, built the same way as the seed builds it."""
    parts = [stem, *options, *(tag.replace("-", " ") for tag in tags)]
    if topic_name:
        parts.append(topic_name)
    if chapter is not None:
        parts += [chapter.name, chapter.slug.replace("-", " ")]
    if passage_title:
        parts.append(passage_title)
    return plain_text(" ".join(parts))


def question_snapshot(question: Question) -> dict[str, Any]:
    """The row as JSON for the audit log."""
    return {
        "id": str(question.id),
        "external_id": question.external_id,
        "subject_id": question.subject_id,
        "chapter_id": question.chapter_id,
        "topic_id": question.topic_id,
        "passage_id": str(question.passage_id) if question.passage_id else None,
        "kind": question.kind,
        "category": question.category,
        "exams": list(question.exams) if question.exams is not None else None,
        "difficulty": question.difficulty,
        "battle_pool": question.battle_pool,
        "status": question.status,
        "stem": question.stem,
        "options": list(question.options),
        "answer": question.answer,
        "explanation": question.explanation,
        "tags": list(question.tags),
        "content_hash": question.content_hash,
        "supersedes_id": str(question.supersedes_id) if question.supersedes_id else None,
        "seq": question.seq,
        "source": question.source,
    }


async def lock_content(db: AsyncSession) -> None:
    """Hold the content lock until the transaction ends."""
    await db.execute(select(func.pg_advisory_xact_lock(CONTENT_LOCK)))


async def next_seqs(db: AsyncSession, subject_ids: Sequence[int]) -> dict[int, int]:
    """The last ``seq`` used per subject (0 for none); hold ``lock_content`` while using it."""
    rows = await db.execute(
        select(Question.subject_id, func.max(Question.seq))
        .where(Question.subject_id.in_(list(subject_ids)))
        .group_by(Question.subject_id)
    )
    last = dict.fromkeys(subject_ids, 0)
    last.update(dict(rows.all()))
    return last


async def subject_exams(db: AsyncSession, subject_id: int) -> set[str]:
    """The exams that include the subject."""
    rows = await db.scalars(
        select(ExamGoal.slug)
        .join(GoalSubject, GoalSubject.goal_id == ExamGoal.id)
        .where(GoalSubject.subject_id == subject_id)
    )
    return set(rows)


@dataclass(frozen=True, slots=True)
class Revision:
    """The outcome of an edit: the live row, and the row it replaced if a new version was made."""

    question: Question
    superseded: Question | None
    before: dict[str, Any]

    @property
    def changed(self) -> bool:
        return self.superseded is not None or self.before != question_snapshot(self.question)


async def revise_question(
    db: AsyncSession, question: Question, changes: Mapping[str, Any], *, now: datetime
) -> Revision:
    """Apply ``changes`` (a subset of ``EDITABLE_FIELDS``) to ``question``.

    A published question becomes a new version unless only its status or battle pool changed.
    Raises ``InvalidEdit`` if the result breaks a content rule. The caller commits and writes
    the audit log (``Revision.before`` and the new row's snapshot).
    """
    unknown = set(changes) - set(EDITABLE_FIELDS)
    if unknown:
        raise InvalidEdit([f"{name} can't be changed" for name in sorted(unknown)])
    before = question_snapshot(question)
    if question.status == ContentStatus.RETIRED:
        raise InvalidEdit(["retired questions are history and can't be edited"])
    values = {name: before_value(question, name) for name in EDITABLE_FIELDS}
    values.update({name: _normalized(name, value) for name, value in changes.items()})
    changed = {name for name in EDITABLE_FIELDS if values[name] != before_value(question, name)}
    if not changed:
        return Revision(question, None, before)
    await _check(db, question, values)

    placement = await _placement(db, question, values)
    derived = {
        "content_hash": content_hash(values["stem"], values["options"], values["answer"]),
        "search_text": search_text(
            values["stem"],
            values["options"],
            values["tags"],
            topic_name=placement.topic.name if placement.topic else None,
            chapter=placement.chapter,
            passage_title=placement.passage_title,
        ),
    }
    if question.status != ContentStatus.PUBLISHED or changed <= _IN_PLACE_ON_PUBLISHED:
        for name in changed:
            setattr(question, name, values[name])
        for name, value in derived.items():
            setattr(question, name, value)
        question.updated_at = now
        await db.flush()
        return Revision(question, None, before)

    # A new version: retire this one first (external_id is unique among live rows).
    await lock_content(db)
    question.status = ContentStatus.RETIRED.value
    question.updated_at = now
    await db.flush()
    seq = (await next_seqs(db, [question.subject_id]))[question.subject_id] + 1
    successor = Question(
        external_id=question.external_id,
        subject_id=question.subject_id,
        passage_id=question.passage_id,
        kind=question.kind,
        source=question.source,
        supersedes_id=question.id,
        seq=seq,
        **{name: values[name] for name in EDITABLE_FIELDS},
        **derived,
    )
    db.add(successor)
    await db.flush()
    return Revision(successor, question, before)


def before_value(question: Question, name: str) -> Any:
    value = getattr(question, name)
    if name in ("options", "tags"):
        return list(value)
    if name == "exams":
        return list(value) if value is not None else None
    return value


def _normalized(name: str, value: Any) -> Any:
    if name in ("options", "tags"):
        return [str(item) for item in value]
    if name == "exams":
        return [str(item) for item in value] if value else None
    if name in ("stem", "explanation") and isinstance(value, str):
        return value.strip()
    return value


@dataclass(frozen=True, slots=True)
class _Placement:
    chapter: Chapter | None
    topic: Topic | None
    passage_title: str | None


async def _placement(db: AsyncSession, question: Question, values: Mapping[str, Any]) -> _Placement:
    chapter = await db.get(Chapter, values["chapter_id"]) if values["chapter_id"] else None
    topic = await db.get(Topic, values["topic_id"]) if values["topic_id"] else None
    passage = await db.get(Passage, question.passage_id) if question.passage_id else None
    return _Placement(chapter, topic, passage.title if passage else None)


async def _check(db: AsyncSession, question: Question, values: Mapping[str, Any]) -> None:
    problems = question_problems(
        stem=values["stem"],
        options=values["options"],
        answer=values["answer"],
        explanation=values["explanation"],
        difficulty=values["difficulty"],
        battle=values["battle_pool"] != BattlePool.NONE,
        exams=values["exams"],
        subject_exams=await subject_exams(db, question.subject_id),
    )
    if values["category"] not in {category.value for category in Category}:
        problems.append("category must be concept, numerical, factual or application")
    if values["battle_pool"] not in {pool.value for pool in BattlePool}:
        problems.append("battle_pool must be none, shared or reserved")
    if values["status"] not in {status.value for status in ContentStatus}:
        problems.append("status must be draft, review, published or retired")
    if question.kind == QuestionKind.MCQ_SINGLE:
        problems.extend(await _placement_problems(db, question.subject_id, values))
    elif values["chapter_id"] != question.chapter_id or values["topic_id"] != question.topic_id:
        problems.append("a passage question's chapter and topic come from its passage")
    if problems:
        raise InvalidEdit(problems)


async def _placement_problems(
    db: AsyncSession, subject_id: int, values: Mapping[str, Any]
) -> list[str]:
    chapter = await db.get(Chapter, values["chapter_id"]) if values["chapter_id"] else None
    if chapter is None or chapter.subject_id != subject_id:
        return ["choose a chapter of the question's subject"]
    topic = await db.get(Topic, values["topic_id"]) if values["topic_id"] else None
    if topic is None or topic.chapter_id != chapter.id:
        return ["choose a topic of the question's chapter"]
    if not chapter.is_active or not topic.is_active:
        return ["the chapter or topic is no longer in use"]
    return []


async def bump_content_version(db: AsyncSession, *, now: datetime) -> None:
    """Change the content version (the catalog ETag) after the bank changed outside the seed.

    The stored file hash is kept, so the next seed run only changes the version again if the
    files changed.
    """
    row = await db.get(AppConfig, CONTENT_VERSION_KEY, with_for_update=True)
    stored = row.value if row is not None and isinstance(row.value, dict) else {}
    version = hashlib.sha256(f"{stored.get('version')}:{now.isoformat()}".encode()).hexdigest()
    value = {**stored, "version": version[:12], "updated_at": now.isoformat()}
    if row is None:
        db.add(AppConfig(key=CONTENT_VERSION_KEY, value=value))
    else:
        row.value = value
