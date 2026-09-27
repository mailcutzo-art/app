"""Load the question bank from ``content/`` into PostgreSQL.

    python -m app.modules.content.seed [content_dir]

``content_dir`` defaults to ``APP_CONTENT_DIR`` (``../content``, relative to the working
directory). The files are checked with ``content/tools/validate.py`` first; any problem aborts
the run before the database is touched.

Rows are matched by their stable ids (``external_id``, slugs), so running the seed again changes
nothing. A question whose stem, options or answer changed becomes a new row that supersedes the
retired old one (past answers keep pointing at exactly what was asked); other edits
(explanation, tags, difficulty, topic...) update the row in place. Questions, passages and words
that disappear from the files are retired, and chapters and topics are deactivated. Rows that
did not come from the files (``source = 'import'``) are never touched.
"""

import asyncio
import hashlib
import sys
from collections import Counter
from collections.abc import Iterable, Mapping, Sequence
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path

from sqlalchemy import delete, func, select, tuple_
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.clock import utc_now
from app.core.config import Settings, get_settings
from app.core.db import create_engine, create_sessionmaker
from app.modules.content.catalog import CONTENT_VERSION_KEY
from app.modules.content.loader import (
    ChapterSpec,
    ContentBundle,
    ContentProblems,
    QuestionSpec,
    load_content,
)
from app.modules.content.markup import plain_text
from app.modules.content.models import (
    BattlePool,
    Chapter,
    ContentSource,
    ContentStatus,
    ExamGoal,
    GoalSubject,
    Passage,
    Question,
    Subject,
    Topic,
    WordPuzzle,
)
from app.modules.system.models import AppConfig

# pg_advisory_xact_lock key: one seed at a time.
_SEED_LOCK = 0x5EED_C0DE


@dataclass
class SeedReport:
    """What a run changed, per table."""

    inserted: Counter[str] = field(default_factory=Counter)
    updated: Counter[str] = field(default_factory=Counter)
    retired: Counter[str] = field(default_factory=Counter)
    superseded: int = 0
    version: str = ""
    version_changed: bool = False

    @property
    def rows_changed(self) -> bool:
        return bool(self.inserted or self.updated or self.retired or self.superseded)

    @property
    def changed(self) -> bool:
        return self.rows_changed or self.version_changed

    def summary(self) -> str:
        if not self.changed:
            return f"Content is up to date (version {self.version}); nothing changed."
        lines = [f"Content loaded (version {self.version})."]
        for label, counts in (
            ("added", self.inserted),
            ("updated", self.updated),
            ("retired or deactivated", self.retired),
        ):
            if counts:
                parts = ", ".join(f"{table} {n}" for table, n in sorted(counts.items()))
                lines.append(f"  {label}: {parts}")
        if self.superseded:
            lines.append(f"  new versions of changed questions: {self.superseded}")
        return "\n".join(lines)


def _assign(row: object, values: Mapping[str, object]) -> bool:
    """Set the attributes that differ; True if any did."""
    changed = False
    for name, value in values.items():
        if getattr(row, name) != value:
            setattr(row, name, value)
            changed = True
    return changed


async def seed_content(db: AsyncSession, bundle: ContentBundle, *, now: datetime) -> SeedReport:
    """Bring the database in line with ``bundle``. The caller commits."""
    await db.execute(select(func.pg_advisory_xact_lock(_SEED_LOCK)))
    report = SeedReport()
    goals = await _sync_goals(db, bundle, report)
    subjects = await _sync_subjects(db, bundle, report)
    await _sync_goal_subjects(db, bundle, goals, subjects, report)
    chapters = await _sync_chapters(db, bundle, subjects, report)
    topics = await _sync_topics(db, bundle, chapters, report)
    passages = await _sync_passages(db, bundle, subjects, chapters, report)
    await _sync_questions(db, bundle, subjects, chapters, topics, passages, report)
    await _sync_words(db, bundle, subjects, report)
    await _store_version(db, bundle, report, now=now)
    await db.flush()
    return report


