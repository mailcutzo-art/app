"""Question report review: the outcome an admin records when closing a report.

Revision ID: 0006
Revises: 0007
Create Date: 2026-09-28 10:00:00+00:00

Open reports have no outcome; closed ones (``resolved`` or ``dismissed``) record how they were
closed (``fixed``, ``rejected`` or ``retired``), the admin's note, who closed them and when. A
partial index serves the admin review queue (open reports, oldest first).
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "0006"
down_revision: str | None = "0007"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column("question_reports", sa.Column("resolution", sa.Text(), nullable=True))
    op.add_column("question_reports", sa.Column("resolution_note", sa.Text(), nullable=True))
    op.add_column("question_reports", sa.Column("resolved_by", sa.Uuid(), nullable=True))
    op.add_column(
        "question_reports",
        sa.Column("resolved_at", sa.DateTime(timezone=True), nullable=True),
    )
    op.create_foreign_key(
        op.f("fk_question_reports_resolved_by_users"),
        "question_reports",
        "users",
        ["resolved_by"],
        ["id"],
        ondelete="SET NULL",
    )
    # Reports closed before this revision (none are, as nothing closed them) get an outcome so
    # the new check holds.
    op.execute(
        "UPDATE question_reports SET resolution = CASE status WHEN 'dismissed' THEN 'rejected' "
        "ELSE 'fixed' END, resolved_at = created_at WHERE status <> 'open'"
    )
    op.create_check_constraint(
        op.f("ck_question_reports_resolution"),
        "question_reports",
        "resolution IN ('fixed', 'rejected', 'retired')",
    )
    op.create_check_constraint(
        op.f("ck_question_reports_resolved"),
        "question_reports",
        "(status = 'open') = (resolution IS NULL AND resolved_at IS NULL)",
    )
    op.create_index(
        "ix_question_reports_open_created",
        "question_reports",
        ["created_at"],
        postgresql_where=sa.text("status = 'open'"),
    )


def downgrade() -> None:
    op.drop_index("ix_question_reports_open_created", table_name="question_reports")
    op.drop_constraint(op.f("ck_question_reports_resolved"), "question_reports", type_="check")
    op.drop_constraint(op.f("ck_question_reports_resolution"), "question_reports", type_="check")
    op.drop_constraint(
        op.f("fk_question_reports_resolved_by_users"), "question_reports", type_="foreignkey"
    )
    for column in ("resolved_at", "resolved_by", "resolution_note", "resolution"):
        op.drop_column("question_reports", column)
