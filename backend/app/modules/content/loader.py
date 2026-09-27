"""Reads the question bank in ``content/`` through the repository's own validator.

``content/tools/validate.py`` holds the schema and the quality rules that CI runs. The seed
imports its ``load()`` from the content directory itself, so the files and the rules they are
checked against always come together, then turns the result into the plain records below.
"""

import hashlib
import importlib.util
import json
import sys
from collections import defaultdict
from dataclasses import asdict, dataclass
from pathlib import Path
from types import ModuleType
from typing import Any

from app.modules.content.models import QuestionKind

VALIDATOR_PATH = Path("tools") / "validate.py"
_VALIDATOR_MODULE = "quiz_content_validate"


class ContentProblems(Exception):
    """The content failed validation; nothing may be loaded."""

    def __init__(self, problems: list[str]) -> None:
        super().__init__(f"{len(problems)} content problem(s)")
        self.problems = problems


@dataclass(frozen=True, slots=True)
class GoalSpec:
    slug: str
    name: str
    subjects: tuple[str, ...]


@dataclass(frozen=True, slots=True)
class SubjectSpec:
    slug: str
    name: str
    tone: str
    icon: str


@dataclass(frozen=True, slots=True)
class TopicSpec:
    slug: str
    name: str


@dataclass(frozen=True, slots=True)
class ChapterSpec:
    subject: str
    slug: str
    name: str
    order: int
    topics: tuple[TopicSpec, ...]


@dataclass(frozen=True, slots=True)
class PassageSpec:
    external_id: str
    subject: str
    chapter: str | None
    title: str
    body: str
    difficulty: int


@dataclass(frozen=True, slots=True)
class QuestionSpec:
    external_id: str
    kind: QuestionKind
    subject: str
    chapter: str | None  # chapter slug; optional for passage questions
    topic: str | None  # topic slug; None for passage questions
    passage: str | None  # passage external id, for passage questions
    category: str
    exams: tuple[str, ...] | None
    difficulty: int
    battle: bool
    tags: tuple[str, ...]
    stem: str
    options: tuple[str, ...]
    answer: int
    explanation: str

    @property
    def content_hash(self) -> str:
        """SHA-256 of what the student is asked: stem, options and answer."""
        canonical = json.dumps(
            {"stem": self.stem, "options": list(self.options), "answer": self.answer},
            ensure_ascii=False,
            separators=(",", ":"),
            sort_keys=True,
        )
        return hashlib.sha256(canonical.encode()).hexdigest()


@dataclass(frozen=True, slots=True)
class WordSpec:
    external_id: str
    subject: str
    word: str
    clue: str
    difficulty: int


@dataclass(frozen=True, slots=True)
class ContentBundle:
    goals: tuple[GoalSpec, ...]
    subjects: tuple[SubjectSpec, ...]
    chapters: tuple[ChapterSpec, ...]
    passages: tuple[PassageSpec, ...]
    questions: tuple[QuestionSpec, ...]
    words: tuple[WordSpec, ...]

    @property
    def version(self) -> str:
        """Hash of everything loaded: equal bundles have equal versions."""
        canonical = json.dumps(asdict(self), ensure_ascii=False, sort_keys=True, default=str)
        return hashlib.sha256(canonical.encode()).hexdigest()


def load_validator(root: Path) -> ModuleType:
    """Import ``<root>/tools/validate.py`` as a module."""
    path = root / VALIDATOR_PATH
    spec = importlib.util.spec_from_file_location(_VALIDATOR_MODULE, path)
    if spec is None or spec.loader is None or not path.is_file():
        raise ContentProblems([f"{path}: the content validator is missing"])
    module = importlib.util.module_from_spec(spec)
    # Registered before running it: dataclasses and pydantic look the module up by name.
    sys.modules[_VALIDATOR_MODULE] = module
    try:
        spec.loader.exec_module(module)
    except BaseException:
        sys.modules.pop(_VALIDATOR_MODULE, None)
        raise
    return module


def load_content(root: Path) -> ContentBundle:
    """Validate and read the content under ``root``; ``ContentProblems`` lists every problem."""
    if not (root / "catalog.yaml").is_file():
        raise ContentProblems([f"{root}: no catalog.yaml here; is this the content directory?"])
    content, problems = load_validator(root).load(root)
    if problems:
        raise ContentProblems(list(problems))
    bundle = _bundle(content)
    problems = _check_topic_slugs(bundle)
    if problems:
        raise ContentProblems(problems)
    return bundle


def _bundle(content: Any) -> ContentBundle:
    """Copy the validator's pydantic models into plain records (the validator is untyped)."""
    catalog = content.catalog
    chapters: list[ChapterSpec] = []
    questions: list[QuestionSpec] = []
    for file in content.chapters:
        chapter = file.chapter
        chapters.append(
            ChapterSpec(
                subject=file.subject,
                slug=chapter.slug,
                name=chapter.name,
                order=chapter.order,
                topics=tuple(TopicSpec(topic.slug, topic.name) for topic in chapter.topics),
            )
        )
        questions.extend(
            QuestionSpec(
                external_id=q.id,
                kind=QuestionKind.MCQ_SINGLE,
                subject=file.subject,
                chapter=chapter.slug,
                topic=q.topic,
                passage=None,
                category=str(q.category.value),
                exams=tuple(q.exams) if q.exams is not None else None,
                difficulty=q.difficulty,
                battle=q.battle,
                tags=tuple(q.tags),
                stem=q.stem,
                options=tuple(q.options),
                answer=q.answer,
                explanation=q.explanation,
            )
            for q in file.questions
        )
    passages: list[PassageSpec] = []
    for file in content.passages:
        for passage in file.passages:
            passages.append(
                PassageSpec(
                    external_id=passage.id,
                    subject=file.subject,
                    chapter=passage.chapter,
                    title=passage.title,
                    body=passage.body,
                    difficulty=passage.difficulty,
                )
            )
            questions.extend(
                QuestionSpec(
                    external_id=q.id,
                    kind=QuestionKind.PASSAGE_MCQ,
                    subject=file.subject,
                    chapter=passage.chapter,
                    topic=None,
                    passage=passage.id,
                    category=str(q.category.value),
                    exams=None,
                    difficulty=q.difficulty if q.difficulty is not None else passage.difficulty,
                    battle=False,
                    tags=tuple(q.tags),
                    stem=q.stem,
                    options=tuple(q.options),
                    answer=q.answer,
                    explanation=q.explanation,
                )
                for q in passage.questions
            )
    return ContentBundle(
        goals=tuple(GoalSpec(g.slug, g.name, tuple(g.subjects)) for g in catalog.goals),
        subjects=tuple(SubjectSpec(s.slug, s.name, s.tone, s.icon) for s in catalog.subjects),
        chapters=tuple(chapters),
        passages=tuple(passages),
        questions=tuple(questions),
        words=tuple(
            WordSpec(w.id, file.subject, w.word, w.clue, w.difficulty)
            for file in content.words
            for w in file.words
        ),
    )


def _check_topic_slugs(bundle: ContentBundle) -> list[str]:
    """The API names a topic by subject and slug, so a slug may appear in one chapter only."""
    seen: dict[tuple[str, str], list[str]] = defaultdict(list)
    for chapter in bundle.chapters:
        for topic in chapter.topics:
            seen[chapter.subject, topic.slug].append(chapter.slug)
    return [
        f"questions/{subject}: topic {slug} is used by several chapters ({', '.join(chapters)})"
        for (subject, slug), chapters in sorted(seen.items())
        if len(chapters) > 1
    ]