async def _sync_goals(
    db: AsyncSession, bundle: ContentBundle, report: SeedReport
) -> dict[str, ExamGoal]:
    rows = {row.slug: row for row in await db.scalars(select(ExamGoal))}
    for spec in bundle.goals:
        row = rows.get(spec.slug)
        if row is None:
            rows[spec.slug] = row = ExamGoal(slug=spec.slug, name=spec.name)
            db.add(row)
            report.inserted["goals"] += 1
        elif _assign(row, {"name": spec.name}):
            report.updated["goals"] += 1
    await db.flush()
    return rows


async def _sync_subjects(
    db: AsyncSession, bundle: ContentBundle, report: SeedReport
) -> dict[str, Subject]:
    rows = {row.slug: row for row in await db.scalars(select(Subject))}
    for sort, spec in enumerate(bundle.subjects, start=1):
        values = {"name": spec.name, "tone": spec.tone, "icon": spec.icon, "sort": sort}
        row = rows.get(spec.slug)
        if row is None:
            rows[spec.slug] = row = Subject(slug=spec.slug, **values)
            db.add(row)
            report.inserted["subjects"] += 1
        elif _assign(row, values):
            report.updated["subjects"] += 1
    await db.flush()
    return rows


async def _sync_goal_subjects(
    db: AsyncSession,
    bundle: ContentBundle,
    goals: Mapping[str, ExamGoal],
    subjects: Mapping[str, Subject],
    report: SeedReport,
) -> None:
    pairs = await db.execute(select(GoalSubject.goal_id, GoalSubject.subject_id))
    existing = {(goal_id, subject_id) for goal_id, subject_id in pairs}
    wanted = {
        (goals[goal.slug].id, subjects[subject].id)
        for goal in bundle.goals
        for subject in goal.subjects
    }
    for goal_id, subject_id in sorted(wanted - existing):
        db.add(GoalSubject(goal_id=goal_id, subject_id=subject_id))
        report.inserted["goal_subjects"] += 1
    if stale := existing - wanted:
        await db.execute(
            delete(GoalSubject).where(
                tuple_(GoalSubject.goal_id, GoalSubject.subject_id).in_(sorted(stale))
            )
        )
        report.retired["goal_subjects"] += len(stale)
    await db.flush()


async def _sync_chapters(
    db: AsyncSession,
    bundle: ContentBundle,
    subjects: Mapping[str, Subject],
    report: SeedReport,
) -> dict[tuple[str, str], Chapter]:
    """Chapters by (subject slug, chapter slug)."""
    rows = {(row.subject_id, row.slug): row for row in await db.scalars(select(Chapter))}
    chapters: dict[tuple[str, str], Chapter] = {}
    for spec in bundle.chapters:
        subject_id = subjects[spec.subject].id
        values = {"name": spec.name, "sort": spec.order, "is_active": True}
        row = rows.pop((subject_id, spec.slug), None)
        if row is None:
            row = Chapter(subject_id=subject_id, slug=spec.slug, **values)
            db.add(row)
            report.inserted["chapters"] += 1
        elif _assign(row, values):
            report.updated["chapters"] += 1
        chapters[spec.subject, spec.slug] = row
    for row in rows.values():
        if row.is_active:
            row.is_active = False
            report.retired["chapters"] += 1
    await db.flush()
    return chapters


async def _sync_topics(
    db: AsyncSession,
    bundle: ContentBundle,
    chapters: Mapping[tuple[str, str], Chapter],
    report: SeedReport,
) -> dict[tuple[str, str], Topic]:
    """Topics by (subject slug, topic slug); the loader checks those are unique."""
    rows = {(row.chapter_id, row.slug): row for row in await db.scalars(select(Topic))}
    topics: dict[tuple[str, str], Topic] = {}
    for spec in bundle.chapters:
        chapter_id = chapters[spec.subject, spec.slug].id
        for sort, topic in enumerate(spec.topics, start=1):
            values = {"name": topic.name, "sort": sort, "is_active": True}
            row = rows.pop((chapter_id, topic.slug), None)
            if row is None:
                row = Topic(chapter_id=chapter_id, slug=topic.slug, **values)
                db.add(row)
                report.inserted["topics"] += 1
            elif _assign(row, values):
                report.updated["topics"] += 1
            topics[spec.subject, topic.slug] = row
    for row in rows.values():
        if row.is_active:
            row.is_active = False
            report.retired["topics"] += 1
    await db.flush()
    return topics


