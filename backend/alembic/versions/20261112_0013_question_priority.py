"""Question metadata and ranking for recommended practice.

Revision ID: 0013
Revises: 0012
Create Date: 2026-11-12 12:00:00+00:00

The content files already describe every question's subtopic, concept, format, NCERT basis and
typical time; the seed now stores them, plus the ranking computed from them
(``app.modules.content.priority``): an importance score, a tier (1 core, 2 standard, 3 extra),
the study order within the topic and the cluster (the idea a question tests). Existing rows get
the defaults (importance 50, tier 3) until the next seed run ranks them.
See ``docs/recommendation.md``.
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "0013"
down_revision: str | None = "0012"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column("questions", sa.Column("subtopic", sa.Text(), nullable=True))
    op.add_column("questions", sa.Column("concept", sa.Text(), nullable=True))
    op.add_column("questions", sa.Column("format", sa.Text(), nullable=True))
    op.add_column("questions", sa.Column("ncert", sa.Boolean(), nullable=True))
    op.add_column("questions", sa.Column("time_s", sa.SmallInteger(), nullable=True))
    op.add_column(
        "questions",
        sa.Column("importance", sa.SmallInteger(), server_default=sa.text("50"), nullable=False),
    )
    op.add_column(
        "questions",
        sa.Column("tier", sa.SmallInteger(), server_default=sa.text("3"), nullable=False),
    )
    op.add_column("questions", sa.Column("topic_rank", sa.Integer(), nullable=True))
    op.add_column("questions", sa.Column("cluster", sa.Text(), nullable=True))
    op.create_check_constraint(
        op.f("ck_questions_importance"), "questions", "importance BETWEEN 0 AND 100"
    )
    op.create_check_constraint(op.f("ck_questions_tier"), "questions", "tier BETWEEN 1 AND 3")
    op.create_index(
        "ix_questions_topic_rank_published",
        "questions",
        ["topic_id", "tier", "topic_rank"],
        postgresql_where=sa.text("status = 'published'"),
    )


def downgrade() -> None:
    op.drop_index("ix_questions_topic_rank_published", table_name="questions")
    op.drop_constraint(op.f("ck_questions_tier"), "questions", type_="check")
    op.drop_constraint(op.f("ck_questions_importance"), "questions", type_="check")
    for column in (
        "cluster",
        "topic_rank",
        "tier",
        "importance",
        "time_s",
        "ncert",
        "format",
        "concept",
        "subtopic",
    ):
        op.drop_column("questions", column)
