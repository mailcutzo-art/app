"""Shares in the friends' activity feed: a battle result or the player's progress.

Revision ID: 0009
Revises: 0008
Create Date: 2026-09-28 14:00:00+00:00

Only the allowed ``activity_events.kind`` values change (``shared_result`` and
``shared_progress`` join them); the existing ``(user_id, created_at)`` index serves the daily
limit on progress shares and a player's own shares in their feed.
"""

from collections.abc import Sequence

from alembic import op

revision: str = "0009"
down_revision: str | None = "0008"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

_OLD_KINDS = "'achievement', 'podium', 'level_up', 'streak', 'friend'"
_NEW_KINDS = f"{_OLD_KINDS}, 'shared_result', 'shared_progress'"


def upgrade() -> None:
    op.drop_constraint(op.f("ck_activity_events_kind"), "activity_events", type_="check")
    op.create_check_constraint(
        op.f("ck_activity_events_kind"), "activity_events", f"kind IN ({_NEW_KINDS})"
    )


def downgrade() -> None:
    op.execute("DELETE FROM activity_events WHERE kind IN ('shared_result', 'shared_progress')")
    op.drop_constraint(op.f("ck_activity_events_kind"), "activity_events", type_="check")
    op.create_check_constraint(
        op.f("ck_activity_events_kind"), "activity_events", f"kind IN ({_OLD_KINDS})"
    )
