"""Rooms (Play with Friend, Group Battle): rooms, their members and kicks, and invites.

Revision ID: 0010
Revises: 0011
Create Date: 2026-09-28 11:19:12+00:00

The live lobby is in Redis; these tables are the record. ``ux_rooms_open_code`` keeps a code
unique among open rooms only, so codes are reused after their room closes.
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0010"
down_revision: str | None = "0011"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "rooms",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("code", sa.Text(), nullable=False),
        sa.Column("kind", sa.Text(), nullable=False),
        sa.Column("created_by", sa.Uuid(), nullable=False),
        sa.Column("settings", postgresql.JSONB(astext_type=sa.Text()), nullable=False),
        sa.Column("games", sa.Integer(), server_default=sa.text("0"), nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.Column("closed_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("close_reason", sa.Text(), nullable=True),
        sa.CheckConstraint(
            "close_reason IN ('host_ended', 'idle', 'host_left', 'empty')",
            name=op.f("ck_rooms_close_reason"),
        ),
        sa.CheckConstraint("kind IN ('friend', 'group')", name=op.f("ck_rooms_kind")),
        sa.ForeignKeyConstraint(
            ["created_by"], ["users.id"], name=op.f("fk_rooms_created_by_users"), ondelete="CASCADE"
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_rooms")),
    )
    op.create_index(
        "ix_rooms_open",
        "rooms",
        ["created_at"],
        unique=False,
        postgresql_where=sa.text("closed_at IS NULL"),
    )
    op.create_index(
        "ux_rooms_open_code",
        "rooms",
        ["code"],
        unique=True,
        postgresql_where=sa.text("closed_at IS NULL"),
    )
    op.create_table(
        "room_invites",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("room_id", sa.Uuid(), nullable=False),
        sa.Column("from_id", sa.Uuid(), nullable=False),
        sa.Column("to_id", sa.Uuid(), nullable=False),
        sa.Column("status", sa.Text(), server_default="pending", nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("responded_at", sa.DateTime(timezone=True), nullable=True),
        sa.CheckConstraint(
            "status IN ('pending', 'accepted', 'declined', 'expired', 'cancelled')",
            name=op.f("ck_room_invites_status"),
        ),
        sa.ForeignKeyConstraint(
            ["from_id"],
            ["users.id"],
            name=op.f("fk_room_invites_from_id_users"),
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["room_id"],
            ["rooms.id"],
            name=op.f("fk_room_invites_room_id_rooms"),
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["to_id"], ["users.id"], name=op.f("fk_room_invites_to_id_users"), ondelete="CASCADE"
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_room_invites")),
    )
    op.create_index("ix_room_invites_from", "room_invites", ["from_id", "status"], unique=False)
    op.create_index("ix_room_invites_room", "room_invites", ["room_id"], unique=False)
    op.create_index("ix_room_invites_to", "room_invites", ["to_id", "status"], unique=False)
    op.create_table(
        "room_kicks",
        sa.Column("room_id", sa.Uuid(), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("kicked_by", sa.Uuid(), nullable=False),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.ForeignKeyConstraint(
            ["kicked_by"],
            ["users.id"],
            name=op.f("fk_room_kicks_kicked_by_users"),
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["room_id"], ["rooms.id"], name=op.f("fk_room_kicks_room_id_rooms"), ondelete="CASCADE"
        ),
        sa.ForeignKeyConstraint(
            ["user_id"], ["users.id"], name=op.f("fk_room_kicks_user_id_users"), ondelete="CASCADE"
        ),
        sa.PrimaryKeyConstraint("room_id", "user_id", name=op.f("pk_room_kicks")),
    )
    op.create_table(
        "room_members",
        sa.Column("room_id", sa.Uuid(), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column(
            "joined_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False
        ),
        sa.Column("left_at", sa.DateTime(timezone=True), nullable=True),
        sa.ForeignKeyConstraint(
            ["room_id"],
            ["rooms.id"],
            name=op.f("fk_room_members_room_id_rooms"),
            ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["user_id"],
            ["users.id"],
            name=op.f("fk_room_members_user_id_users"),
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("room_id", "user_id", name=op.f("pk_room_members")),
    )
    op.create_index("ix_room_members_user", "room_members", ["user_id"], unique=False)


def downgrade() -> None:
    op.drop_index("ix_room_members_user", table_name="room_members")
    op.drop_table("room_members")
    op.drop_table("room_kicks")
    op.drop_index("ix_room_invites_to", table_name="room_invites")
    op.drop_index("ix_room_invites_room", table_name="room_invites")
    op.drop_index("ix_room_invites_from", table_name="room_invites")
    op.drop_table("room_invites")
    op.drop_index(
        "ux_rooms_open_code", table_name="rooms", postgresql_where=sa.text("closed_at IS NULL")
    )
    op.drop_index(
        "ix_rooms_open", table_name="rooms", postgresql_where=sa.text("closed_at IS NULL")
    )
    op.drop_table("rooms")
