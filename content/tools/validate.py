"""Schema and quality checks for the question bank (see docs/content-format.md).

Validate from the repo root (exits non-zero and lists every problem):

    uv run --with pyyaml --with pydantic python content/tools/validate.py
    uv run --with pyyaml --with pydantic python content/tools/validate.py --stats \
        content/questions/physics/waves.yaml     # only these chapter files, plus a summary

The backend's seed command imports ``load`` from this file, so CI and the loader share one set of
rules and one set of models.
"""

import re
import sys
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from enum import StrEnum
from pathlib import Path
from typing import Annotated, Literal

import yaml
from pydantic import BaseModel, ConfigDict, Field, ValidationError, field_validator

ROOT = Path(__file__).resolve().parents[1]
# A chapter can host a Quick Battle (7 questions) once it has this many battle questions. Real
# banks should have 15+ per chapter so players rarely see repeats.
MIN_BATTLE_PER_CHAPTER = 7
MAX_ANSWER_SHARE = 0.45
MIN_QUESTIONS_PER_TOPIC = 2
MIN_CATEGORIES_PER_CHAPTER = 2
MAX_TOPICS_PER_CHAPTER = 12
MAX_STEM = 700
MAX_BATTLE_STEM = 180
# Options are shuffled in battles and labelled A–D by position, so they must never point at
# each other.
OPTION_XREF = re.compile(
    r"\b(all|none|both|neither) of (the )?(above|these)\b|\bboth \(?[A-D]\)? and \(?[A-D]\)?(\W|$)"
    r"|\boption \(?[A-D]\)?(\W|$)",
    re.IGNORECASE,
)
LATEX = re.compile(r"\\[a-zA-Z]+|\$")
SLUG = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")
WORD = re.compile(r"^[A-Z]{3,12}$")

Text = Annotated[str, Field(min_length=1)]
Slug = Annotated[str, Field(pattern=SLUG.pattern, max_length=48)]
Exam = Literal["neet", "jee"]
Tone = Literal["sky", "mint", "lemon", "lavender", "peach", "rose", "lime"]


class Category(StrEnum):
    """What kind of thinking a question tests; drives the "practice more numericals" style tips."""

    CONCEPT = "concept"
    NUMERICAL = "numerical"
    FACTUAL = "factual"
    APPLICATION = "application"


class Format(StrEnum):
    """How a question is presented (NEET styles), independent of its category."""

    DIRECT = "direct"  # a plain single-idea question
    STATEMENTS = "statements"  # the options are statements: pick the correct or incorrect one
    MULTI_STATEMENT = "multi-statement"  # statements I–IV in the stem, options combine them
    STATEMENT_PAIR = "statement-pair"  # Statement I / Statement II
    ASSERTION_REASON = "assertion-reason"  # Assertion (A) / Reason (R)
    MATCH = "match"  # List I (P–S) with List II (1–4)
    ORDERING = "ordering"  # arrange in increasing / decreasing order
    GRAPH = "graph"  # read or pick a graph (described in words, or drawn: see `diagram`)
    DIAGRAM = "diagram"  # needs the figure in `diagram`
    CASE = "case"  # an experiment or real-life situation


def _normalize(text: str) -> str:
    return re.sub(r"\s+", " ", text).strip().lower()


def _markup_problem(text: str) -> str | None:
    depth = 0
    for ch in text:
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth < 0:
                return "unbalanced '}'"
    if depth:
        return "unbalanced '{'"
    if LATEX.search(text):
        return "LaTeX is not supported; use the markup in docs/content-format.md"
    return None


class _Model(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)


class CatalogGoal(_Model):
    slug: Slug
    name: Text
    subjects: list[Slug] = Field(min_length=1)


class CatalogSubject(_Model):
    slug: Slug
    name: Text
    tone: Tone
    icon: Text


class Catalog(_Model):
    goals: list[CatalogGoal] = Field(min_length=1)
    subjects: list[CatalogSubject] = Field(min_length=1)