async def _sync_passages(
    db: AsyncSession,
    bundle: ContentBundle,
    subjects: Mapping[str, Subject],
    chapters: Mapping[tuple[str, str], Chapter],
    report: SeedReport,
) -> dict[str, Passage]:
    rows = {row.external_id: row for row in await db.scalars(select(Passage))}
    passages: dict[str, Passage] = {}
    for spec in bundle.passages:
        chapter = chapters[spec.subject, spec.chapter] if spec.chapter else None
        values = {
            "subject_id": subjects[spec.subject].id,
            "chapter_id": chapter.id if chapter else None,
            "title": spec.title,
            "body": spec.body,
            "difficulty": spec.difficulty,
            "status": ContentStatus.PUBLISHED.value,
            "source": ContentSource.CONTENT.value,
        }
        row = rows.pop(spec.external_id, None)
        if row is None:
            row = Passage(external_id=spec.external_id, **values)
            db.add(row)
            report.inserted["passages"] += 1
        elif _assign(row, values):
            report.updated["passages"] += 1
        passages[spec.external_id] = row
    _retire_missing(rows.values(), "passages", report)
    await db.flush()
    return passages


async def _sync_questions(
    db: AsyncSession,
    bundle: ContentBundle,
    subjects: Mapping[str, Subject],
    chapters: Mapping[tuple[str, str], Chapter],
    topics: Mapping[tuple[str, str], Topic],
    passages: Mapping[str, Passage],
    report: SeedReport,
) -> None:
    live = {
        row.external_id: row
        for row in await db.scalars(
            select(Question).where(Question.status != ContentStatus.RETIRED.value)
        )
    }
    max_seqs = await db.execute(
        select(Question.subject_id, func.max(Question.seq)).group_by(Question.subject_id)
    )
    last_seq: dict[int, int] = dict(max_seqs.all())
    chapter_specs = {(spec.subject, spec.slug): spec for spec in bundle.chapters}
    passage_titles = {spec.external_id: spec.title for spec in bundle.passages}

    for spec in bundle.questions:
        subject_id = subjects[spec.subject].id
        chapter = chapters[spec.subject, spec.chapter] if spec.chapter else None
        topic = topics[spec.subject, spec.topic] if spec.topic else None
        passage = passages[spec.passage] if spec.passage else None
        current = live.pop(spec.external_id, None)
        values = {
            "subject_id": subject_id,
            "chapter_id": chapter.id if chapter else None,
            "topic_id": topic.id if topic else None,
            "passage_id": passage.id if passage else None,
            "kind": spec.kind.value,
            "category": spec.category,
            "exams": list(spec.exams) if spec.exams is not None else None,
            "difficulty": spec.difficulty,
            "battle_pool": _battle_pool(spec, current),
            "explanation": spec.explanation,
            "tags": list(spec.tags),
            "search_text": _search_text(
                spec,
                chapter_specs.get((spec.subject, spec.chapter or "")),
                topic.name if topic else None,
                passage_titles.get(spec.passage or ""),
            ),
            "status": ContentStatus.PUBLISHED.value,
            "source": ContentSource.CONTENT.value,
        }
        if current is not None and current.content_hash == spec.content_hash:
            if _assign(current, values):
                report.updated["questions"] += 1
            continue
        if current is not None:
            # Published questions are never edited: retire this version, add the new one.
            current.status = ContentStatus.RETIRED.value
            await db.flush()  # before the insert: external_id is unique among live rows
            report.superseded += 1
        else:
            report.inserted["questions"] += 1
        last_seq[subject_id] = last_seq.get(subject_id, 0) + 1
        db.add(
            Question(
                external_id=spec.external_id,
                stem=spec.stem,
                options=list(spec.options),
                answer=spec.answer,
                content_hash=spec.content_hash,
                supersedes_id=current.id if current else None,
                seq=last_seq[subject_id],
                **values,
            )
        )
    _retire_missing(live.values(), "questions", report)
    await db.flush()


