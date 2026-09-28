"""Every ORM model, imported so ``Base.metadata`` is complete (Alembic autogenerate uses it)."""

import re

from app.core.db import Base
from app.modules.analytics.models import AnalyticsEvent
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
from app.modules.economy.models import CoinHold, LedgerEntry, Wallet
from app.modules.feedback.models import Feedback
from app.modules.matches.models import (
    HeadToHead,
    Match,
    MatchAnswer,
    MatchParticipant,
    MatchQuestion,
)
from app.modules.moderation.models import ModerationAction, UserReport
from app.modules.notifications.models import Notification, PushToken
from app.modules.outbox.models import OutboxMessage
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
from app.modules.progression.models import (
    Achievement,
    DailyMission,
    MissionDef,
    ProgressEventDedupe,
    StreakDay,
    UserAchievement,
    UserProgress,
    UserStreak,
    XpEvent,
)
from app.modules.ratings.models import Rating, RatingHistory
from app.modules.social.models import ActivityEvent, Block, FriendRequest, Friendship
from app.modules.system.models import AppConfig, AuditLog
from app.modules.users.models import User, UserSettings

# Monthly partitions of question_attempts are created at runtime by ensure_attempt_partitions();
# they are not models, so migration autogenerate and the drift check skip them.
_ATTEMPT_PARTITION = re.compile(r"question_attempts_(default|\d{4}_\d{2})")


def include_name(name: str | None, type_: str, _parent_names: object) -> bool:
    """Alembic ``include_name`` hook: everything except runtime-created partitions."""
    return not (type_ == "table" and name is not None and _ATTEMPT_PARTITION.fullmatch(name))


__all__ = [
    "Achievement",
    "ActivityEvent",
    "AnalyticsEvent",
    "AppConfig",
    "AttemptKey",
    "AuditLog",
    "AuthIdentity",
    "Base",
    "Block",
    "Chapter",
    "CoinHold",
    "DailyMission",
    "DeviceSession",
    "ExamGoal",
    "Feedback",
    "FriendRequest",
    "Friendship",
    "GoalSubject",
    "HeadToHead",
    "LedgerEntry",
    "Match",
    "MatchAnswer",
    "MatchParticipant",
    "MatchQuestion",
    "MissionDef",
    "ModerationAction",
    "Notification",
    "OutboxMessage",
    "Passage",
    "PracticeAnswer",
    "PracticeSession",
    "ProgressEventDedupe",
    "PushToken",
    "Question",
    "QuestionAttempt",
    "QuestionReport",
    "QuestionStats",
    "Rating",
    "RatingHistory",
    "RefreshToken",
    "StreakDay",
    "Subject",
    "Topic",
    "User",
    "UserAchievement",
    "UserCategoryStats",
    "UserChapterStats",
    "UserDailyStats",
    "UserProgress",
    "UserQuestion",
    "UserReport",
    "UserSettings",
    "UserStreak",
    "UserTip",
    "UserTopicStats",
    "Wallet",
    "WordPuzzle",
    "XpEvent",
    "include_name",
]