class _QuestionBase(_Model):
    id: Text
    category: Category
    stem: Annotated[str, Field(min_length=10, max_length=MAX_STEM)]
    options: list[Annotated[str, Field(min_length=1, max_length=160)]]
    answer: int = Field(ge=0, le=3)
    explanation: Annotated[str, Field(min_length=10, max_length=1500)]
    tags: list[str] = []

    @field_validator("options")
    @classmethod
    def _four_distinct(cls, options: list[str]) -> list[str]:
        if len(options) != 4:
            raise ValueError(f"expected 4 options, got {len(options)}")
        if len({_normalize(o) for o in options}) != 4:
            raise ValueError("options must all be different")
        return options


class Question(_QuestionBase):
    topic: Slug  # the chapter's module
    exams: list[Exam] | None = Field(default=None, min_length=1)
    difficulty: int = Field(ge=1, le=5)  # easy 1–2, medium 3, hard 4–5
    battle: bool = False
    # Optional metadata for the real bank (see docs/content-format.md).
    subtopic: Annotated[str, Field(min_length=2, max_length=80)] | None = None
    concept: Annotated[str, Field(min_length=2, max_length=120)] | None = None
    format: Format = Format.DIRECT
    time: int | None = Field(default=None, ge=10, le=600)  # typical seconds to answer
    ncert: bool | None = None  # rests directly on NCERT text
    formula: Annotated[str, Field(min_length=1, max_length=200)] | None = None
    diagram: Annotated[str, Field(min_length=40, max_length=1500)] | None = None

    @field_validator("exams")
    @classmethod
    def _distinct_exams(cls, exams: list[str] | None) -> list[str] | None:
        if exams is not None and len(set(exams)) != len(exams):
            raise ValueError("exams must not repeat")
        return exams


class PassageQuestion(_QuestionBase):
    # Falls back to the passage's difficulty when omitted.
    difficulty: int | None = Field(default=None, ge=1, le=5)


class Topic(_Model):
    slug: Slug
    name: Annotated[str, Field(min_length=2, max_length=60)]


class Chapter(_Model):
    slug: Slug
    name: Text
    order: int = Field(ge=1)
    classes: list[Literal[11, 12]] | None = Field(default=None, min_length=1)  # NCERT class
    topics: list[Topic] = Field(min_length=2, max_length=MAX_TOPICS_PER_CHAPTER)


class ChapterFile(_Model):
    subject: Text
    chapter: Chapter
    questions: list[Question]


class Passage(_Model):
    id: Text
    title: Text
    chapter: Slug | None = None
    difficulty: int = Field(ge=1, le=5)
    body: Annotated[str, Field(min_length=300, max_length=2400)]
    questions: list[PassageQuestion] = Field(min_length=3, max_length=5)


class PassageFile(_Model):
    subject: Text
    passages: list[Passage]


class Word(_Model):
    id: Text
    word: Text
    clue: Annotated[str, Field(min_length=10, max_length=200)]
    difficulty: int = Field(ge=1, le=5)

    @field_validator("word")
    @classmethod
    def _letters(cls, word: str) -> str:
        if not WORD.match(word):
            raise ValueError("word must be 3–12 uppercase letters A–Z")
        return word


class WordFile(_Model):
    subject: Text
    words: list[Word]


@dataclass
class Content:
    """Everything that parsed. Check the problems returned alongside it before using it."""

    catalog: Catalog | None = None
    chapters: list[ChapterFile] = field(default_factory=list)
    passages: list[PassageFile] = field(default_factory=list)
    words: list[WordFile] = field(default_factory=list)


def _read(path: Path) -> object:
    with path.open(encoding="utf-8") as f:
        return yaml.safe_load(f)


