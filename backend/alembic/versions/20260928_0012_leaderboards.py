"""Leaderboards: the weekly champions' badges.

Revision ID: 0012
Revises: 0009
Create Date: 2026-09-28 18:00:00+00:00

The boards themselves are Redis sorted sets rebuilt nightly from Postgres (ratings, xp_events
and match_participants); only the "Physics Champion · Week 39" badges are stored.
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "0012"
down_revision: str | None = "0009"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "leaderboard_badges",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("board", sa.Text(), nullable=False),
        sa.Column("goal", sa.Text(), nullable=False),
        sa.Column("week", sa.Date(), nullable=False),
        sa.Column("title", sa.Text(), nullable=False),
        sa.Column("value", sa.Integer(), nullable=False),
        sa.Column(
            "created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False
        ),
        sa.CheckConstraint("goal IN ('neet', 'jee')", name=op.f("ck_leaderboard_badges_goal")),
        sa.ForeignKeyConstraint(
            ["user_id"],
            ["users.id"],
            name=op.f("fk_leaderboard_badges_user_id_users"),
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_leaderboard_badges")),
        sa.UniqueConstraint(
            "board", "goal", "week", name=op.f("uq_leaderboard_badges_board_goal_week")
        ),
    )
    op.create_index(
        "ix_leaderboard_badges_user", "leaderboard_badges", ["user_id", "week"], unique=False
    )


def downgrade() -> None:
    op.drop_index("ix_leaderboard_badges_user", table_name="leaderboard_badges")
    op.drop_table("leaderboard_badges")
