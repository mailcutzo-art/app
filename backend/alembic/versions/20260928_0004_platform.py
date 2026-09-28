"""Platform: outbox, coins, inbox and push, user settings, analytics and feedback.

Revision ID: 0004
Revises: 0003
Create Date: 2026-09-28 09:00:00+00:00

``coin_ledger`` is append-only like ``audit_log``: the ``append_only_guard()`` trigger from 0001
rejects UPDATE, DELETE and TRUNCATE. Its ``user_id`` has no foreign key on purpose, so no
cascade from ``users`` can ever reach it (ledger rows outlive an erased account).
"""

from collections.abc import Sequence
from typing import Any

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0004"
down_revision: str | None = "0003"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

COIN_REASONS = (
    "reason IN ('welcome', 'match_entry', 'match_pot', 'match_reward', 'tournament_entry', "
    "'tournament_prize', 'refund', 'mission_bonus', 'level_up', 'streak_bonus', 'achievement', "
    "'streak_freeze', 'hint', 'transfer', 'adjustment')"
)
REF_KINDS = (
    "ref_kind IN ('match', 'tournament', 'mission', 'streak', 'achievement', 'hint', "
    "'welcome', 'level', 'room')"
)
NOTIFICATION_KINDS = (
    "kind IN ('invite', 'friend_request', 'friend_accepted', 'tournament_reminder', "
    "'tournament_check_in', 'tournament_round', 'tournament_at_risk', 'tournament_result', "
    "'tournament_cancelled', 'tournament_withdrawn', 'refund', 'prize', 'match_forfeit', "
    "'match_aborted', 'match_settled', 'mission_done', 'level_up', 'achievement', "
    "'rank_milestone', 'weekly_result', 'streak_risk', 'streak_freeze_used', 'streak_lost', "
    "'question_report', 'account')"
)


def _timestamp(name: str) -> sa.Column[Any]:
    return sa.Column(
        name, sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False
    )


def _optional_time(name: str) -> sa.Column[Any]:
    return sa.Column(name, sa.DateTime(timezone=True), nullable=True)


def _counter(name: str, type_: sa.types.TypeEngine[Any] | None = None) -> sa.Column[Any]:
    return sa.Column(name, type_ or sa.Integer(), server_default=sa.text("0"), nullable=False)


def _user_fk(table: str, ondelete: str = "CASCADE") -> sa.ForeignKeyConstraint:
    return sa.ForeignKeyConstraint(
        ["user_id"], ["users.id"], name=op.f(f"fk_{table}_user_id_users"), ondelete=ondelete
    )


def upgrade() -> None:
    _create_outbox()
    _create_economy()
    _create_notifications()
    _create_user_settings()
    _create_analytics()
    _create_feedback()


def _create_outbox() -> None:
    op.create_table(
        "outbox",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("topic", sa.Text(), nullable=False),
        sa.Column("payload", postgresql.JSONB(astext_type=sa.Text()), nullable=False),
        sa.Column("key", sa.Text(), nullable=False),
        _timestamp("created_at"),
        _timestamp("available_at"),
        _counter("attempts"),
        _optional_time("delivered_at"),
        _optional_time("dead_at"),
        sa.Column("last_error", sa.Text(), nullable=True),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_outbox")),
        sa.UniqueConstraint("key", name=op.f("uq_outbox_key")),
    )
    op.create_index(
        "ix_outbox_pending",
        "outbox",
        ["available_at"],
        postgresql_where=sa.text("delivered_at IS NULL AND dead_at IS NULL"),
    )


