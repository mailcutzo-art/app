"""Every ORM model, imported so ``Base.metadata`` is complete (Alembic autogenerate uses it)."""

import re

from app.core.db import Base
from app.modules.auth.models import AuthIdentity, DeviceSession, RefreshToken
from app.modules.coach.models import UserTip
from app.modules.content.models import (
    Chapter,
    ExamGoal,
    GoalSubject,
    Passage,
    Question,
    QuestionReport,
    QuestionStats,
    Subject,
    Topic,
    WordPuzzle,
)
from app.modules.practice.models import (
    AttemptKey,
    PracticeAnswer,
    PracticeSession,
    QuestionAttempt,
    UserCategoryStats,
    UserChapterStats,
    UserDailyStats,
    UserQuestion,
    UserTopicStats,
)
from app.modules.progression.models import UserProgress, XpEvent
from app.modules.system.models import AppConfig, AuditLog
from app.modules.users.models import User

# Monthly partitions of question_attempts are created at runtime by ensure_attempt_partitions();
# they are not models, so migration autogenerate and the drift check skip them.
_ATTEMPT_PARTITION = re.compile(r"question_attempts_(default|\d{4}_\d{2})")


def include_name(name: str | None, type_: str, _parent_names: object) -> bool:
    """Alembic ``include_name`` hook: everything except runtime-created partitions."""
    return not (type_ == "table" and name is not None and _ATTEMPT_PARTITION.fullmatch(name))


__all__ = [
    "AppConfig",
    "AttemptKey",
    "AuditLog",
    "AuthIdentity",
    "Base",
    "Chapter",
    "DeviceSession",
    "ExamGoal",
    "GoalSubject",
    "Passage",
    "PracticeAnswer",
    "PracticeSession",
    "Question",
    "QuestionAttempt",
    "QuestionReport",
    "QuestionStats",
    "RefreshToken",
    "Subject",
    "Topic",
    "User",
    "UserCategoryStats",
    "UserChapterStats",
    "UserDailyStats",
    "UserProgress",
    "UserQuestion",
    "UserTip",
    "UserTopicStats",
    "WordPuzzle",
    "XpEvent",
    "include_name",
]
