"""Importing questions from CSV or JSON (``scripts/import_questions.py`` and the admin upload).

The format is documented in ``docs/content-format.md`` ("Importing questions"). Every row is
checked with the validator's rules (``rules.py``) and against the bank, and gets one outcome:

* ``ok``: valid and new (imported unless this is a dry run);
* ``error``: breaks a rule, or names an unknown subject, chapter or topic;
* ``duplicate``: the same question (normalized stem and set of options) is already in the bank
  or earlier in the file. Duplicates are skipped, which makes importing a file again a no-op;
* ``near_duplicate``: a question of the same subject is very similar (pg_trgm similarity of stem
  and options above 0.9) or has the same stem. Imported only when explicitly allowed.

Nothing is written unless every row is ok or a duplicate, or ``skip_invalid`` is set (then the
ok rows are imported and the rest reported). New questions get the subject's next ``seq``, the
status ``review`` (or ``published`` when asked), ``source = 'import'``, and one audit-log entry
records the import.
"""

import csv
import hashlib
import io
import json
import re
import uuid
from collections import defaultdict
from collections.abc import Iterable, Mapping, Sequence
from dataclasses import dataclass, field
from datetime import datetime
from enum import StrEnum
from typing import Annotated, Any, Literal

from pydantic import (
    BaseModel,
    ConfigDict,
    Field,
    ValidationError,
    ValidationInfo,
    field_validator,
)
from sqlalchemy import select, text
from sqlalchemy.ext.asyncio import AsyncSession

from app.modules.content.editing import (
    bump_content_version,
    content_hash,
    lock_content,
    next_seqs,
    search_text,
)
from app.modules.content.models import (
    BattlePool,
    Category,
    Chapter,
    ContentSource,
    ContentStatus,
    ExamGoal,
    GoalSubject,
    Question,
    QuestionKind,
    Subject,
    Topic,
)
from app.modules.content.rules import dedupe_key, normalize, question_problems
from app.modules.system.models import AuditLog

MAX_FILE_BYTES = 5 * 1024 * 1024
MAX_ROWS = 5000
NEAR_DUPLICATE_SIMILARITY = 0.9
LIST_SEPARATOR = re.compile(r"\s*[|;]\s*")
EXTERNAL_ID = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")
GENERATED_ID_PREFIX = "imp-"

CSV_REQUIRED = (
    "subject",
    "chapter",
    "topic",
    "category",
    "difficulty",
    "stem",
    "option_a",
    "option_b",
    "option_c",
    "option_d",
    "answer",
    "explanation",
)
CSV_OPTIONAL = ("id", "exams", "battle_pool", "tags")
_OPTION_COLUMNS = ("option_a", "option_b", "option_c", "option_d")


class ImportFormat(StrEnum):
    CSV = "csv"
    JSON = "json"


class RowStatus(StrEnum):
    OK = "ok"
    ERROR = "error"
    DUPLICATE = "duplicate"
    NEAR_DUPLICATE = "near_duplicate"


@dataclass(frozen=True, slots=True)
class ImportOptions:
    dry_run: bool = True
    publish: bool = False  # status published instead of review
    skip_invalid: bool = False  # import the ok rows even if others have errors
    allow_near_duplicates: bool = False  # import near duplicates too


@dataclass(slots=True)
class RowResult:
    row: int  # CSV line number (the header is line 1) or 1-based position in the JSON list
    status: RowStatus = RowStatus.OK
    external_id: str | None = None
    messages: list[str] = field(default_factory=list)
    match: str | None = None  # the existing question's external id, or "row N"
    similarity: float | None = None
    imported: bool = False

    def as_dict(self) -> dict[str, Any]:
        return {
            "row": self.row,
            "status": self.status.value,
            "external_id": self.external_id,
            "messages": self.messages,
            "match": self.match,
            "similarity": self.similarity,
            "imported": self.imported,
        }


