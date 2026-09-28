"""Social and account lifecycle: friends, requests, blocks, activity, reports, moderation,
privacy settings, handle changes and account deletion.

Revision ID: 0008
Revises: 0006
Create Date: 2026-09-28 09:13:53+00:00

``friendships`` stores each pair once (``lo < hi``). ``ix_users_handle_prefix`` serves handle
search by prefix (``handle::text LIKE 'abc%'``). The privacy columns on ``user_settings`` are
NULL until the player chooses, since their defaults depend on the player's age.
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0008"
down_revision: str | None = "0006"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "activity_events",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("kind", sa.Text(), nullable=False),
        sa.Column(
            "payload",
            postgresql.JSONB(astext_type=sa.Text()),
            server_default=sa.text("'{}'"),
            nullable=False,
        ),
        sa.Column("key", sa.Text(), nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.CheckConstraint(
            "kind IN ('achievement', 'podium', 'level_up', 'streak', 'friend')",
            name=op.f("ck_activity_events_kind"),
        ),
        sa.ForeignKeyConstraint(
            ["user_id"],
            ["users.id"],
            name=op.f("fk_activity_events_user_id_users"),
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_activity_events")),
        sa.UniqueConstraint("user_id", "key", name=op.f("uq_activity_events_user_id_key")),
    )
    op.create_index(
        "ix_activity_events_created_at", "activity_events", ["created_at"], unique=False
    )
    op.create_index(
        "ix_activity_events_user_created",
        "activity_events",
        ["user_id", "created_at"],
        unique=False,
    )
    op.create_table(
        "blocks",
        sa.Column("blocker_id", sa.Uuid(), nullable=False),
        sa.Column("blocked_id", sa.Uuid(), nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.CheckConstraint("blocker_id <> blocked_id", name=op.f("ck_blocks_not_self")),
        sa.ForeignKeyConstraint(
            ["blocked_id"],
            ["users.id"],
            name=op.f("fk_blocks_blocked_id_users"),
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["blocker_id"],
            ["users.id"],
            name=op.f("fk_blocks_blocker_id_users"),
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("blocker_id", "blocked_id", name=op.f("pk_blocks")),
    )
    op.create_index("ix_blocks_blocked", "blocks", ["blocked_id"], unique=False)
    op.create_table(
        "friend_requests",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("from_id", sa.Uuid(), nullable=False),
        sa.Column("to_id", sa.Uuid(), nullable=False),
        sa.Column("status", sa.Text(), server_default="pending", nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.Column("decided_at", sa.DateTime(timezone=True), nullable=True),
        sa.CheckConstraint(
            "(status = 'pending') = (decided_at IS NULL)", name=op.f("ck_friend_requests_decided")
        ),
        sa.CheckConstraint(
            "status IN ('pending', 'accepted', 'declined', 'cancelled')",
            name=op.f("ck_friend_requests_status"),
        ),
        sa.CheckConstraint("from_id <> to_id", name=op.f("ck_friend_requests_not_self")),
        sa.ForeignKeyConstraint(
            ["from_id"],
            ["users.id"],
            name=op.f("fk_friend_requests_from_id_users"),
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["to_id"], ["users.id"], name=op.f("fk_friend_requests_to_id_users"), ondelete="CASCADE"
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_friend_requests")),
    )
    op.create_index(
        "ix_friend_requests_from_created",
        "friend_requests",
        ["from_id", "created_at"],
        unique=False,
    )
    op.create_index(
        "ix_friend_requests_to_pending",
        "friend_requests",
        ["to_id"],
        unique=False,
        postgresql_where=sa.text("status = 'pending'"),
    )
    op.create_index(
        "uq_friend_requests_pending",
        "friend_requests",
        ["from_id", "to_id"],
        unique=True,
        postgresql_where=sa.text("status = 'pending'"),
    )
    op.create_table(
        "friendships",
        sa.Column("lo", sa.Uuid(), nullable=False),
        sa.Column("hi", sa.Uuid(), nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.CheckConstraint("lo < hi", name=op.f("ck_friendships_ordered")),
        sa.ForeignKeyConstraint(
            ["hi"], ["users.id"], name=op.f("fk_friendships_hi_users"), ondelete="CASCADE"
        ),
        sa.ForeignKeyConstraint(
            ["lo"], ["users.id"], name=op.f("fk_friendships_lo_users"), ondelete="CASCADE"
        ),
        sa.PrimaryKeyConstraint("lo", "hi", name=op.f("pk_friendships")),
    )
    op.create_index("ix_friendships_hi", "friendships", ["hi"], unique=False)
    op.create_table(
        "moderation_actions",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("kind", sa.Text(), nullable=False),
        sa.Column("reason", sa.Text(), nullable=False),
        sa.Column("note", sa.Text(), nullable=True),
        sa.Column("until", sa.DateTime(timezone=True), nullable=True),
        sa.Column("created_by", sa.Uuid(), nullable=True),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.Column("revoked_at", sa.DateTime(timezone=True), nullable=True),
        sa.CheckConstraint(
            "kind <> 'perm_ban' OR until IS NULL", name=op.f("ck_moderation_actions_perm_ban_until")
        ),
        sa.CheckConstraint(
            "kind <> 'temp_ban' OR until IS NOT NULL",
            name=op.f("ck_moderation_actions_temp_ban_until"),
        ),
        sa.CheckConstraint(
            "kind IN ('warn', 'reset_name', 'restrict_social', 'shadow_pool', 'temp_ban', "
            "'perm_ban')",
            name=op.f("ck_moderation_actions_kind"),
        ),
        sa.CheckConstraint(
            "reason IN ('cheating', 'abuse', 'offensive_name', 'other')",
            name=op.f("ck_moderation_actions_reason"),
        ),
        sa.ForeignKeyConstraint(
            ["created_by"],
            ["users.id"],
            name=op.f("fk_moderation_actions_created_by_users"),
            ondelete="SET NULL",
        ),
        sa.ForeignKeyConstraint(
            ["user_id"],
            ["users.id"],
            name=op.f("fk_moderation_actions_user_id_users"),
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_moderation_actions")),
    )
    op.create_index(
        "ix_moderation_actions_user_created",
        "moderation_actions",
        ["user_id", "created_at"],
        unique=False,
    )
    op.create_table(
        "user_reports",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("reporter_id", sa.Uuid(), nullable=False),
        sa.Column("reported_id", sa.Uuid(), nullable=False),
        sa.Column("match_id", sa.Uuid(), nullable=True),
        sa.Column("reason", sa.Text(), nullable=False),
        sa.Column("note", sa.Text(), nullable=True),
        sa.Column("status", sa.Text(), server_default="open", nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.Column("resolved_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("resolved_by", sa.Uuid(), nullable=True),
        sa.CheckConstraint(
            "reason IN ('cheating', 'offensive_name', 'harassment', 'other')",
            name=op.f("ck_user_reports_reason"),
        ),
        sa.CheckConstraint(
            "status IN ('open', 'actioned', 'dismissed')", name=op.f("ck_user_reports_status")
        ),
        sa.CheckConstraint("char_length(note) <= 500", name=op.f("ck_user_reports_note_length")),
        sa.CheckConstraint("reporter_id <> reported_id", name=op.f("ck_user_reports_not_self")),
        sa.ForeignKeyConstraint(
            ["reported_id"],
            ["users.id"],
            name=op.f("fk_user_reports_reported_id_users"),
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["reporter_id"],
            ["users.id"],
            name=op.f("fk_user_reports_reporter_id_users"),
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["resolved_by"],
            ["users.id"],
            name=op.f("fk_user_reports_resolved_by_users"),
            ondelete="SET NULL",
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_user_reports")),
    )
    op.create_index(
        "ix_user_reports_open",
        "user_reports",
        ["created_at"],
        unique=False,
        postgresql_where=sa.text("status = 'open'"),
    )
    op.create_index(
        "ix_user_reports_reported", "user_reports", ["reported_id", "created_at"], unique=False
    )
    op.create_index(
        "ix_user_reports_reporter", "user_reports", ["reporter_id", "created_at"], unique=False
    )
    op.add_column("user_settings", sa.Column("friend_requests", sa.Text(), nullable=True))
    op.add_column("user_settings", sa.Column("challenges", sa.Text(), nullable=True))
    op.add_column("user_settings", sa.Column("presence", sa.Text(), nullable=True))
    op.add_column("user_settings", sa.Column("public_boards", sa.Boolean(), nullable=True))
    op.create_check_constraint(
        op.f("ck_user_settings_friend_requests"),
        "user_settings",
        "friend_requests IN ('everyone', 'played_with', 'nobody')",
    )
    op.create_check_constraint(
        op.f("ck_user_settings_challenges"),
        "user_settings",
        "challenges IN ('friends', 'everyone', 'nobody')",
    )
    op.create_check_constraint(
        op.f("ck_user_settings_presence"), "user_settings", "presence IN ('friends', 'nobody')"
    )
    op.add_column(
        "users", sa.Column("handle_changed_at", sa.DateTime(timezone=True), nullable=True)
    )
    op.add_column(
        "users", sa.Column("deletion_requested_at", sa.DateTime(timezone=True), nullable=True)
    )
    op.add_column("users", sa.Column("restore_until", sa.DateTime(timezone=True), nullable=True))
    op.create_index(
        "ix_users_handle_prefix",
        "users",
        ["handle"],
        unique=False,
        postgresql_ops={"handle": "text_pattern_ops"},
    )
    op.create_index(
        "ix_users_pending_deletion",
        "users",
        ["deletion_requested_at"],
        unique=False,
        postgresql_where=sa.text("status = 'pending_deletion'"),
    )


def downgrade() -> None:
    op.drop_index(
        "ix_users_pending_deletion",
        table_name="users",
        postgresql_where=sa.text("status = 'pending_deletion'"),
    )
    op.drop_index(
        "ix_users_handle_prefix", table_name="users", postgresql_ops={"handle": "text_pattern_ops"}
    )
    op.drop_column("users", "restore_until")
    op.drop_column("users", "deletion_requested_at")
    op.drop_column("users", "handle_changed_at")
    op.drop_constraint(op.f("ck_user_settings_presence"), "user_settings", type_="check")
    op.drop_constraint(op.f("ck_user_settings_challenges"), "user_settings", type_="check")
    op.drop_constraint(op.f("ck_user_settings_friend_requests"), "user_settings", type_="check")
    op.drop_column("user_settings", "public_boards")
    op.drop_column("user_settings", "presence")
    op.drop_column("user_settings", "challenges")
    op.drop_column("user_settings", "friend_requests")
    op.drop_index("ix_user_reports_reporter", table_name="user_reports")
    op.drop_index("ix_user_reports_reported", table_name="user_reports")
    op.drop_index(
        "ix_user_reports_open",
        table_name="user_reports",
        postgresql_where=sa.text("status = 'open'"),
    )
    op.drop_table("user_reports")
    op.drop_index("ix_moderation_actions_user_created", table_name="moderation_actions")
    op.drop_table("moderation_actions")
    op.drop_index("ix_friendships_hi", table_name="friendships")
    op.drop_table("friendships")
    op.drop_index(
        "uq_friend_requests_pending",
        table_name="friend_requests",
        postgresql_where=sa.text("status = 'pending'"),
    )
    op.drop_index(
        "ix_friend_requests_to_pending",
        table_name="friend_requests",
        postgresql_where=sa.text("status = 'pending'"),
    )
    op.drop_index("ix_friend_requests_from_created", table_name="friend_requests")
    op.drop_table("friend_requests")
    op.drop_index("ix_blocks_blocked", table_name="blocks")
    op.drop_table("blocks")
    op.drop_index("ix_activity_events_user_created", table_name="activity_events")
    op.drop_index("ix_activity_events_created_at", table_name="activity_events")
    op.drop_table("activity_events")