def _check_catalog(catalog: Catalog) -> list[str]:
    problems: list[str] = []
    subjects = [s.slug for s in catalog.subjects]
    if len(set(subjects)) != len(subjects):
        problems.append("catalog.yaml: subject slugs repeat")
    goals = [g.slug for g in catalog.goals]
    if len(set(goals)) != len(goals):
        problems.append("catalog.yaml: goal slugs repeat")
    for goal in catalog.goals:
        for slug in goal.subjects:
            if slug not in subjects:
                problems.append(f"catalog.yaml: goal {goal.slug} lists unknown subject {slug}")
    return problems


def _check_chapter(data: ChapterFile, where: str, exams_for_subject: set[str]) -> list[str]:
    """Rules about one chapter as a whole: topics, categories, battle pool and answer spread."""
    problems: list[str] = []
    chapter = data.chapter
    questions = data.questions

    topic_slugs = [t.slug for t in chapter.topics]
    if len(set(topic_slugs)) != len(topic_slugs):
        problems.append(f"{where}: topic slugs repeat")
    if len({_normalize(t.name) for t in chapter.topics}) != len(chapter.topics):
        problems.append(f"{where}: topic names repeat")

    per_topic = Counter(q.topic for q in questions)
    for q in questions:
        if q.topic not in topic_slugs:
            problems.append(f"{where}: {q.id} has unknown topic {q.topic!r}")
        if q.exams and not set(q.exams) <= exams_for_subject:
            problems.append(
                f"{where}: {q.id} lists exams {q.exams} but {data.subject} is only in "
                f"{sorted(exams_for_subject)}"
            )
    for slug in topic_slugs:
        if per_topic[slug] < MIN_QUESTIONS_PER_TOPIC:
            problems.append(
                f"{where}: topic {slug} has {per_topic[slug]} questions "
                f"(need {MIN_QUESTIONS_PER_TOPIC})"
            )

    categories = {q.category for q in questions}
    if len(categories) < MIN_CATEGORIES_PER_CHAPTER:
        problems.append(f"{where}: uses only {sorted(categories)}; mix question categories")

    battle = sum(q.battle for q in questions)
    if battle < MIN_BATTLE_PER_CHAPTER:
        problems.append(f"{where}: only {battle} battle questions (need {MIN_BATTLE_PER_CHAPTER})")
    answers = Counter(q.answer for q in questions)
    if questions and max(answers.values()) / len(questions) > MAX_ANSWER_SHARE:
        problems.append(f"{where}: answers cluster on one position {dict(answers)}")
    return problems


def _read_syllabus(root: Path) -> dict[str, dict[str, dict[str, object]]]:
    """``syllabus.yaml`` as subject -> chapter slug -> entry; empty when there is none."""
    path = root / "syllabus.yaml"
    if not path.is_file():
        return {}
    data = _read(path) or {}
    return {subject: {c["slug"]: c for c in entries} for subject, entries in data.items()}  # type: ignore[union-attr]