@dataclass(slots=True)
class ImportReport:
    rows: list[RowResult]
    options: ImportOptions
    file_problems: list[str] = field(default_factory=list)
    imported: int = 0
    audit_id: uuid.UUID | None = None

    @property
    def counts(self) -> dict[str, int]:
        counts = dict.fromkeys((status.value for status in RowStatus), 0)
        for row in self.rows:
            counts[row.status.value] += 1
        return counts

    @property
    def blocked(self) -> bool:
        """Whether problems stop the import (unless ``skip_invalid``)."""
        return bool(self.file_problems) or any(self._blocks(row) for row in self.rows)

    def _blocks(self, row: RowResult) -> bool:
        return row.status is RowStatus.ERROR or (
            row.status is RowStatus.NEAR_DUPLICATE and not self.options.allow_near_duplicates
        )

    def summary(self) -> str:
        counts = ", ".join(f"{name} {n}" for name, n in self.counts.items())
        if self.file_problems:
            return "The file can't be imported: " + "; ".join(self.file_problems)
        if self.options.dry_run:
            return f"Dry run, nothing written. {len(self.rows)} rows: {counts}."
        if self.imported == 0 and self.blocked and not self.options.skip_invalid:
            return (
                f"Nothing imported: fix the rows with problems, or skip them. "
                f"{len(self.rows)} rows: {counts}."
            )
        return f"Imported {self.imported} questions. {len(self.rows)} rows: {counts}."

    def as_dict(self) -> dict[str, Any]:
        return {
            "summary": self.summary(),
            "dry_run": self.options.dry_run,
            "imported": self.imported,
            "counts": self.counts,
            "file_problems": self.file_problems,
            "rows": [row.as_dict() for row in self.rows],
        }


class ImportRow(BaseModel):
    """One question as the file gives it (after CSV columns are mapped to these names)."""

    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)

    id: Annotated[str, Field(max_length=64, pattern=EXTERNAL_ID.pattern)] | None = None
    subject: Annotated[str, Field(min_length=1, max_length=48)]
    chapter: Annotated[str, Field(min_length=1, max_length=48)]
    topic: Annotated[str, Field(min_length=1, max_length=48)]
    category: Category
    difficulty: int
    exams: list[Literal["neet", "jee"]] | None = None
    battle_pool: BattlePool = BattlePool.NONE
    stem: str
    options: list[str]
    answer: int
    explanation: str
    tags: list[Annotated[str, Field(min_length=1, max_length=40)]] = []

    @field_validator("exams", "tags", mode="before")
    @classmethod
    def _split_list(cls, value: Any, info: ValidationInfo) -> Any:
        """CSV cells list items separated by ``|`` (or ``;``); a missing value means none."""
        if isinstance(value, str):
            value = [item for item in LIST_SEPARATOR.split(value.strip()) if item]
        if info.field_name == "tags" and value is None:
            return []
        return value

    @field_validator("answer", mode="before")
    @classmethod
    def _answer_letter(cls, value: Any) -> Any:
        """``A``–``D`` (any case) or a 0-based index."""
        if isinstance(value, str):
            stripped = value.strip()
            if len(stripped) == 1 and stripped.upper() in "ABCD":
                return "ABCD".index(stripped.upper())
        return value

    @field_validator("category", "battle_pool", mode="before")
    @classmethod
    def _lower(cls, value: Any, info: ValidationInfo) -> Any:
        if value is None and info.field_name == "battle_pool":
            return BattlePool.NONE.value  # JSON null: the default
        return value.strip().lower() if isinstance(value, str) else value


def detect_format(filename: str | None, data: bytes) -> ImportFormat:
    """From the file extension, else from the first non-blank character."""
    name = (filename or "").lower()
    if name.endswith(".json"):
        return ImportFormat.JSON
    if name.endswith(".csv"):
        return ImportFormat.CSV
    head = data.lstrip(b"\xef\xbb\xbf \t\r\n")[:1]
    return ImportFormat.JSON if head in (b"[", b"{") else ImportFormat.CSV


