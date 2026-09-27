"""Baseline: extensions, app_config and the append-only audit_log.

Revision ID: 0001
Revises:
Create Date: 2026-09-27 00:00:00+00:00
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0001"
down_revision: str | None = None
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

# Left in place on downgrade: they may be provisioned by a superuser (scripts/dev_services.sh
# does so), and only their owner can drop them.
EXTENSIONS = ("citext", "pg_trgm")


def upgrade() -> None:
    for extension in EXTENSIONS:
        op.execute(f"CREATE EXTENSION IF NOT EXISTS {extension}")

    # Reusable guard for append-only tables (audit_log now, the coin ledger later).
    op.execute(
        """
        CREATE FUNCTION append_only_guard() RETURNS trigger
        LANGUAGE plpgsql AS $$
        BEGIN
            RAISE EXCEPTION '% on % is not allowed: the table is append-only',
                TG_OP, TG_TABLE_NAME;
        END;
        $$
        """
    )

    op.create_table(
        "app_config",
        sa.Column("key", sa.Text(), nullable=False),
        sa.Column("value", postgresql.JSONB(), nullable=False),
        sa.Column(
            "updated_at",
            sa.DateTime(timezone=True),
            server_default=sa.func.now(),
            nullable=False,
        ),
        sa.PrimaryKeyConstraint("key", name=op.f("pk_app_config")),
    )

    op.create_table(
        "audit_log",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("actor_id", sa.Uuid(), nullable=True),
        sa.Column("action", sa.Text(), nullable=False),
        sa.Column("entity_type", sa.Text(), nullable=False),
        sa.Column("entity_id", sa.Text(), nullable=False),
        sa.Column("before", postgresql.JSONB(), nullable=True),
        sa.Column("after", postgresql.JSONB(), nullable=True),
        sa.Column("ip", sa.Text(), nullable=True),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.func.now(),
            nullable=False,
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_audit_log")),
    )
    op.create_index("ix_audit_log_entity", "audit_log", ["entity_type", "entity_id"])
    op.create_index("ix_audit_log_actor_id", "audit_log", ["actor_id"])
    op.execute(
        "CREATE TRIGGER audit_log_append_only BEFORE UPDATE OR DELETE ON audit_log "
        "FOR EACH ROW EXECUTE FUNCTION append_only_guard()"
    )
    # Row triggers do not fire for TRUNCATE.
    op.execute(
        "CREATE TRIGGER audit_log_append_only_truncate BEFORE TRUNCATE ON audit_log "
        "FOR EACH STATEMENT EXECUTE FUNCTION append_only_guard()"
    )


def downgrade() -> None:
    op.drop_table("audit_log")
    op.drop_table("app_config")
    op.execute("DROP FUNCTION append_only_guard()")