def load(root: Path = ROOT, only: set[Path] | None = None) -> tuple[Content, list[str]]:
    """Parse and check every content file under ``root``; returns what parsed and all problems.

    ``only`` limits the run to those chapter files (passages and words, which refer to every
    chapter, are then skipped).
    """
    content = Content()
    problems: list[str] = []
    try:
        syllabus = _read_syllabus(root)
    except (OSError, yaml.YAMLError, KeyError, TypeError) as e:
        return content, [f"syllabus.yaml: {e}"]
    try:
        content.catalog = Catalog.model_validate(_read(root / "catalog.yaml"))
    except (OSError, ValidationError, yaml.YAMLError) as e:
        return content, [f"catalog.yaml: {e}"]
    catalog = content.catalog
    problems.extend(_check_catalog(catalog))
    subjects = {s.slug for s in catalog.subjects}
    exams_by_subject: dict[str, set[str]] = defaultdict(set)
    for goal in catalog.goals:
        for subject in goal.subjects:
            exams_by_subject[subject].add(goal.slug)

    ids: dict[str, str] = {}
    stems: dict[str, str] = {}
    chapters: dict[str, dict[str, str]] = defaultdict(dict)  # subject -> slug -> file
    # The app and API name a topic by subject and slug, so a slug may appear once per subject.
    topics: dict[str, dict[str, str]] = defaultdict(dict)  # subject -> topic slug -> chapter
    orders: dict[str, dict[int, str]] = defaultdict(dict)

    def check_question(q: _QuestionBase, where: str) -> None:
        if q.id in ids:
            problems.append(f"{where}: duplicate id {q.id} (also in {ids[q.id]})")
        ids[q.id] = where
        key = _normalize(q.stem)
        if key in stems:
            problems.append(f"{where}: duplicate stem for {q.id} (also {stems[key]})")
        stems[key] = q.id
        for field_text in [q.stem, q.explanation, *q.options]:
            issue = _markup_problem(field_text)
            if issue:
                problems.append(f"{where}: {q.id}: {issue}")

    for path in sorted((root / "questions").glob("*/*.yaml")):
        if only and path.resolve() not in only:
            continue
        where = str(path.relative_to(root))
        try:
            data = ChapterFile.model_validate(_read(path))
        except (ValidationError, yaml.YAMLError) as e:
            problems.append(f"{where}: {e}")
            continue
        subject, chapter = data.subject, data.chapter
        if subject not in subjects:
            problems.append(f"{where}: unknown subject {subject}")
        if subject != path.parent.name:
            problems.append(f"{where}: subject {subject} doesn't match folder")
        if chapter.slug != path.stem:
            problems.append(f"{where}: file should be named {chapter.slug}.yaml")
        if chapter.slug in chapters[subject]:
            problems.append(
                f"{where}: chapter {chapter.slug} also in {chapters[subject][chapter.slug]}"
            )
        chapters[subject][chapter.slug] = where
        if chapter.order in orders[subject]:
            problems.append(
                f"{where}: order {chapter.order} also used by {orders[subject][chapter.order]}"
            )
        orders[subject][chapter.order] = where
        for topic in chapter.topics:
            if topic.slug in topics[subject] and topics[subject][topic.slug] != chapter.slug:
                problems.append(
                    f"{where}: topic {topic.slug} also in chapter {topics[subject][topic.slug]}"
                    f" of {subject}; topic slugs must be unique within a subject"
                )
            topics[subject].setdefault(topic.slug, chapter.slug)

        prefix = f"{subject[:3]}-"
        entry = syllabus.get(subject, {}).get(chapter.slug)
        if subject in syllabus and entry is None:
            problems.append(f"{where}: chapter {chapter.slug} is not in syllabus.yaml")
        if entry:
            prefix = f"{subject[:3]}-{entry['prefix']}-"
            for attr in ("name", "order", "classes"):
                if getattr(chapter, attr) != entry[attr]:
                    problems.append(
                        f"{where}: chapter {attr} {getattr(chapter, attr)!r} doesn't match "
                        f"syllabus.yaml ({entry[attr]!r})"
                    )
        for q in data.questions:
            check_question(q, where)
            if not re.match(rf"^{prefix}([a-z0-9]+-)?\d{{3}}$", q.id):
                problems.append(f"{where}: id {q.id} should look like {prefix}<nnn>")
            if q.battle and len(q.stem) > MAX_BATTLE_STEM:
                problems.append(f"{where}: {q.id} is too long for a battle question")
            if q.battle and q.diagram:
                problems.append(f"{where}: {q.id} needs a diagram, so it can't be in battles")
            if q.format == Format.DIAGRAM and not q.diagram:
                problems.append(f"{where}: {q.id} has format diagram but no diagram description")
            for option in q.options:
                if OPTION_XREF.search(option):
                    problems.append(
                        f"{where}: {q.id} option {option!r} refers to other options, which are "
                        "shuffled"
                    )
            for extra in (q.formula, q.diagram, q.subtopic, q.concept):
                issue = _markup_problem(extra) if extra else None
                if issue:
                    problems.append(f"{where}: {q.id}: {issue}")
        problems.extend(_check_chapter(data, where, exams_by_subject[subject]))
        content.chapters.append(data)

    if only:  # passages and words refer to every chapter, so a partial run skips them
        return content, problems

    passage_ids: set[str] = set()
    for path in sorted((root / "passages").glob("*.yaml")):
        where = str(path.relative_to(root))
        try:
            passages = PassageFile.model_validate(_read(path))
        except (ValidationError, yaml.YAMLError) as e:
            problems.append(f"{where}: {e}")
            continue
        if passages.subject not in subjects:
            problems.append(f"{where}: unknown subject {passages.subject}")
        for passage in passages.passages:
            if passage.id in passage_ids:
                problems.append(f"{where}: duplicate passage id {passage.id}")
            passage_ids.add(passage.id)
            if passage.chapter and passage.chapter not in chapters[passages.subject]:
                problems.append(
                    f"{where}: {passage.id} names chapter {passage.chapter!r}, which isn't a "
                    f"{passages.subject} chapter"
                )
            for q in passage.questions:
                check_question(q, where)
        content.passages.append(passages)

    word_ids: set[str] = set()
    words_seen: set[str] = set()
    for path in sorted((root / "words").glob("*.yaml")):
        where = str(path.relative_to(root))
        try:
            words = WordFile.model_validate(_read(path))
        except (ValidationError, yaml.YAMLError) as e:
            problems.append(f"{where}: {e}")
            continue
        if words.subject not in subjects:
            problems.append(f"{where}: unknown subject {words.subject}")
        for w in words.words:
            if w.id in word_ids:
                problems.append(f"{where}: duplicate word id {w.id}")
            if w.word in words_seen:
                problems.append(f"{where}: duplicate word {w.word}")
            word_ids.add(w.id)
            words_seen.add(w.word)
        content.words.append(words)

    return content, problems


