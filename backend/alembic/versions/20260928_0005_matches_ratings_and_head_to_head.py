"""Live games in Postgres: matches, players, questions and answers; ratings and head-to-head.

Revision ID: 0005
Revises: 0003
Create Date: 2026-09-28 08:44:15+00:00

Only tables the realtime engine owns. Coins, holds and notifications live in their own
migration; settlement reaches them through ports (``app.modules.matches.ports``).
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0005"
down_revision: str | None = "0003"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "h2h",
        sa.Column("lo", sa.Uuid(), nullable=False),
        sa.Column("hi", sa.Uuid(), nullable=False),
        sa.Column("lo_wins", sa.Integer(), server_default=sa.text("0"), nullable=False),
        sa.Column("hi_wins", sa.Integer(), server_default=sa.text("0"), nullable=False),
        sa.Column("draws", sa.Integer(), server_default=sa.text("0"), nullable=False),
        sa.Column("last_played_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint("lo < hi", name=op.f("ck_h2h_order")),
        sa.ForeignKeyConstraint(
            ["hi"], ["users.id"], name=op.f("fk_h2h_hi_users"), ondelete="CASCADE"
        ),
        sa.ForeignKeyConstraint(
            ["lo"], ["users.id"], name=op.f("fk_h2h_lo_users"), ondelete="CASCADE"
        ),
        sa.PrimaryKeyConstraint("lo", "hi", name=op.f("pk_h2h")),
    )
    op.create_index("ix_h2h_hi", "h2h", ["hi"], unique=False)
    op.create_table(
        "matches",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("kind", sa.Text(), nullable=False),
        sa.Column("subject_id", sa.SmallInteger(), nullable=False),
        sa.Column("sources", postgresql.JSONB(astext_type=sa.Text()), nullable=False),
        sa.Column("chapter_ids", postgresql.ARRAY(sa.Integer()), nullable=False),
        sa.Column("status", sa.Text(), server_default="live", nullable=False),
        sa.Column("end_reason", sa.Text(), nullable=True),
        sa.Column("config", postgresql.JSONB(astext_type=sa.Text()), nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.Column("started_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("finished_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("settled_at", sa.DateTime(timezone=True), nullable=True),
        sa.CheckConstraint(
            "end_reason IN ('normal', 'forfeit', 'disconnected', 'no_show', 'ended_by_host',"
            " 'aborted', 'voided')",
            name=op.f("ck_matches_reason"),
        ),
        sa.CheckConstraint(
            "kind IN ('quick_rated', 'quick_casual', 'bot', 'friend', 'group', 'tournament')",
            name=op.f("ck_matches_kind"),
        ),
        sa.CheckConstraint(
            "status IN ('live', 'finished', 'settled', 'aborted', 'voided')",
            name=op.f("ck_matches_status"),
        ),
        sa.ForeignKeyConstraint(
            ["subject_id"], ["subjects.id"], name=op.f("fk_matches_subject_id_subjects")
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_matches")),
    )
    op.create_index(
        "ix_matches_live",
        "matches",
        ["created_at"],
        unique=False,
        postgresql_where=sa.text("status = 'live'"),
    )
    op.create_table(
        "ratings",
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("scope", sa.Text(), nullable=False),
        sa.Column("rating", sa.Double(), server_default=sa.text("1500"), nullable=False),
        sa.Column("rd", sa.Double(), server_default=sa.text("350"), nullable=False),
        sa.Column("volatility", sa.Double(), server_default=sa.text("0.06"), nullable=False),
        sa.Column("games", sa.Integer(), server_default=sa.text("0"), nullable=False),
        sa.Column("last_played_at", sa.DateTime(timezone=True), nullable=True),
        sa.CheckConstraint("games >= 0", name=op.f("ck_ratings_games")),
        sa.CheckConstraint("rd > 0 AND volatility > 0", name=op.f("ck_ratings_positive")),
        sa.ForeignKeyConstraint(
            ["user_id"], ["users.id"], name=op.f("fk_ratings_user_id_users"), ondelete="CASCADE"
        ),
        sa.PrimaryKeyConstraint("user_id", "scope", name=op.f("pk_ratings")),
    )
    op.create_table(
        "match_answers",
        sa.Column("match_id", sa.Uuid(), nullable=False),
        sa.Column("seat", sa.SmallInteger(), nullable=False),
        sa.Column("position", sa.SmallInteger(), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=True),
        sa.Column("option_id", sa.Text(), nullable=True),
        sa.Column("selected_option", sa.SmallInteger(), nullable=True),
        sa.Column("status", sa.Text(), nullable=False),
        sa.Column("is_correct", sa.Boolean(), nullable=False),
        sa.Column("raw_ms", sa.Integer(), nullable=True),
        sa.Column("time_ms", sa.Integer(), nullable=True),
        sa.Column("points", sa.SmallInteger(), server_default=sa.text("0"), nullable=False),
        sa.Column("speed", sa.Text(), nullable=True),
        sa.Column("peer_time_ms", sa.Integer(), nullable=True),
        sa.Column("answered_at", sa.DateTime(timezone=True), nullable=True),
        sa.CheckConstraint(
            "speed IN ('fast', 'slow', 'even')", name=op.f("ck_match_answers_speed")
        ),
        sa.CheckConstraint(
            "status IN ('accepted', 'late', 'too_early', 'timeout')",
            name=op.f("ck_match_answers_status"),
        ),
        sa.CheckConstraint(
            "selected_option BETWEEN 0 AND 3", name=op.f("ck_match_answers_selected_option")
        ),
        sa.ForeignKeyConstraint(
            ["match_id"],
            ["matches.id"],
            name=op.f("fk_match_answers_match_id_matches"),
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["user_id"],
            ["users.id"],
            name=op.f("fk_match_answers_user_id_users"),
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("match_id", "seat", "position", name=op.f("pk_match_answers")),
    )
    op.create_table(
        "match_participants",
        sa.Column("match_id", sa.Uuid(), nullable=False),
        sa.Column("seat", sa.SmallInteger(), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=True),
        sa.Column("is_bot", sa.Boolean(), nullable=False),
        sa.Column("card", postgresql.JSONB(astext_type=sa.Text()), nullable=False),
        sa.Column("result", sa.Text(), nullable=False),
        sa.Column("forfeited", sa.Boolean(), server_default=sa.text("false"), nullable=False),
        sa.Column("score", sa.Integer(), server_default=sa.text("0"), nullable=False),
        sa.Column("correct", sa.Integer(), server_default=sa.text("0"), nullable=False),
        sa.Column("correct_time_ms", sa.Integer(), server_default=sa.text("0"), nullable=False),
        sa.Column("place", sa.SmallInteger(), nullable=True),
        sa.Column("rating_before", sa.Double(), nullable=True),
        sa.Column("rating_after", sa.Double(), nullable=True),
        sa.Column("rating_delta", sa.Integer(), nullable=True),
        sa.Column("coins_delta", sa.Integer(), nullable=True),
        sa.Column("settlement", postgresql.JSONB(astext_type=sa.Text()), nullable=True),
        sa.CheckConstraint(
            "result IN ('win', 'loss', 'draw', 'aborted', 'voided')",
            name=op.f("ck_match_participants_result"),
        ),
        sa.CheckConstraint("is_bot = (user_id IS NULL)", name=op.f("ck_match_participants_bot")),
        sa.ForeignKeyConstraint(
            ["match_id"],
            ["matches.id"],
            name=op.f("fk_match_participants_match_id_matches"),
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["user_id"],
            ["users.id"],
            name=op.f("fk_match_participants_user_id_users"),
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("match_id", "seat", name=op.f("pk_match_participants")),
        sa.UniqueConstraint(
            "match_id", "user_id", name=op.f("uq_match_participants_match_id_user_id")
        ),
    )
    op.create_index(
        "ix_match_participants_user", "match_participants", ["user_id", "match_id"], unique=False
    )
    op.create_table(
        "rating_history",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("match_id", sa.Uuid(), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("scope", sa.Text(), nullable=False),
        sa.Column("rating_before", sa.Double(), nullable=False),
        sa.Column("rd_before", sa.Double(), nullable=False),
        sa.Column("rating_after", sa.Double(), nullable=False),
        sa.Column("rd_after", sa.Double(), nullable=False),
        sa.Column("volatility_after", sa.Double(), nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.ForeignKeyConstraint(
            ["match_id"],
            ["matches.id"],
            name=op.f("fk_rating_history_match_id_matches"),
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["user_id"],
            ["users.id"],
            name=op.f("fk_rating_history_user_id_users"),
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_rating_history")),
        sa.UniqueConstraint(
            "match_id", "user_id", "scope", name=op.f("uq_rating_history_match_id_user_id_scope")
        ),
    )
    op.create_index(
        "ix_rating_history_user_scope",
        "rating_history",
        ["user_id", "scope", "created_at"],
        unique=False,
    )
    op.create_table(
        "match_questions",
        sa.Column("match_id", sa.Uuid(), nullable=False),
        sa.Column("position", sa.SmallInteger(), nullable=False),
        sa.Column("question_id", sa.Uuid(), nullable=False),
        sa.Column("option_map", postgresql.JSONB(astext_type=sa.Text()), nullable=False),
        sa.ForeignKeyConstraint(
            ["match_id"],
            ["matches.id"],
            name=op.f("fk_match_questions_match_id_matches"),
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["question_id"], ["questions.id"], name=op.f("fk_match_questions_question_id_questions")
        ),
        sa.PrimaryKeyConstraint("match_id", "position", name=op.f("pk_match_questions")),
    )


def downgrade() -> None:
    op.drop_table("match_questions")
    op.drop_index("ix_rating_history_user_scope", table_name="rating_history")
    op.drop_table("rating_history")
    op.drop_index("ix_match_participants_user", table_name="match_participants")
    op.drop_table("match_participants")
    op.drop_table("match_answers")
    op.drop_table("ratings")
    op.drop_index(
        "ix_matches_live", table_name="matches", postgresql_where=sa.text("status = 'live'")
    )
    op.drop_table("matches")
    op.drop_index("ix_h2h_hi", table_name="h2h")
    op.drop_table("h2h")
