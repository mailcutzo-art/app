"""Progression: XP per game kind, daily missions, streaks and achievements.

Revision ID: 0007
Revises: 0004
Create Date: 2026-09-28 12:00:00+00:00

Seeds the mission and achievement catalogues. ``xp_events`` gains ``game_kind`` (for the
per-kind daily caps) and ``total_after`` (so a replayed award reports the same level change).
"""

from collections.abc import Sequence
from typing import Any

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0007"
down_revision: str | None = "0004"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

GAME_KINDS = "('quick_rated', 'quick_casual', 'tournament', 'friend', 'bot', 'group')"
SLOTS = "('practice', 'play', 'review')"
MISSION_KINDS = (
    "('practice_answer', 'review_answer', 'chapter_answer', 'rated_game', 'battle_finished')"
)
METRICS = (
    "('battles', 'wins', 'perfect_battles', 'answers', 'review_answers', 'streak', 'level', "
    "'tournaments', 'podiums', 'tournament_wins', 'friends', 'mission_days')"
)

# id, slot, kind, target, xp, title, generate, sort
MISSION_DEFS = [
    ("practice_10", "practice", "practice_answer", 10, 20, "Answer 10 practice questions", True),
    ("practice_20", "practice", "practice_answer", 20, 20, "Answer 20 practice questions", True),
    ("practice_30", "practice", "practice_answer", 30, 20, "Answer 30 practice questions", True),
    ("play_rated_1", "play", "rated_game", 1, 25, "Play 1 rated battle or tournament game", True),
    ("play_any_1", "play", "battle_finished", 1, 25, "Finish 1 battle of any kind", False),
    ("review_5", "review", "review_answer", 5, 30, "Review 5 weak questions", True),
    (
        "weak_chapter_10",
        "review",
        "chapter_answer",
        10,
        30,
        "Answer 10 questions in {chapter}",
        True,
    ),
    (
        "any_chapter_10",
        "review",
        "chapter_answer",
        10,
        30,
        "Answer 10 questions in any chapter",
        True,
    ),
]

# id, metric, target, title, description, icon, coins
ACHIEVEMENTS = [
    (
        "first_battle",
        "battles",
        1,
        "First battle",
        "Finish your first battle",
        "swords",
        10,
    ),
    (
        "first_win",
        "wins",
        1,
        "First win",
        "Win a battle against another player",
        "trophy",
        20,
    ),
    (
        "wins_10",
        "wins",
        10,
        "Ten wins",
        "Win 10 battles against other players",
        "trophy",
        50,
    ),
    (
        "wins_50",
        "wins",
        50,
        "Battle veteran",
        "Win 50 battles against other players",
        "trophy",
        150,
    ),
    (
        "perfect_battle",
        "perfect_battles",
        1,
        "Perfect battle",
        "Answer every question right in a battle",
        "star",
        50,
    ),
    (
        "questions_100",
        "answers",
        100,
        "Century",
        "Answer 100 questions",
        "book",
        20,
    ),
    (
        "questions_1000",
        "answers",
        1000,
        "Thousand strong",
        "Answer 1,000 questions",
        "book",
        100,
    ),
    (
        "review_50",
        "review_answers",
        50,
        "Review regular",
        "Answer 50 review questions",
        "refresh",
        30,
    ),
    (
        "streak_7",
        "streak",
        7,
        "Week streak",
        "Keep a 7-day streak",
        "flame",
        30,
    ),
    (
        "streak_30",
        "streak",
        30,
        "Month streak",
        "Keep a 30-day streak",
        "flame",
        100,
    ),
    (
        "level_10",
        "level",
        10,
        "Level 10",
        "Reach level 10",
        "level",
        50,
    ),
    (
        "level_25",
        "level",
        25,
        "Level 25",
        "Reach level 25",
        "level",
        150,
    ),
    (
        "first_tournament",
        "tournaments",
        1,
        "Tournament debut",
        "Finish your first tournament",
        "arena",
        20,
    ),
    (
        "tournament_podium",
        "podiums",
        1,
        "On the podium",
        "Finish in the top 3 of a tournament",
        "medal",
        100,
    ),
    (
        "tournament_champion",
        "tournament_wins",
        1,
        "Champion",
        "Win a tournament",
        "crown",
        200,
    ),
    (
        "friend_made",
        "friends",
        1,
        "Study buddy",
        "Make your first friend",
        "friends",
        10,
    ),
    (
        "mission_days_7",
        "mission_days",
        7,
        "Mission master",
        "Finish all daily missions on 7 days",
        "mission",
        50,
    ),
]