def _bucket(difficulty: int) -> str:
    return "easy" if difficulty <= 2 else "medium" if difficulty == 3 else "hard"


def _stats(data: ChapterFile) -> None:
    qs = data.questions
    n = len(qs) or 1

    def share(counter: Counter[str]) -> str:
        return ", ".join(f"{k} {v} ({100 * v // n}%)" for k, v in counter.most_common())

    where = f"questions/{data.subject}/{data.chapter.slug}.yaml"
    print(f"\n{where}: {len(qs)} questions, {sum(q.battle for q in qs)} battle")
    print(f"  difficulty: {share(Counter(_bucket(q.difficulty) for q in qs))}")
    print(f"  category:   {share(Counter(q.category.value for q in qs))}")
    print(f"  format:     {share(Counter(q.format.value for q in qs))}")
    print(f"  answer:     {share(Counter('ABCD'[q.answer] for q in qs))}")
    print(f"  diagrams:   {sum(bool(q.diagram) for q in qs)}")
    per_topic = Counter(q.topic for q in qs)
    for t in data.chapter.topics:
        print(f"  {t.slug}: {per_topic[t.slug]}")


def main(argv: list[str] | None = None) -> int:
    args = sys.argv[1:] if argv is None else argv
    only = {Path(a).resolve() for a in args if a != "--stats"} or None
    content, problems = load(ROOT, only)
    if "--stats" in args:
        for chapter in content.chapters:
            _stats(chapter)
    for problem in problems:
        print(f"✗ {problem}")
    totals = Counter(c.subject for c in content.chapters for _ in c.questions)
    categories = Counter(
        q.category.value
        for group in (
            [q for c in content.chapters for q in c.questions],
            [q for f in content.passages for p in f.passages for q in p.questions],
        )
        for q in group
    )
    passage_questions = sum(len(p.questions) for f in content.passages for p in f.passages)
    words = sum(len(f.words) for f in content.words)
    summary = ", ".join(f"{s}: {n}" for s, n in sorted(totals.items())) or "no questions"
    print(
        f"{sum(totals.values())} chapter questions ({summary}), "
        f"{passage_questions} passage questions, {words} words."
    )
    if categories:
        print("Categories: " + ", ".join(f"{c}: {n}" for c, n in sorted(categories.items())) + ".")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