def _battle_pool(spec: QuestionSpec, current: Question | None) -> str:
    """``battle: true`` means shared with practice, unless an admin reserved it for battles."""
    if not spec.battle:
        return BattlePool.NONE.value
    if current is not None and current.battle_pool == BattlePool.RESERVED:
        return BattlePool.RESERVED.value
    return BattlePool.SHARED.value


def _search_text(
    spec: QuestionSpec,
    chapter: ChapterSpec | None,
    topic_name: str | None,
    passage_title: str | None,
) -> str:
    parts = [spec.stem, *spec.options, *(tag.replace("-", " ") for tag in spec.tags)]
    if topic_name:
        parts.append(topic_name)
    if chapter:
        parts += [chapter.name, chapter.slug.replace("-", " ")]
    if passage_title:
        parts.append(passage_title)
    return plain_text(" ".join(parts))


async def _sync_words(
    db: AsyncSession,
    bundle: ContentBundle,
    subjects: Mapping[str, Subject],
    report: SeedReport,
) -> None:
    rows = {row.external_id: row for row in await db.scalars(select(WordPuzzle))}
    for spec in bundle.words:
        values = {
            "subject_id": subjects[spec.subject].id,
            "word": spec.word,
            "clue": spec.clue,
            "difficulty": spec.difficulty,
            "status": ContentStatus.PUBLISHED.value,
            "source": ContentSource.CONTENT.value,
        }
        row = rows.pop(spec.external_id, None)
        if row is None:
            db.add(WordPuzzle(external_id=spec.external_id, **values))
            report.inserted["word_puzzles"] += 1
        elif _assign(row, values):
            report.updated["word_puzzles"] += 1
    _retire_missing(rows.values(), "word_puzzles", report)
    await db.flush()


def _retire_missing(
    rows: Iterable[Passage | Question | WordPuzzle], table: str, report: SeedReport
) -> None:
    for row in rows:
        if row.source == ContentSource.CONTENT and row.status != ContentStatus.RETIRED:
            row.status = ContentStatus.RETIRED.value
            report.retired[table] += 1


async def _store_version(
    db: AsyncSession, bundle: ContentBundle, report: SeedReport, *, now: datetime
) -> None:
    """Record the content version; the catalog ETag changes whenever the seed changed data."""
    row = await db.get(AppConfig, CONTENT_VERSION_KEY)
    stored = row.value if row is not None else None
    if (
        isinstance(stored, dict)
        and stored.get("hash") == bundle.version
        and isinstance(stored.get("version"), str)
        and not report.rows_changed
    ):
        report.version = stored["version"]
        return
    version = hashlib.sha256(f"{bundle.version}:{now.isoformat()}".encode()).hexdigest()[:12]
    value = {"hash": bundle.version, "version": version, "updated_at": now.isoformat()}
    if row is None:
        db.add(AppConfig(key=CONTENT_VERSION_KEY, value=value))
    else:
        row.value = value
    report.version = version
    report.version_changed = True


async def _run(settings: Settings, bundle: ContentBundle) -> SeedReport:
    engine = create_engine(settings, application_name="quiz-seed")
    try:
        async with create_sessionmaker(engine)() as db:
            report = await seed_content(db, bundle, now=utc_now())
            await db.commit()
            return report
    finally:
        await engine.dispose()


def main(argv: Sequence[str] | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    if len(args) > 1 or (args and args[0].startswith("-")):
        print("usage: python -m app.modules.content.seed [content_dir]", file=sys.stderr)
        return 2
    settings = get_settings()
    root = Path(args[0] if args else settings.content_dir).resolve()
    try:
        bundle = load_content(root)
    except ContentProblems as exc:
        print(f"Content in {root} was not loaded; fix these problems first:", file=sys.stderr)
        for problem in exc.problems:
            print(f"  - {problem}", file=sys.stderr)
        return 1
    report = asyncio.run(_run(settings, bundle))
    print(report.summary())
    return 0


if __name__ == "__main__":
    sys.exit(main())
