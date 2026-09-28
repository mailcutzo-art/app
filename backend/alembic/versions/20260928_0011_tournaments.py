"""Scheduled Swiss tournaments: templates, tournaments, entries, rounds, pairings and prizes.

Revision ID: 0011
Revises: 0009
Create Date: 2026-09-28 11:23:07+00:00

``tournaments.next_action_at`` drives the worker's lifecycle steps (a partial index serves its
scan), ``UQ(template_id, starts_at)`` keeps recurring instances idempotent, and pairings hold
their pre-generated match ids (unique) with one board per player and round.
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0011"
down_revision: str | None = "0009"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

_STATUSES = (
    "'scheduled', 'reg_open', 'check_in', 'locked', 'running', 'finalizing', 'finished', "
    "'cancelled'"
)
_RESULTS = "'win', 'draw', 'loss', 'forfeit_win', 'forfeit_loss', 'double_forfeit', 'bye'"


def upgrade() -> None:
    op.create_table(
        "tournament_templates",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("title", sa.Text(), nullable=False),
        sa.Column("description", sa.Text(), server_default="", nullable=False),
        sa.Column("subject_id", sa.SmallInteger(), nullable=True),
        sa.Column("goal", sa.Text(), nullable=False),
        sa.Column("rounds", sa.SmallInteger(), server_default=sa.text("5"), nullable=False),
        sa.Column("entry_fee", sa.Integer(), server_default=sa.text("0"), nullable=False),
        sa.Column("prize_pool", sa.Integer(), server_default=sa.text("0"), nullable=False),
        sa.Column("capacity", sa.SmallInteger(), server_default=sa.text("64"), nullable=False),
        sa.Column("min_players", sa.SmallInteger(), server_default=sa.text("8"), nullable=False),
        sa.Column("rrule", sa.Text(), nullable=False),
        sa.Column(
            "reg_opens_before_min", sa.Integer(), server_default=sa.text("1440"), nullable=False
        ),
        sa.Column("active", sa.Boolean(), server_default=sa.text("true"), nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.CheckConstraint(
            "goal IN ('neet', 'jee', 'any')", name=op.f("ck_tournament_templates_goal")
        ),
        sa.CheckConstraint(
            "capacity BETWEEN 4 AND 256", name=op.f("ck_tournament_templates_capacity")
        ),
        sa.CheckConstraint(
            "entry_fee IN (0, 10, 15, 25, 50)", name=op.f("ck_tournament_templates_entry_fee")
        ),
        sa.CheckConstraint(
            "min_players BETWEEN 4 AND capacity", name=op.f("ck_tournament_templates_min_players")
        ),
        sa.CheckConstraint("prize_pool >= 0", name=op.f("ck_tournament_templates_prize_pool")),
        sa.CheckConstraint(
            "reg_opens_before_min > 15", name=op.f("ck_tournament_templates_reg_opens_before")
        ),
        sa.CheckConstraint("rounds BETWEEN 3 AND 6", name=op.f("ck_tournament_templates_rounds")),
        sa.ForeignKeyConstraint(
            ["subject_id"],
            ["subjects.id"],
            name=op.f("fk_tournament_templates_subject_id_subjects"),
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_tournament_templates")),
    )
    op.create_table(
        "tournaments",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("template_id", sa.Uuid(), nullable=True),
        sa.Column("title", sa.Text(), nullable=False),
        sa.Column("description", sa.Text(), server_default="", nullable=False),
        sa.Column("subject_id", sa.SmallInteger(), nullable=True),
        sa.Column("goal", sa.Text(), nullable=False),
        sa.Column("rounds", sa.SmallInteger(), server_default=sa.text("5"), nullable=False),
        sa.Column("entry_fee", sa.Integer(), server_default=sa.text("0"), nullable=False),
        sa.Column("prize_pool", sa.Integer(), server_default=sa.text("0"), nullable=False),
        sa.Column("capacity", sa.SmallInteger(), server_default=sa.text("64"), nullable=False),
        sa.Column("min_players", sa.SmallInteger(), server_default=sa.text("8"), nullable=False),
        sa.Column("reg_opens_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("starts_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("status", sa.Text(), server_default="scheduled", nullable=False),
        sa.Column("rounds_planned", sa.SmallInteger(), nullable=True),
        sa.Column("current_round", sa.SmallInteger(), server_default=sa.text("0"), nullable=False),
        sa.Column("players", sa.SmallInteger(), server_default=sa.text("0"), nullable=False),
        sa.Column("next_action_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("at_risk_sent", sa.Boolean(), server_default=sa.text("false"), nullable=False),
        sa.Column("cancel_reason", sa.Text(), nullable=True),
        sa.Column("started_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("finished_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.CheckConstraint("goal IN ('neet', 'jee', 'any')", name=op.f("ck_tournaments_goal")),
        sa.CheckConstraint(
            f"status IN ({_STATUSES})",
            name=op.f("ck_tournaments_status"),
        ),
        sa.CheckConstraint("capacity BETWEEN 4 AND 256", name=op.f("ck_tournaments_capacity")),
        sa.CheckConstraint(
            "entry_fee IN (0, 10, 15, 25, 50)", name=op.f("ck_tournaments_entry_fee")
        ),
        sa.CheckConstraint(
            "min_players BETWEEN 4 AND capacity", name=op.f("ck_tournaments_min_players")
        ),
        sa.CheckConstraint("prize_pool >= 0", name=op.f("ck_tournaments_prize_pool")),
        sa.CheckConstraint("reg_opens_at < starts_at", name=op.f("ck_tournaments_schedule")),
        sa.CheckConstraint("rounds BETWEEN 3 AND 6", name=op.f("ck_tournaments_rounds")),
        sa.ForeignKeyConstraint(
            ["subject_id"], ["subjects.id"], name=op.f("fk_tournaments_subject_id_subjects")
        ),
        sa.ForeignKeyConstraint(
            ["template_id"],
            ["tournament_templates.id"],
            name=op.f("fk_tournaments_template_id_tournament_templates"),
            ondelete="SET NULL",
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_tournaments")),
        sa.UniqueConstraint(
            "template_id", "starts_at", name=op.f("uq_tournaments_template_id_starts_at")
        ),
    )
    op.create_index(
        "ix_tournaments_due",
        "tournaments",
        ["next_action_at"],
        unique=False,
        postgresql_where=sa.text("next_action_at IS NOT NULL"),
    )
    op.create_index(
        "ix_tournaments_status_starts", "tournaments", ["status", "starts_at"], unique=False
    )
    op.create_table(
        "tournament_entries",
        sa.Column("tournament_id", sa.Uuid(), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column(
            "registered_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.Column("hold_id", sa.Uuid(), nullable=True),
        sa.Column("seed", sa.SmallInteger(), nullable=True),
        sa.Column("checked_in", sa.Boolean(), server_default=sa.text("false"), nullable=False),
        sa.Column("checked_in_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("withdrawn", sa.Boolean(), server_default=sa.text("false"), nullable=False),
        sa.Column("withdrawn_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("withdraw_reason", sa.Text(), nullable=True),
        sa.Column("no_show", sa.Boolean(), server_default=sa.text("false"), nullable=False),
        sa.Column("points", sa.Double(), server_default=sa.text("0"), nullable=False),
        sa.Column("bh", sa.Double(), server_default=sa.text("0"), nullable=False),
        sa.Column("bh_c1", sa.Double(), server_default=sa.text("0"), nullable=False),
        sa.Column("sb", sa.Double(), server_default=sa.text("0"), nullable=False),
        sa.Column("quiz_points", sa.Integer(), server_default=sa.text("0"), nullable=False),
        sa.Column("correct_count", sa.Integer(), server_default=sa.text("0"), nullable=False),
        sa.Column("correct_time_ms", sa.Integer(), server_default=sa.text("0"), nullable=False),
        sa.Column("wins", sa.SmallInteger(), server_default=sa.text("0"), nullable=False),
        sa.Column("draws", sa.SmallInteger(), server_default=sa.text("0"), nullable=False),
        sa.Column("losses", sa.SmallInteger(), server_default=sa.text("0"), nullable=False),
        sa.Column("byes", sa.SmallInteger(), server_default=sa.text("0"), nullable=False),
        sa.Column("absences", sa.SmallInteger(), server_default=sa.text("0"), nullable=False),
        sa.Column("rank", sa.SmallInteger(), nullable=True),
        sa.Column("final_rank", sa.SmallInteger(), nullable=True),
        sa.CheckConstraint(
            "byes >= 0 AND absences >= 0", name=op.f("ck_tournament_entries_counts")
        ),
        sa.ForeignKeyConstraint(
            ["tournament_id"],
            ["tournaments.id"],
            name=op.f("fk_tournament_entries_tournament_id_tournaments"),
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["user_id"],
            ["users.id"],
            name=op.f("fk_tournament_entries_user_id_users"),
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("tournament_id", "user_id", name=op.f("pk_tournament_entries")),
    )
    op.create_index(
        "ix_tournament_entries_user",
        "tournament_entries",
        ["user_id", "tournament_id"],
        unique=False,
    )
    op.create_table(
        "tournament_pairings",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("tournament_id", sa.Uuid(), nullable=False),
        sa.Column("round", sa.SmallInteger(), nullable=False),
        sa.Column("board", sa.SmallInteger(), nullable=False),
        sa.Column("a_id", sa.Uuid(), nullable=False),
        sa.Column("b_id", sa.Uuid(), nullable=True),
        sa.Column("match_id", sa.Uuid(), nullable=True),
        sa.Column("status", sa.Text(), server_default="pending", nullable=False),
        sa.Column("result_a", sa.Text(), nullable=True),
        sa.Column("result_b", sa.Text(), nullable=True),
        sa.Column("score_a", sa.Integer(), server_default=sa.text("0"), nullable=False),
        sa.Column("score_b", sa.Integer(), server_default=sa.text("0"), nullable=False),
        sa.Column("finished_at", sa.DateTime(timezone=True), nullable=True),
        sa.CheckConstraint(
            f"result_a IN ({_RESULTS})",
            name=op.f("ck_tournament_pairings_result_a"),
        ),
        sa.CheckConstraint(
            f"result_b IN ({_RESULTS})",
            name=op.f("ck_tournament_pairings_result_b"),
        ),
        sa.CheckConstraint(
            "status IN ('pending', 'done')", name=op.f("ck_tournament_pairings_status")
        ),
        sa.CheckConstraint(
            "(b_id IS NULL) = (match_id IS NULL)", name=op.f("ck_tournament_pairings_bye")
        ),
        sa.CheckConstraint("a_id <> b_id", name=op.f("ck_tournament_pairings_distinct")),
        sa.ForeignKeyConstraint(
            ["a_id"],
            ["users.id"],
            name=op.f("fk_tournament_pairings_a_id_users"),
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["b_id"],
            ["users.id"],
            name=op.f("fk_tournament_pairings_b_id_users"),
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["tournament_id"],
            ["tournaments.id"],
            name=op.f("fk_tournament_pairings_tournament_id_tournaments"),
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_tournament_pairings")),
        sa.UniqueConstraint("match_id", name=op.f("uq_tournament_pairings_match_id")),
        sa.UniqueConstraint(
            "tournament_id",
            "round",
            "a_id",
            name=op.f("uq_tournament_pairings_tournament_id_round_a_id"),
        ),
        sa.UniqueConstraint(
            "tournament_id",
            "round",
            "b_id",
            name=op.f("uq_tournament_pairings_tournament_id_round_b_id"),
        ),
    )
    op.create_index(
        "ix_tournament_pairings_b", "tournament_pairings", ["tournament_id", "b_id"], unique=False
    )
    op.create_table(
        "tournament_prizes",
        sa.Column("tournament_id", sa.Uuid(), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("place", sa.SmallInteger(), nullable=False),
        sa.Column("amount", sa.Integer(), nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.CheckConstraint("amount > 0", name=op.f("ck_tournament_prizes_amount")),
        sa.ForeignKeyConstraint(
            ["tournament_id"],
            ["tournaments.id"],
            name=op.f("fk_tournament_prizes_tournament_id_tournaments"),
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["user_id"],
            ["users.id"],
            name=op.f("fk_tournament_prizes_user_id_users"),
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("tournament_id", "user_id", name=op.f("pk_tournament_prizes")),
        sa.UniqueConstraint(
            "tournament_id", "place", name=op.f("uq_tournament_prizes_tournament_id_place")
        ),
    )
    op.create_table(
        "tournament_rounds",
        sa.Column("tournament_id", sa.Uuid(), nullable=False),
        sa.Column("number", sa.SmallInteger(), nullable=False),
        sa.Column("subject_id", sa.SmallInteger(), nullable=False),
        sa.Column("status", sa.Text(), server_default="starting", nullable=False),
        sa.Column(
            "relaxations",
            postgresql.JSONB(astext_type=sa.Text()),
            server_default=sa.text("'[]'"),
            nullable=False,
        ),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.Column("started_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("deadline_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("finished_at", sa.DateTime(timezone=True), nullable=True),
        sa.CheckConstraint(
            "status IN ('starting', 'live', 'closing', 'done')",
            name=op.f("ck_tournament_rounds_status"),
        ),
        sa.ForeignKeyConstraint(
            ["subject_id"], ["subjects.id"], name=op.f("fk_tournament_rounds_subject_id_subjects")
        ),
        sa.ForeignKeyConstraint(
            ["tournament_id"],
            ["tournaments.id"],
            name=op.f("fk_tournament_rounds_tournament_id_tournaments"),
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("tournament_id", "number", name=op.f("pk_tournament_rounds")),
    )


def downgrade() -> None:
    op.drop_table("tournament_rounds")
    op.drop_table("tournament_prizes")
    op.drop_index("ix_tournament_pairings_b", table_name="tournament_pairings")
    op.drop_table("tournament_pairings")
    op.drop_index("ix_tournament_entries_user", table_name="tournament_entries")
    op.drop_table("tournament_entries")
    op.drop_index("ix_tournaments_status_starts", table_name="tournaments")
    op.drop_index(
        "ix_tournaments_due",
        table_name="tournaments",
        postgresql_where=sa.text("next_action_at IS NOT NULL"),
    )
    op.drop_table("tournaments")
    op.drop_table("tournament_templates")