def _create_economy() -> None:
    op.create_table(
        "wallets",
        sa.Column("user_id", sa.Uuid(), nullable=False),
        _counter("balance", sa.BigInteger()),
        _counter("held", sa.BigInteger()),
        _counter("purchased", sa.BigInteger()),
        _optional_time("welcome_seen_at"),
        _timestamp("updated_at"),
        sa.CheckConstraint("balance >= 0", name=op.f("ck_wallets_balance")),
        sa.CheckConstraint("held >= 0", name=op.f("ck_wallets_held")),
        sa.CheckConstraint("purchased >= 0", name=op.f("ck_wallets_purchased")),
        _user_fk("wallets"),
        sa.PrimaryKeyConstraint("user_id", name=op.f("pk_wallets")),
    )
    op.create_table(
        "coin_ledger",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("delta", sa.BigInteger(), nullable=False),
        sa.Column("balance_after", sa.BigInteger(), nullable=False),
        sa.Column("reason", sa.Text(), nullable=False),
        sa.Column("title", sa.Text(), nullable=False),
        sa.Column("ref_kind", sa.Text(), nullable=True),
        sa.Column("ref_id", sa.Text(), nullable=True),
        sa.Column("bucket", sa.Text(), server_default="earned", nullable=False),
        sa.Column("idempotency_key", sa.Text(), nullable=False),
        _timestamp("created_at"),
        sa.CheckConstraint("delta <> 0", name=op.f("ck_coin_ledger_delta")),
        sa.CheckConstraint("balance_after >= 0", name=op.f("ck_coin_ledger_balance_after")),
        sa.CheckConstraint(COIN_REASONS, name=op.f("ck_coin_ledger_reason")),
        sa.CheckConstraint(REF_KINDS, name=op.f("ck_coin_ledger_ref_kind")),
        sa.CheckConstraint("bucket IN ('earned', 'purchased')", name=op.f("ck_coin_ledger_bucket")),
        sa.CheckConstraint(
            "(ref_kind IS NULL) = (ref_id IS NULL)", name=op.f("ck_coin_ledger_ref")
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_coin_ledger")),
        sa.UniqueConstraint("idempotency_key", name=op.f("uq_coin_ledger_idempotency_key")),
    )
    op.create_index("ix_coin_ledger_user_created", "coin_ledger", ["user_id", "created_at", "id"])
    op.execute(
        "CREATE TRIGGER coin_ledger_append_only BEFORE UPDATE OR DELETE ON coin_ledger "
        "FOR EACH ROW EXECUTE FUNCTION append_only_guard()"
    )
    op.execute(
        "CREATE TRIGGER coin_ledger_append_only_truncate BEFORE TRUNCATE ON coin_ledger "
        "FOR EACH STATEMENT EXECUTE FUNCTION append_only_guard()"
    )
    op.create_table(
        "coin_holds",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("amount", sa.BigInteger(), nullable=False),
        sa.Column("reason", sa.Text(), nullable=False),
        sa.Column("ref_kind", sa.Text(), nullable=False),
        sa.Column("ref_id", sa.Text(), nullable=False),
        sa.Column("status", sa.Text(), server_default="held", nullable=False),
        sa.Column("key", sa.Text(), nullable=False),
        _timestamp("created_at"),
        _optional_time("settled_at"),
        sa.CheckConstraint("amount > 0", name=op.f("ck_coin_holds_amount")),
        sa.CheckConstraint(
            "status IN ('held', 'captured', 'released')", name=op.f("ck_coin_holds_status")
        ),
        sa.CheckConstraint(REF_KINDS, name=op.f("ck_coin_holds_ref_kind")),
        sa.CheckConstraint(COIN_REASONS, name=op.f("ck_coin_holds_reason")),
        sa.CheckConstraint(
            "(status = 'held') = (settled_at IS NULL)", name=op.f("ck_coin_holds_settled")
        ),
        _user_fk("coin_holds"),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_coin_holds")),
        sa.UniqueConstraint("key", name=op.f("uq_coin_holds_key")),
    )
    op.create_index(
        "ix_coin_holds_open",
        "coin_holds",
        ["created_at"],
        postgresql_where=sa.text("status = 'held'"),
    )
    op.create_index("ix_coin_holds_ref", "coin_holds", ["ref_kind", "ref_id"])
    op.create_index(op.f("ix_coin_holds_user_id"), "coin_holds", ["user_id"])


def _create_notifications() -> None:
    op.create_table(
        "notifications",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("kind", sa.Text(), nullable=False),
        sa.Column("title", sa.Text(), nullable=False),
        sa.Column("body", sa.Text(), nullable=False),
        sa.Column("icon", sa.Text(), nullable=True),
        sa.Column("action", postgresql.JSONB(astext_type=sa.Text()), nullable=True),
        sa.Column("key", sa.Text(), nullable=False),
        _timestamp("created_at"),
        _optional_time("read_at"),
        sa.CheckConstraint(NOTIFICATION_KINDS, name=op.f("ck_notifications_kind")),
        _user_fk("notifications"),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_notifications")),
        sa.UniqueConstraint("user_id", "key", name=op.f("uq_notifications_user_id_key")),
    )
    op.create_index(
        "ix_notifications_user_created", "notifications", ["user_id", "created_at", "id"]
    )
    op.create_index(
        "ix_notifications_unread",
        "notifications",
        ["user_id"],
        postgresql_where=sa.text("read_at IS NULL"),
    )
    op.create_index("ix_notifications_created_at", "notifications", ["created_at"])
    op.create_table(
        "push_tokens",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("session_id", sa.Uuid(), nullable=False),
        sa.Column("token", sa.Text(), nullable=False),
        sa.Column("platform", sa.Text(), nullable=False),
        _timestamp("created_at"),
        _timestamp("updated_at"),
        sa.CheckConstraint("platform IN ('android', 'ios')", name=op.f("ck_push_tokens_platform")),
        _user_fk("push_tokens"),
        sa.ForeignKeyConstraint(
            ["session_id"],
            ["device_sessions.id"],
            name=op.f("fk_push_tokens_session_id_device_sessions"),
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_push_tokens")),
        sa.UniqueConstraint("session_id", name=op.f("uq_push_tokens_session_id")),
        sa.UniqueConstraint("token", name=op.f("uq_push_tokens_token")),
    )
    op.create_index(op.f("ix_push_tokens_user_id"), "push_tokens", ["user_id"])


def _create_user_settings() -> None:
    op.create_table(
        "user_settings",
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column(
            "analytics_enabled", sa.Boolean(), server_default=sa.text("true"), nullable=False
        ),
        sa.Column(
            "notification_kinds",
            postgresql.JSONB(astext_type=sa.Text()),
            server_default=sa.text("'{}'"),
            nullable=False,
        ),
        sa.Column("quiet_start", sa.Time(), server_default=sa.text("'22:30'"), nullable=True),
        sa.Column("quiet_end", sa.Time(), server_default=sa.text("'07:00'"), nullable=True),
        _timestamp("updated_at"),
        sa.CheckConstraint(
            "(quiet_start IS NULL) = (quiet_end IS NULL)", name=op.f("ck_user_settings_quiet_hours")
        ),
        _user_fk("user_settings"),
        sa.PrimaryKeyConstraint("user_id", name=op.f("pk_user_settings")),
    )


def _create_analytics() -> None:
    op.create_table(
        "analytics_events",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("name", sa.Text(), nullable=False),
        sa.Column("props", postgresql.JSONB(astext_type=sa.Text()), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=True),
        sa.Column("session_key", sa.Text(), nullable=True),
        sa.Column("is_minor", sa.Boolean(), nullable=False),
        sa.Column("source", sa.Text(), nullable=False),
        sa.Column("at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("ist_day", sa.Date(), nullable=False),
        _timestamp("created_at"),
        sa.CheckConstraint(
            "source IN ('client', 'server')", name=op.f("ck_analytics_events_source")
        ),
        sa.CheckConstraint(
            "NOT (is_minor AND user_id IS NOT NULL)",
            name=op.f("ck_analytics_events_minor_anonymous"),
        ),
        _user_fk("analytics_events", ondelete="SET NULL"),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_analytics_events")),
    )
    op.create_index("ix_analytics_events_day_name", "analytics_events", ["ist_day", "name"])
    op.create_index("ix_analytics_events_at", "analytics_events", ["at"])
    op.create_index(op.f("ix_analytics_events_user_id"), "analytics_events", ["user_id"])


def _create_feedback() -> None:
    op.create_table(
        "feedback",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=True),
        sa.Column("kind", sa.Text(), nullable=False),
        sa.Column("message", sa.Text(), nullable=False),
        sa.Column("request_id", sa.Text(), nullable=True),
        sa.Column("app_build", sa.Integer(), nullable=True),
        sa.Column("status", sa.Text(), server_default="open", nullable=False),
        _timestamp("created_at"),
        sa.CheckConstraint(
            "kind IN ('problem', 'idea', 'coins', 'ban_appeal')", name=op.f("ck_feedback_kind")
        ),
        sa.CheckConstraint("status IN ('open', 'closed')", name=op.f("ck_feedback_status")),
        sa.CheckConstraint(
            "char_length(message) BETWEEN 1 AND 2000", name=op.f("ck_feedback_message")
        ),
        _user_fk("feedback", ondelete="SET NULL"),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_feedback")),
    )
    op.create_index(
        "ix_feedback_open", "feedback", ["created_at"], postgresql_where=sa.text("status = 'open'")
    )
    op.create_index(op.f("ix_feedback_user_id"), "feedback", ["user_id"])


def downgrade() -> None:
    # Dropping the table drops its triggers; append_only_guard() itself belongs to 0001.
    for table in (
        "feedback",
        "analytics_events",
        "user_settings",
        "push_tokens",
        "notifications",
        "coin_holds",
        "coin_ledger",
        "wallets",
        "outbox",
    ):
        op.drop_table(table)
