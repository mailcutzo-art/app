"""Extension points other modules plug into, so content doesn't import them.

``on_report_resolved`` runs when an admin closes a question report, once per reporter, inside
the transaction that closes it (a hook's writes commit or roll back with the resolution). The
inbox wires it at startup to send the reporter a ``question_report`` notification::

    from app.modules.content.hooks import on_report_resolved, report_outcome_notice
    from app.modules.notifications.service import notify

    async def notify_reporter(db, event):
        notice = report_outcome_notice(event)
        await notify(db, event.user_id, kind="question_report", title=notice.title,
                     body=notice.body, icon=notice.icon, action=notice.action, key=notice.key)

    on_report_resolved.register(notify_reporter)
"""

import uuid
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from datetime import datetime
from typing import Any, Generic, TypeVar

from sqlalchemy.ext.asyncio import AsyncSession

from app.modules.content.models import ReportResolution


@dataclass(frozen=True, slots=True)
class ReportResolved:
    """One reporter's report was closed."""

    report_id: uuid.UUID
    user_id: uuid.UUID  # the reporter
    question_id: uuid.UUID
    question_ref: str  # the ref the app knows the question by (``q_<hex>``)
    reason: str  # what they reported: wrong_answer, typo, unclear or other
    resolution: ReportResolution
    resolved_at: datetime


E = TypeVar("E")


class HookRegistry(Generic[E]):
    """Async callbacks run in registration order; registering the same one twice is a no-op."""

    def __init__(self, name: str) -> None:
        self.name = name
        self._hooks: list[Callable[[AsyncSession, E], Awaitable[None]]] = []

    def register(self, hook: Callable[[AsyncSession, E], Awaitable[None]]) -> None:
        if hook not in self._hooks:
            self._hooks.append(hook)

    def unregister(self, hook: Callable[[AsyncSession, E], Awaitable[None]]) -> None:
        if hook in self._hooks:
            self._hooks.remove(hook)

    @property
    def hooks(self) -> tuple[Callable[[AsyncSession, E], Awaitable[None]], ...]:
        return tuple(self._hooks)

    async def emit(self, db: AsyncSession, event: E) -> None:
        """Run every hook; an exception propagates (and rolls the caller's transaction back)."""
        for hook in self._hooks:
            await hook(db, event)


on_report_resolved: HookRegistry[ReportResolved] = HookRegistry("on_report_resolved")


@dataclass(frozen=True, slots=True)
class Notice:
    """What the reporter's inbox item says."""

    title: str
    body: str
    icon: str
    action: dict[str, Any] | None
    key: str  # de-duplication key: one item per report


_NOTICES: dict[ReportResolution, tuple[str, str, str]] = {
    ReportResolution.FIXED: (
        "Thanks, we fixed that question",
        "You reported a problem with a question and you were right. It has been corrected.",
        "checkCircle",
    ),
    ReportResolution.RETIRED: (
        "Thanks, we removed that question",
        "You reported a problem with a question. We've taken it out of practice and battles.",
        "checkCircle",
    ),
    ReportResolution.REJECTED: (
        "We checked the question you reported",
        "Our reviewers looked at it again and found it correct as it is. Thanks for helping!",
        "info",
    ),
}


def report_outcome_notice(event: ReportResolved) -> Notice:
    """The inbox item for ``event`` (the admin's note is internal and never shown)."""
    title, body, icon = _NOTICES[event.resolution]
    return Notice(title, body, icon, None, f"question_report:{event.report_id}")