def parse_file(data: bytes, fmt: ImportFormat) -> tuple[list[tuple[int, Any]], list[str]]:
    """The raw rows with their row numbers, and problems with the file as a whole."""
    if len(data) > MAX_FILE_BYTES:
        return [], [f"the file is larger than {MAX_FILE_BYTES // (1024 * 1024)} MB"]
    try:
        content = data.decode("utf-8-sig")
    except UnicodeDecodeError:
        return [], ["the file must be UTF-8 text"]
    rows, problems = _parse_csv(content) if fmt is ImportFormat.CSV else _parse_json(content)
    if not problems and not rows:
        problems.append("the file has no questions")
    if len(rows) > MAX_ROWS:
        problems.append(f"the file has {len(rows)} questions; import at most {MAX_ROWS} at once")
    return rows, problems


def _parse_json(content: str) -> tuple[list[tuple[int, Any]], list[str]]:
    try:
        document = json.loads(content)
    except json.JSONDecodeError as exc:
        return [], [f"not valid JSON: {exc.msg} (line {exc.lineno}, column {exc.colno})"]
    if isinstance(document, dict) and set(document) == {"questions"}:
        document = document["questions"]
    if not isinstance(document, list):
        return [], ['expected a JSON list of questions (or {"questions": [...]})']
    return list(enumerate(document, start=1)), []


def _parse_csv(content: str) -> tuple[list[tuple[int, Any]], list[str]]:
    reader = csv.DictReader(io.StringIO(content, newline=""), strict=True)
    try:
        header = [name.strip().lower() for name in reader.fieldnames or []]
    except csv.Error as exc:
        return [], [f"not valid CSV: {exc}"]
    missing = [name for name in CSV_REQUIRED if name not in header]
    unknown = [name for name in header if name not in (*CSV_REQUIRED, *CSV_OPTIONAL)]
    duplicated = sorted({name for name in header if header.count(name) > 1})
    problems = []
    if missing:
        problems.append("missing columns: " + ", ".join(missing))
    if unknown:
        problems.append("unknown columns: " + ", ".join(unknown))
    if duplicated:
        problems.append("repeated columns: " + ", ".join(duplicated))
    if problems:
        return [], problems
    reader.fieldnames = header
    rows: list[tuple[int, Any]] = []
    try:
        for record in reader:
            line = reader.line_num
            if None in record:
                rows.append((line, {"__problem__": "the row has more cells than the header"}))
                continue
            if all(not (value or "").strip() for value in record.values()):
                continue  # blank line
            row: dict[str, Any] = {
                name: value for name, value in record.items() if name not in _OPTION_COLUMNS
            }
            row["options"] = [record[name] or "" for name in _OPTION_COLUMNS]
            answer = (record["answer"] or "").strip()
            if answer and answer.upper() not in ("A", "B", "C", "D"):
                # A number is ambiguous in a sheet (0- or 1-based?), so CSV takes letters only.
                rows.append((line, {"__problem__": "answer: write the letter A, B, C or D"}))
                continue
            # A blank cell leaves the field out, so optional fields take their defaults.
            cells = {name: _cell(value) for name, value in row.items()}
            rows.append((line, {name: value for name, value in cells.items() if value is not None}))
    except csv.Error as exc:
        return [], [f"not valid CSV (line {reader.line_num}): {exc}"]
    return rows, []


def _cell(value: Any) -> Any:
    """Empty cells count as missing (so optional columns can be left blank)."""
    if isinstance(value, str):
        stripped = value.strip()
        return stripped or None
    if isinstance(value, list):
        return [item.strip() for item in value]
    return value


def _validation_messages(error: ValidationError) -> list[str]:
    messages = []
    for item in error.errors(include_url=False):
        where = ".".join(str(part) for part in item["loc"]) or "row"
        messages.append(f"{where}: {item['msg']}")
    return messages


