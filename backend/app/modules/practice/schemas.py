"""Request and response bodies for practice sessions, progress, bookmarks and reviews."""

import uuid
from datetime import datetime
from typing import Annotated, Literal

from pydantic import AwareDatetime, Field, StringConstraints, model_validator

from app.core.schemas import ApiModel, Lax, field_error
from app.modules.coach.schemas import TipOut
from app.modules.content.schemas import QuestionOut, QuestionSummaryOut

ModeName = Literal["chapter", "topic", "category", "review", "bookmarks", "challenge", "passage"]
CategoryName = Literal["concept", "numerical", "factual", "application"]
Slug = Annotated[str, StringConstraints(min_length=1, max_length=64)]


class SessionIn(ApiModel):
    """``POST /v1/practice/sessions``. Which fields apply depends on ``mode``."""

    mode: ModeName
    subject: Slug | None = None
    chapters: list[Slug] = Field(default_factory=list, max_length=30)
    topic: Slug | None = None
    category: CategoryName | None = None
    count: int = Field(default=10, ge=5, le=50)
    difficulty: Literal["mixed", "easy", "medium", "hard"] = "mixed"
    timed: bool = False
    per_question_s: Literal[20, 30, 45, 60] | None = None
    time_limit_s: Literal[300, 600, 900, 1800, 3600] | None = None
    marking: Literal["none", "neet"] = "none"
    unseen_only: bool = False
    passage_id: Lax[uuid.UUID] | None = None


class PassageOut(ApiModel):
    id: uuid.UUID
    title: str
    body: str


class SessionQuestionOut(QuestionOut):
    position: int  # from 1


class SessionOut(ApiModel):
    session_id: uuid.UUID
    mode: str
    title: str
    feedback: Literal["instant", "end"]  # challenge shows answers at the end
    created_at: datetime
    expires_at: datetime
    per_question_ms: int | None
    time_limit_ms: int | None
    marking: str
    short: bool  # fewer questions matched than were asked for
    passage: PassageOut | None
    questions: list[SessionQuestionOut]


class AnswerStateOut(ApiModel):
    position: int
    selected_option: int | None
    outcome: str
    time_ms: int


class SessionDetailOut(SessionOut):
    """``GET /v1/practice/sessions/{id}``: the session plus what has been answered."""

    answers: list[AnswerStateOut]
    finished: bool


ClientAnswerId = Annotated[str, StringConstraints(pattern=r"^[A-Za-z0-9_-]{1,64}$")]


class AnswerIn(ApiModel):
    client_answer_id: ClientAnswerId
    ref: Annotated[str, StringConstraints(max_length=64)]
    position: int = Field(ge=1, le=50)
    selected_option: int | None = Field(default=None, ge=0, le=3)  # an option ``id``
    skipped: bool = False
    timed_out: bool = False
    time_ms: int  # clamped by the server
    answer_changes: int = Field(default=0, ge=0)
    answered_at: Lax[AwareDatetime]  # with a timezone offset or Z

    @model_validator(mode="after")
    def _one_kind_of_answer(self) -> "AnswerIn":
        kinds = (self.selected_option is not None) + self.skipped + self.timed_out
        if kinds != 1:
            raise field_error("Send a selected option, or mark the answer skipped or timed out.")
        return self


class AnswersIn(ApiModel):
    answers: Annotated[list[AnswerIn], Field(min_length=1, max_length=50)]


class AnswerResultOut(ApiModel):
    client_answer_id: str
    status: Literal["accepted", "duplicate", "rejected"]
    outcome: str | None  # for accepted answers, and duplicates of a recorded one
    reason: Literal["unknown_question", "position_mismatch", "session_expired", "time_up"] | None


class XpOut(ApiModel):
    delta: int
    total: int
    level: int
    into_level: int
    for_next: int  # the size of the current level
    capped: bool  # the daily practice XP cap cut this award
    resets_at: datetime | None  # when the cap resets (next midnight in India), if capped


class AnswersOut(ApiModel):
    results: list[AnswerResultOut]
    xp: XpOut | None


class TopicResultOut(ApiModel):
    slug: str
    name: str
    answered: int
    correct: int


class FinishOut(ApiModel):
    session_id: uuid.UUID
    answered: int
    correct: int
    skipped: int
    time_ms: int
    score: int | None  # only with ``marking: neet`` (+4 / -1)
    max_score: int | None
    topics: list[TopicResultOut]
    xp: XpOut | None
    tip: TipOut | None


class ChapterProgressOut(ApiModel):
    slug: str
    answered: int
    correct: int
    seen: int
    label: Literal["strong", "needs_work"] | None


class SubjectProgressOut(ApiModel):
    slug: str
    answered: int
    correct: int
    chapters: list[ChapterProgressOut]


class ContinueOut(ApiModel):
    session_id: uuid.UUID
    title: str
    answered: int
    count: int


class ProgressOut(ApiModel):
    subjects: list[SubjectProgressOut]
    reviews_due: int
    continue_: ContinueOut | None = Field(serialization_alias="continue")
    tip: TipOut | None


class HistoryItemOut(ApiModel):
    session_id: uuid.UUID
    mode: str
    title: str
    created_at: datetime
    finished_at: datetime | None
    answered: int
    correct: int
    score: int | None  # only with ``marking: neet``
    max_score: int | None


class HistoryOut(ApiModel):
    items: list[HistoryItemOut]
    next_cursor: str | None


class BookmarkOut(QuestionSummaryOut):
    bookmarked_at: datetime


class BookmarksOut(ApiModel):
    items: list[BookmarkOut]
    next_cursor: str | None


class ReviewSummaryOut(ApiModel):
    due: int
    total: int
