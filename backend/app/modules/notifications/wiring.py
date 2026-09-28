"""Hooks that turn other modules' events into inbox items. ``install()`` runs once at startup."""

from sqlalchemy.ext.asyncio import AsyncSession

from app.modules.content.hooks import ReportResolved, on_report_resolved, report_outcome_notice
from app.modules.notifications.kinds import NotificationKind
from app.modules.notifications.service import notify


async def notify_reporter(db: AsyncSession, event: ReportResolved) -> None:
    """Tell a player what happened to the question they reported."""
    notice = report_outcome_notice(event)
    await notify(
        db,
        event.user_id,
        kind=NotificationKind.QUESTION_REPORT,
        title=notice.title,
        body=notice.body,
        icon=notice.icon,
        action=notice.action,
        key=notice.key,
    )


def install() -> None:
    on_report_resolved.register(notify_reporter)