@dataclass(frozen=True, slots=True)
class _Catalog:
    subjects: dict[str, Subject]
    chapters: dict[tuple[int, str], Chapter]
    topics: dict[tuple[int, str], Topic]
    exams: dict[int, set[str]]


async def _load_catalog(db: AsyncSession, subject_slugs: Iterable[str]) -> _Catalog:
    subjects = {
        row.slug: row
        for row in await db.scalars(select(Subject).where(Subject.slug.in_(set(subject_slugs))))
    }
    ids = [subject.id for subject in subjects.values()]
    chapters = {
        (row.subject_id, row.slug): row
        for row in await db.scalars(select(Chapter).where(Chapter.subject_id.in_(ids)))
    }
    chapter_ids = [chapter.id for chapter in chapters.values()]
    topics = {
        (row.chapter_id, row.slug): row
        for row in await db.scalars(select(Topic).where(Topic.chapter_id.in_(chapter_ids)))
    }
    exams: dict[int, set[str]] = defaultdict(set)
    pairs = await db.execute(
        select(GoalSubject.subject_id, ExamGoal.slug)
        .join(ExamGoal, ExamGoal.id == GoalSubject.goal_id)
        .where(GoalSubject.subject_id.in_(ids))
    )
    for subject_id, slug in pairs:
        exams[subject_id].add(slug)
    return _Catalog(subjects, chapters, topics, exams)


@dataclass(slots=True)
class _Candidate:
    """A row that passed validation, with everything needed to insert it."""

    result: RowResult
    data: ImportRow
    subject: Subject
    chapter: Chapter
    topic: Topic
    key: str


@dataclass(frozen=True, slots=True)
class _Existing:
    external_id: str
    key: str
    stem: str


async def import_questions(
    db: AsyncSession,
    raw_rows: Sequence[tuple[int, Any]],
    options: ImportOptions,
    *,
    source_name: str,
    source_digest: str,
    actor_id: uuid.UUID | None,
    ip: str | None,
    now: datetime,
    file_problems: Sequence[str] = (),
) -> ImportReport:
    """Check ``raw_rows`` (from ``parse_file``) and import them unless ``options.dry_run``.

    The caller commits. ``source_name`` and ``source_digest`` (the file's name and SHA-256) go
    into the audit log.
    """
    report = ImportReport(rows=[], options=options, file_problems=list(file_problems))
    if report.file_problems:
        return report
    if not options.dry_run:
        # Held from the checks to the inserts, so concurrent imports can't both add a question.
        await lock_content(db)

    parsed: list[tuple[RowResult, ImportRow]] = []
    for number, raw in raw_rows:
        result = RowResult(row=number)
        report.rows.append(result)
        if not isinstance(raw, dict):
            _fail(result, ["each question must be an object"])
            continue
        if "__problem__" in raw:
            _fail(result, [raw["__problem__"]])
            continue
        result.external_id = raw.get("id") if isinstance(raw.get("id"), str) else None
        try:
            parsed.append((result, ImportRow.model_validate(raw)))
        except ValidationError as exc:
            _fail(result, _validation_messages(exc))

    catalog = await _load_catalog(db, {row.subject for _, row in parsed})
    candidates = [
        candidate
        for result, row in parsed
        if (candidate := _check_row(result, row, catalog)) is not None
    ]
    existing = await _existing_questions(db, {c.subject.id for c in candidates})
    _check_duplicates(candidates, existing)
    await _check_near_duplicates(db, [c for c in candidates if c.result.status is RowStatus.OK])

    importable = [
        c
        for c in candidates
        if c.result.status is RowStatus.OK
        or (c.result.status is RowStatus.NEAR_DUPLICATE and options.allow_near_duplicates)
    ]
    if options.dry_run or not importable or (report.blocked and not options.skip_invalid):
        return report
    await _insert(db, importable, publish=options.publish)
    report.imported = len(importable)
    audit = AuditLog(
        actor_id=actor_id,
        action="questions.imported",
        entity_type="question_import",
        entity_id=source_digest,
        before=None,
        after={
            "file": source_name,
            "sha256": source_digest,
            "status": _status(options.publish).value,
            "counts": report.counts,
            "imported": [c.result.external_id for c in importable],
        },
        ip=ip,
    )
    db.add(audit)
    if options.publish:
        await bump_content_version(db, now=now)
    await db.flush()
    report.audit_id = audit.id
    return report


