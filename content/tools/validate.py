"""Validate starter content (see docs/content-format.md).

Run from the repo root:

    uv run --with pyyaml --with pydantic python content/tools/validate.py

Exits non-zero and lists every problem found.
"""

from __future__ import annotations

import re
import sys
from collections import Counter
from pathlib import Path
from typing import Annotated

import yaml
from pydantic import BaseModel, ConfigDict, Field, ValidationError, field_validator

ROOT = Path(__file__).resolve().parents[1]
MIN_BATTLE_PER_CHAPTER = 15
MAX_ANSWER_SHARE = 0.45
LATEX = re.compile(r"\\[a-zA-Z]+|\$")
SLUG = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")
WORD = re.compile(r"^[A-Z]{3,12}$")

Text = Annotated[str, Field(min_length=1)]


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


class Question(BaseModel):
    model_config = ConfigDict(extra="forbid")

    id: Text
    difficulty: int = Field(ge=1, le=5)
    stem: Annotated[str, Field(min_length=10, max_length=300)]
    options: list[Annotated[str, Field(min_length=1, max_length=120)]]
    answer: int = Field(ge=0, le=3)
    explanation: Annotated[str, Field(min_length=10, max_length=1200)]
    tags: list[str] = []
    battle: bool = False

    @field_validator("options")
    @classmethod
    def _four_distinct(cls, options: list[str]) -> list[str]:
        if len(options) != 4:
            raise ValueError(f"expected 4 options, got {len(options)}")
        if len({_normalize(o) for o in options}) != 4:
            raise ValueError("options must all be different")
        return options


class PassageQuestion(Question):
    battle: bool = False


class Chapter(BaseModel):
    model_config = ConfigDict(extra="forbid")

    slug: Text
    name: Text
    order: int = Field(ge=1)


class ChapterFile(BaseModel):
    model_config = ConfigDict(extra="forbid")

    subject: Text
    chapter: Chapter
    questions: list[Question]


class Passage(BaseModel):
    model_config = ConfigDict(extra="forbid")

    id: Text
    title: Text
    difficulty: int = Field(ge=1, le=5)
    body: Annotated[str, Field(min_length=300, max_length=2400)]
    questions: list[PassageQuestion] = Field(min_length=3, max_length=5)


class PassageFile(BaseModel):
    model_config = ConfigDict(extra="forbid")

    subject: Text
    passages: list[Passage]


class Word(BaseModel):
    model_config = ConfigDict(extra="forbid")

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


class WordFile(BaseModel):
    model_config = ConfigDict(extra="forbid")

    subject: Text
    words: list[Word]


def _load(path: Path) -> object:
    with path.open(encoding="utf-8") as f:
        return yaml.safe_load(f)


def main() -> int:
    problems: list[str] = []
    catalog = _load(ROOT / "catalog.yaml")
    subjects = {s["slug"] for s in catalog["subjects"]}  # type: ignore[index]

    ids: dict[str, str] = {}
    stems: dict[str, str] = {}
    totals: Counter[str] = Counter()

    def check_question(q: Question, where: str) -> None:
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

    for path in sorted((ROOT / "questions").glob("*/*.yaml")):
        where = str(path.relative_to(ROOT))
        try:
            data = ChapterFile.model_validate(_load(path))
        except ValidationError as e:
            problems.append(f"{where}: {e}")
            continue
        if data.subject not in subjects:
            problems.append(f"{where}: unknown subject {data.subject}")
        if data.subject != path.parent.name:
            problems.append(f"{where}: subject {data.subject} doesn't match folder")
        if not SLUG.match(data.chapter.slug):
            problems.append(f"{where}: bad chapter slug {data.chapter.slug}")
        prefix = f"{data.subject[:3]}-"
        for q in data.questions:
            check_question(q, where)
            if not re.match(rf"^{prefix}[a-z0-9]+-\d{{3}}$", q.id):
                problems.append(f"{where}: id {q.id} should look like {prefix}<chap>-<nnn>")
            if q.battle and len(q.stem) > 180:
                problems.append(f"{where}: {q.id} is too long for a battle question")
        battle = sum(q.battle for q in data.questions)
        if battle < MIN_BATTLE_PER_CHAPTER:
            problems.append(
                f"{where}: only {battle} battle questions (need {MIN_BATTLE_PER_CHAPTER})"
            )
        answers = Counter(q.answer for q in data.questions)
        if data.questions and max(answers.values()) / len(data.questions) > MAX_ANSWER_SHARE:
            problems.append(f"{where}: answers cluster on one position {dict(answers)}")
        totals[data.subject] += len(data.questions)

    for path in sorted((ROOT / "passages").glob("*.yaml")):
        where = str(path.relative_to(ROOT))
        try:
            passages = PassageFile.model_validate(_load(path))
        except ValidationError as e:
            problems.append(f"{where}: {e}")
            continue
        for passage in passages.passages:
            for q in passage.questions:
                check_question(q, where)

    word_ids: set[str] = set()
    words_seen: set[str] = set()
    for path in sorted((ROOT / "words").glob("*.yaml")):
        where = str(path.relative_to(ROOT))
        try:
            words = WordFile.model_validate(_load(path))
        except ValidationError as e:
            problems.append(f"{where}: {e}")
            continue
        for w in words.words:
            if w.id in word_ids:
                problems.append(f"{where}: duplicate word id {w.id}")
            if w.word in words_seen:
                problems.append(f"{where}: duplicate word {w.word}")
            word_ids.add(w.id)
            words_seen.add(w.word)

    for problem in problems:
        print(f"✗ {problem}")
    summary = ", ".join(f"{s}: {n}" for s, n in sorted(totals.items())) or "no questions"
    print(f"{len(ids)} questions checked ({summary}); {len(words_seen)} words.")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