def _timestamp(name: str) -> sa.Column[Any]:
    return sa.Column(
        name, sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False
    )


def _counter(name: str, type_: sa.types.TypeEngine[Any] | None = None) -> sa.Column[Any]:
    return sa.Column(name, type_ or sa.Integer(), server_default=sa.text("0"), nullable=False)


def _user_fk(table: str) -> sa.ForeignKeyConstraint:
    return sa.ForeignKeyConstraint(
        ["user_id"], ["users.id"], name=op.f(f"fk_{table}_user_id_users"), ondelete="CASCADE"
    )


def upgrade() -> None:
    _extend_xp_events()
    _create_missions()
    _create_streaks()
    _create_achievements()


def _extend_xp_events() -> None:
    op.add_column("xp_events", sa.Column("game_kind", sa.Text(), nullable=True))
    op.add_column("xp_events", sa.Column("total_after", sa.BigInteger(), nullable=True))
    op.create_check_constraint(
        op.f("ck_xp_events_game_kind"), "xp_events", f"game_kind IN {GAME_KINDS}"
    )
    op.create_index("ix_xp_events_user_day", "xp_events", ["user_id", "ist_day"])


def _create_missions() -> None:
    defs = op.create_table(
        "mission_defs",
        sa.Column("id", sa.Text(), nullable=False),
        sa.Column("slot", sa.Text(), nullable=False),
        sa.Column("kind", sa.Text(), nullable=False),
        sa.Column("target", sa.Integer(), nullable=False),
        sa.Column("xp", sa.Integer(), nullable=False),
        sa.Column("title", sa.Text(), nullable=False),
        sa.Column("generate", sa.Boolean(), nullable=False),
        sa.Column("sort", sa.SmallInteger(), nullable=False),
        sa.CheckConstraint(f"slot IN {SLOTS}", name=op.f("ck_mission_defs_slot")),
        sa.CheckConstraint(f"kind IN {MISSION_KINDS}", name=op.f("ck_mission_defs_kind")),
        sa.CheckConstraint("target > 0", name=op.f("ck_mission_defs_target")),
        sa.CheckConstraint("xp >= 0", name=op.f("ck_mission_defs_xp")),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_mission_defs")),
    )
    op.bulk_insert(
        defs,
        [
            {
                "id": id_,
                "slot": slot,
                "kind": kind,
                "target": target,
                "xp": xp,
                "title": title,
                "generate": generate,
                "sort": sort,
            }
            for sort, (id_, slot, kind, target, xp, title, generate) in enumerate(MISSION_DEFS, 1)
        ],
    )
    op.create_table(
        "daily_missions",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("ist_day", sa.Date(), nullable=False),
        sa.Column("slot", sa.Text(), nullable=False),
        sa.Column("def_id", sa.Text(), nullable=False),
        sa.Column("kind", sa.Text(), nullable=False),
        sa.Column("title", sa.Text(), nullable=False),
        sa.Column("target", sa.Integer(), nullable=False),
        sa.Column("xp", sa.Integer(), nullable=False),
        _counter("progress"),
        sa.Column(
            "params",
            postgresql.JSONB(astext_type=sa.Text()),
            server_default=sa.text("'{}'"),
            nullable=False,
        ),
        sa.Column("done_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("swapped", sa.Boolean(), server_default=sa.text("false"), nullable=False),
        _timestamp("created_at"),
        sa.CheckConstraint(f"slot IN {SLOTS}", name=op.f("ck_daily_missions_slot")),
        sa.CheckConstraint(f"kind IN {MISSION_KINDS}", name=op.f("ck_daily_missions_kind")),
        sa.CheckConstraint(
            "progress BETWEEN 0 AND target", name=op.f("ck_daily_missions_progress")
        ),
        _user_fk("daily_missions"),
        sa.ForeignKeyConstraint(
            ["def_id"], ["mission_defs.id"], name=op.f("fk_daily_missions_def_id_mission_defs")
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_daily_missions")),
        sa.UniqueConstraint(
            "user_id", "ist_day", "slot", name=op.f("uq_daily_missions_user_id_ist_day_slot")
        ),
    )
    op.create_table(
        "mission_event_dedupe",
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("kind", sa.Text(), nullable=False),
        sa.Column("event_id", sa.Text(), nullable=False),
        _timestamp("created_at"),
        _user_fk("mission_event_dedupe"),
        sa.PrimaryKeyConstraint(
            "user_id", "kind", "event_id", name=op.f("pk_mission_event_dedupe")
        ),
    )
    op.create_index(
        op.f("ix_mission_event_dedupe_created_at"), "mission_event_dedupe", ["created_at"]
    )


def _create_streaks() -> None:
    op.create_table(
        "user_streaks",
        sa.Column("user_id", sa.Uuid(), nullable=False),
        _counter("current"),
        _counter("best"),
        _counter("freezes", sa.SmallInteger()),
        sa.Column("started_on", sa.Date(), nullable=True),
        sa.Column("last_day", sa.Date(), nullable=True),
        sa.Column("checked_through", sa.Date(), nullable=True),
        _timestamp("updated_at"),
        sa.CheckConstraint("current >= 0", name=op.f("ck_user_streaks_current")),
        sa.CheckConstraint("best >= current", name=op.f("ck_user_streaks_best")),
        sa.CheckConstraint("freezes BETWEEN 0 AND 2", name=op.f("ck_user_streaks_freezes")),
        _user_fk("user_streaks"),
        sa.PrimaryKeyConstraint("user_id", name=op.f("pk_user_streaks")),
    )
    op.create_table(
        "streak_days",
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("day", sa.Date(), nullable=False),
        _counter("battles_finished"),
        sa.Column("state", sa.Text(), nullable=True),
        sa.CheckConstraint("state IN ('active', 'frozen')", name=op.f("ck_streak_days_state")),
        sa.CheckConstraint("battles_finished >= 0", name=op.f("ck_streak_days_battles_finished")),
        _user_fk("streak_days"),
        sa.PrimaryKeyConstraint("user_id", "day", name=op.f("pk_streak_days")),
    )


def _create_achievements() -> None:
    table = op.create_table(
        "achievements",
        sa.Column("id", sa.Text(), nullable=False),
        sa.Column("metric", sa.Text(), nullable=False),
        sa.Column("target", sa.Integer(), nullable=False),
        sa.Column("title", sa.Text(), nullable=False),
        sa.Column("description", sa.Text(), nullable=False),
        sa.Column("icon", sa.Text(), nullable=False),
        sa.Column("coins", sa.Integer(), nullable=False),
        sa.Column("sort", sa.SmallInteger(), nullable=False),
        sa.CheckConstraint(f"metric IN {METRICS}", name=op.f("ck_achievements_metric")),
        sa.CheckConstraint("target > 0", name=op.f("ck_achievements_target")),
        sa.CheckConstraint("coins BETWEEN 0 AND 200", name=op.f("ck_achievements_coins")),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_achievements")),
    )
    op.bulk_insert(
        table,
        [
            {
                "id": id_,
                "metric": metric,
                "target": target,
                "title": title,
                "description": description,
                "icon": icon,
                "coins": coins,
                "sort": sort,
            }
            for sort, (id_, metric, target, title, description, icon, coins) in enumerate(
                ACHIEVEMENTS, 1
            )
        ],
    )
    op.create_table(
        "user_achievements",
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("achievement_id", sa.Text(), nullable=False),
        _counter("progress", sa.BigInteger()),
        sa.Column("earned_at", sa.DateTime(timezone=True), nullable=True),
        _timestamp("updated_at"),
        sa.CheckConstraint("progress >= 0", name=op.f("ck_user_achievements_progress")),
        _user_fk("user_achievements"),
        sa.ForeignKeyConstraint(
            ["achievement_id"],
            ["achievements.id"],
            name=op.f("fk_user_achievements_achievement_id_achievements"),
        ),
        sa.PrimaryKeyConstraint("user_id", "achievement_id", name=op.f("pk_user_achievements")),
    )


def downgrade() -> None:
    for table in (
        "user_achievements",
        "achievements",
        "streak_days",
        "user_streaks",
        "mission_event_dedupe",
        "daily_missions",
        "mission_defs",
    ):
        op.drop_table(table)
    op.drop_index("ix_xp_events_user_day", table_name="xp_events")
    op.drop_constraint(op.f("ck_xp_events_game_kind"), "xp_events", type_="check")
    op.drop_column("xp_events", "total_after")
    op.drop_column("xp_events", "game_kind")
