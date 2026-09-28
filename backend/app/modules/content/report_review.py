"""The admin review queue for question reports.

An admin closes a report as ``fixed`` (the question was corrected: edit it first, which makes a
new version), ``rejected`` (it is right as it is) or ``retired`` (it leaves practice and
battles). Every open report on the same question closes with it, each reporter's
``on_report_resolved`` hook runs, and each closed report is audit-logged.
"""

import uuid
from dataclasses import dataclass
from datetime import datetime
from typing import Any

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.modules.content.editing import question_snapshot
from app.modules.content.hooks import ReportResolved, on_report_resolved
from app.modules.content.models import (
    ContentStatus,
    Question,
    QuestionReport,
    ReportResolution,
    ReportStatus,
)
from app.modules.content.refs import question_ref
from app.modules.system.models import AuditLog

MAX_NOTE = 1000


class ReportNotOpen(Exception):
    """The report doesn't exist or was already closed."""


@dataclass(frozen=True, slots=True)
class ReviewOutcome:
    reports: list[QuestionReport]  # every report closed, the chosen one first
    question_retired: bool


def report_snapshot(report: QuestionReport) -> dict[str, Any]:
    return {
        "id": str(report.id),
        "user_id": str(report.user_id),
        "question_id": str(report.question_id),
        "reason": report.reason,
        "note": report.note,
        "status": report.status,
        "resolution": report.resolution,
        "resolution_note": report.resolution_note,
        "resolved_by": str(report.resolved_by) if report.resolved_by else None,
        "resolved_at": report.resolved_at.isoformat() if report.resolved_at else None,
    }


async def resolve_report(
    db: AsyncSession,
    report_id: uuid.UUID,
    resolution: ReportResolution,
    *,
    note: str | None,
    admin_id: uuid.UUID | None,
    ip: str | None,
    now: datetime,
) -> ReviewOutcome:
    """Close the report and the other open reports on its question. The caller commits."""
    report = await db.get(QuestionReport, report_id, with_for_update=True)
    if report is None or report.status != ReportStatus.OPEN:
        raise ReportNotOpen(str(report_id))
    note = (note or "").strip()[:MAX_NOTE] or None
    others = await db.scalars(
        select(QuestionReport)
        .where(
            QuestionReport.question_id == report.question_id,
            QuestionReport.status == ReportStatus.OPEN.value,
            QuestionReport.id != report.id,
        )
        .order_by(QuestionReport.created_at)
        .with_for_update()
    )
    reports = [report, *others]

    question_retired = False
    if resolution is ReportResolution.RETIRED:
        question = await db.get_one(Question, report.question_id, with_for_update=True)
        if question.status != ContentStatus.RETIRED:
            before = question_snapshot(question)
            question.status = ContentStatus.RETIRED.value
            question.updated_at = now
            question_retired = True
            db.add(
                AuditLog(
                    actor_id=admin_id,
                    action="question.retired",
                    entity_type="question",
                    entity_id=str(question.id),
                    before=before,
                    after=question_snapshot(question),
                    ip=ip,
                )
            )

    for item in reports:
        before = report_snapshot(item)
        item.status = resolution.status.value
        item.resolution = resolution.value
        item.resolution_note = note
        item.resolved_by = admin_id
        item.resolved_at = now
        db.add(
            AuditLog(
                actor_id=admin_id,
                action="question_report.resolved",
                entity_type="question_report",
                entity_id=str(item.id),
                before=before,
                after=report_snapshot(item),
                ip=ip,
            )
        )
    await db.flush()
    for item in reports:
        await on_report_resolved.emit(
            db,
            ReportResolved(
                report_id=item.id,
                user_id=item.user_id,
                question_id=item.question_id,
                question_ref=question_ref(item.question_id),
                reason=item.reason,
                resolution=resolution,
                resolved_at=now,
            ),
        )
    return ReviewOutcome(reports, question_retired)