def _fail(result: RowResult, messages: Iterable[str]) -> None:
    result.status = RowStatus.ERROR
    result.messages.extend(messages)


def _check_row(result: RowResult, row: ImportRow, catalog: _Catalog) -> _Candidate | None:
    subject = catalog.subjects.get(row.subject)
    if subject is None:
        _fail(result, [f"unknown subject {row.subject!r}"])
        return None
    chapter = catalog.chapters.get((subject.id, row.chapter))
    if chapter is None or not chapter.is_active:
        _fail(result, [f"{row.subject} has no chapter {row.chapter!r}"])
        return None
    topic = catalog.topics.get((chapter.id, row.topic))
    if topic is None or not topic.is_active:
        _fail(result, [f"chapter {row.chapter} has no topic {row.topic!r}"])
        return None
    problems = question_problems(
        stem=row.stem,
        options=row.options,
        answer=row.answer,
        explanation=row.explanation,
        difficulty=row.difficulty,
        battle=row.battle_pool is not BattlePool.NONE,
        exams=row.exams,
        subject_exams=catalog.exams.get(subject.id, set()),
    )
    if problems:
        _fail(result, problems)
        return None
    key = dedupe_key(row.stem, row.options)
    result.external_id = row.id or f"{GENERATED_ID_PREFIX}{subject.slug[:3]}-{key[:12]}"
    return _Candidate(result, row, subject, chapter, topic, key)


async def _existing_questions(
    db: AsyncSession, subject_ids: set[int]
) -> dict[int, list[_Existing]]:
    """Every live question of the subjects, keyed for duplicate checks."""
    rows = await db.execute(
        select(Question.subject_id, Question.external_id, Question.stem, Question.options).where(
            Question.subject_id.in_(subject_ids),
            Question.status != ContentStatus.RETIRED.value,
        )
    )
    existing: dict[int, list[_Existing]] = defaultdict(list)
    for subject_id, external_id, stem, question_options in rows:
        existing[subject_id].append(
            _Existing(external_id, dedupe_key(stem, question_options), normalize(stem))
        )
    return existing


def _check_duplicates(
    candidates: Sequence[_Candidate], existing: Mapping[int, Sequence[_Existing]]
) -> None:
    by_key: dict[str, str] = {}
    by_stem: dict[str, str] = {}
    live_ids: dict[str, str] = {}
    for items in existing.values():
        for item in items:
            by_key.setdefault(item.key, item.external_id)
            by_stem.setdefault(item.stem, item.external_id)
            live_ids[item.external_id] = item.key
    all_live_ids = set(live_ids)

    seen_keys: dict[str, int] = {}
    seen_stems: dict[str, int] = {}
    seen_ids: dict[str, int] = {}
    for candidate in candidates:
        result, key = candidate.result, candidate.key
        stem = normalize(candidate.data.stem)
        external_id = result.external_id or ""
        if key in seen_keys:
            result.status, result.match = RowStatus.DUPLICATE, f"row {seen_keys[key]}"
            result.messages.append(f"the same question as row {seen_keys[key]}")
        elif key in by_key:
            result.status, result.match = RowStatus.DUPLICATE, by_key[key]
            result.messages.append(f"already in the bank as {by_key[key]}")
            result.external_id = by_key[key]
        elif stem in seen_stems:
            _fail(result, [f"the same stem as row {seen_stems[stem]}, with other options"])
        elif external_id in seen_ids:
            _fail(result, [f"id {external_id} is also used by row {seen_ids[external_id]}"])
        elif external_id in all_live_ids:
            _fail(result, [f"id {external_id} is already used by another question"])
        elif stem in by_stem:
            result.status, result.match, result.similarity = (
                RowStatus.NEAR_DUPLICATE,
                by_stem[stem],
                1.0,
            )
            result.messages.append(f"{by_stem[stem]} has the same stem, with other options")
        seen_keys.setdefault(key, result.row)
        seen_stems.setdefault(stem, result.row)
        seen_ids.setdefault(external_id, result.row)


