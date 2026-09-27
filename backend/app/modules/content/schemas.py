"""Response bodies for the catalog, questions, search and passages (``docs/api-learn.md``)."""

import uuid

from app.core.schemas import ApiModel


class NamedRef(ApiModel):
    slug: str
    name: str


class TopicOut(ApiModel):
    slug: str
    name: str
    question_count: int


class ChapterOut(ApiModel):
    slug: str
    name: str
    order: int
    question_count: int
    battle_ready: bool  # enough battle questions (7) to be offered for battles
    topics: list[TopicOut]


class SubjectOut(ApiModel):
    slug: str
    name: str
    tone: str
    icon: str
    question_count: int
    chapters: list[ChapterOut]


class CatalogOut(ApiModel):
    goal: str
    version: str
    subjects: list[SubjectOut]


class OptionOut(ApiModel):
    id: int  # the option's position as authored
    text: str


class QuestionOut(ApiModel):
    """A question with its answer key, as practice serves it."""

    ref: str
    stem: str
    options: list[OptionOut]
    answer: int  # the ``id`` of the correct option
    explanation: str
    difficulty: int
    category: str
    chapter: NamedRef | None
    topic: NamedRef | None
    bookmarked: bool


class QuestionSummaryOut(ApiModel):
    """A question in a list (search results): no options or answer."""

    ref: str
    stem: str
    subject: str
    chapter: NamedRef | None
    topic: NamedRef | None


class SearchOut(ApiModel):
    items: list[QuestionSummaryOut]


class PassageItemOut(ApiModel):
    id: uuid.UUID
    title: str
    subject: str
    chapter: NamedRef | None
    difficulty: int
    question_count: int
    done: bool  # every question of it answered at least once


class PassagesOut(ApiModel):
    items: list[PassageItemOut]
