"""Notification kinds (docs/api-play.md, "Inbox and push") and the settings that govern them.

Each kind belongs to a preference category the player can switch off in Settings
(``invites``, ``tournaments``, ``friends``, ``missions``, ``streaks``), or to none: coins,
match outcomes and account notices always push. Preferences only affect push; everything is
kept in the inbox.
"""

from enum import StrEnum


class NotificationKind(StrEnum):
    # Invites and friends
    INVITE = "invite"
    FRIEND_REQUEST = "friend_request"
    FRIEND_ACCEPTED = "friend_accepted"
    # Tournaments
    TOURNAMENT_REMINDER = "tournament_reminder"
    TOURNAMENT_CHECK_IN = "tournament_check_in"
    TOURNAMENT_ROUND = "tournament_round"
    TOURNAMENT_AT_RISK = "tournament_at_risk"
    TOURNAMENT_RESULT = "tournament_result"
    TOURNAMENT_CANCELLED = "tournament_cancelled"
    TOURNAMENT_WITHDRAWN = "tournament_withdrawn"
    # Coins and matches
    REFUND = "refund"
    PRIZE = "prize"
    MATCH_FORFEIT = "match_forfeit"
    MATCH_ABORTED = "match_aborted"
    MATCH_SETTLED = "match_settled"
    # Progress
    MISSION_DONE = "mission_done"
    LEVEL_UP = "level_up"
    ACHIEVEMENT = "achievement"
    RANK_MILESTONE = "rank_milestone"
    WEEKLY_RESULT = "weekly_result"
    STREAK_RISK = "streak_risk"
    STREAK_FREEZE_USED = "streak_freeze_used"
    STREAK_LOST = "streak_lost"
    # Other
    QUESTION_REPORT = "question_report"
    ACCOUNT = "account"


class Category(StrEnum):
    """Push preference categories, also the Android notification channels."""

    INVITES = "invites"
    TOURNAMENTS = "tournaments"
    FRIENDS = "friends"
    MISSIONS = "missions"  # missions and other progress (levels, achievements, ranks)
    STREAKS = "streaks"


# Channel for kinds outside every category (Android needs one for each notification).
ALWAYS_ON_CHANNEL = "general"

K = NotificationKind
CATEGORY: dict[NotificationKind, Category | None] = {
    K.INVITE: Category.INVITES,
    K.FRIEND_REQUEST: Category.FRIENDS,
    K.FRIEND_ACCEPTED: Category.FRIENDS,
    K.TOURNAMENT_REMINDER: Category.TOURNAMENTS,
    K.TOURNAMENT_CHECK_IN: Category.TOURNAMENTS,
    K.TOURNAMENT_ROUND: Category.TOURNAMENTS,
    K.TOURNAMENT_AT_RISK: Category.TOURNAMENTS,
    K.TOURNAMENT_RESULT: Category.TOURNAMENTS,
    K.TOURNAMENT_CANCELLED: Category.TOURNAMENTS,
    K.TOURNAMENT_WITHDRAWN: Category.TOURNAMENTS,
    K.REFUND: None,
    K.PRIZE: None,
    K.MATCH_FORFEIT: None,
    K.MATCH_ABORTED: None,
    K.MATCH_SETTLED: None,
    K.MISSION_DONE: Category.MISSIONS,
    K.LEVEL_UP: Category.MISSIONS,
    K.ACHIEVEMENT: Category.MISSIONS,
    K.RANK_MILESTONE: Category.MISSIONS,
    K.WEEKLY_RESULT: Category.MISSIONS,
    K.STREAK_RISK: Category.STREAKS,
    K.STREAK_FREEZE_USED: Category.STREAKS,
    K.STREAK_LOST: Category.STREAKS,
    K.QUESTION_REPORT: None,
    K.ACCOUNT: None,
}

# Kinds that stay in the inbox without a push unless the caller asks for one: the player is
# looking at the app when they happen (a late settlement, an abort they just saw).
INBOX_ONLY = frozenset({K.MATCH_SETTLED, K.MATCH_ABORTED, K.QUESTION_REPORT})


def category_of(kind: NotificationKind) -> Category | None:
    return CATEGORY[kind]


def channel_of(kind: NotificationKind) -> str:
    category = CATEGORY[kind]
    return category.value if category is not None else ALWAYS_ON_CHANNEL


def pushes_by_default(kind: NotificationKind) -> bool:
    return kind not in INBOX_ONLY