_NEAR_DUPLICATES = text(
    """
    SELECT r.idx, m.external_id, m.sim
    FROM unnest(CAST(:idx AS int[]), CAST(:subject AS int[]), CAST(:body AS text[]),
                CAST(:search AS text[])) AS r(idx, subject_id, body, search)
    CROSS JOIN LATERAL (
        SELECT q.external_id,
               similarity(q.stem || ' ' || array_to_string(q.options, ' '), r.body) AS sim
        FROM questions AS q
        -- Candidates come from the trigram index on search_text (pg_trgm's default 0.3
        -- threshold); it also holds tags and names, so the exact check is on stem and options.
        WHERE q.search_text % r.search
          AND q.subject_id = r.subject_id
          AND q.status <> 'retired'
        ORDER BY sim DESC, q.external_id
        LIMIT 1
    ) AS m
    WHERE m.sim > :threshold
    """
)


async def _check_near_duplicates(db: AsyncSession, candidates: Sequence[_Candidate]) -> None:
    if not candidates:
        return
    rows = await db.execute(
        _NEAR_DUPLICATES,
        {
            "idx": list(range(len(candidates))),
            "subject": [c.subject.id for c in candidates],
            "body": [f"{c.data.stem} {' '.join(c.data.options)}" for c in candidates],
            "search": [
                search_text(c.data.stem, c.data.options, (), topic_name=None, chapter=None)
                for c in candidates
            ],
            "threshold": NEAR_DUPLICATE_SIMILARITY,
        },
    )
    for index, external_id, similarity in rows.all():
        result = candidates[index].result
        result.status = RowStatus.NEAR_DUPLICATE
        result.match = external_id
        result.similarity = round(float(similarity), 3)
        result.messages.append(f"very similar to {external_id} ({similarity:.0%})")


def _status(publish: bool) -> ContentStatus:
    return ContentStatus.PUBLISHED if publish else ContentStatus.REVIEW


async def _insert(db: AsyncSession, candidates: Sequence[_Candidate], *, publish: bool) -> None:
    last_seq = await next_seqs(db, sorted({c.subject.id for c in candidates}))
    for candidate in candidates:
        row = candidate.data
        last_seq[candidate.subject.id] += 1
        db.add(
            Question(
                external_id=candidate.result.external_id,
                subject_id=candidate.subject.id,
                chapter_id=candidate.chapter.id,
                topic_id=candidate.topic.id,
                passage_id=None,
                kind=QuestionKind.MCQ_SINGLE.value,
                category=row.category.value,
                exams=list(row.exams) if row.exams else None,
                difficulty=row.difficulty,
                battle_pool=row.battle_pool.value,
                status=_status(publish).value,
                stem=row.stem,
                options=list(row.options),
                answer=row.answer,
                explanation=row.explanation,
                tags=list(row.tags),
                search_text=search_text(
                    row.stem,
                    row.options,
                    row.tags,
                    topic_name=candidate.topic.name,
                    chapter=candidate.chapter,
                ),
                content_hash=content_hash(row.stem, row.options, row.answer),
                supersedes_id=None,
                seq=last_seq[candidate.subject.id],
                source=ContentSource.IMPORT.value,
            )
        )
        candidate.result.imported = True
    await db.flush()


def file_digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()
