"""Admin views for tournaments: recurring templates, one-off tournaments and cancelling.

Writes are audited like every admin view (``AuditedView``). A tournament can be edited only
before registration opens; after that the only change is **Cancel**, which refunds everyone
(``t.cancelled`` with reason ``admin``) and is audited too.
"""

import uuid
from datetime import datetime
from typing import Any, ClassVar

from sqladmin import ModelView, action
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from starlette.requests import Request
from starlette.responses import RedirectResponse, Response
from wtforms import (
    BooleanField,
    DateTimeLocalField,
    Form,
    IntegerField,
    SelectField,
    StringField,
    TextAreaField,
)
from wtforms.validators import DataRequired, InputRequired, Length, NumberRange, Optional

from app.core.clock import IST
from app.modules.admin.context import AdminContext, audit_entry, snapshot
from app.modules.admin.views import AuditedView
from app.modules.content.models import Subject
from app.modules.tournaments import rules
from app.modules.tournaments.lifecycle import cancel
from app.modules.tournaments.models import (
    ENTRY_FEES,
    TERMINAL,
    Goal,
    Tournament,
    TournamentStatus,
    TournamentTemplate,
)

ARENA = "Arena"
_GOALS = [(goal.value, goal.value.upper() if goal != Goal.ANY else "Any") for goal in Goal]
_FEES = [(str(fee), "Free" if fee == 0 else str(fee)) for fee in ENTRY_FEES]


class _TournamentFields(Form):
    title = StringField("Title", validators=[DataRequired(), Length(max=80)])
    description = TextAreaField("Description", validators=[Optional(), Length(max=2000)])
    subject = StringField(
        "Subject",
        validators=[Optional()],
        description="physics, chemistry, biology, maths; blank = All",
    )
    goal = SelectField("Exam", choices=_GOALS)
    rounds = IntegerField("Rounds", default=5, validators=[InputRequired(), NumberRange(3, 6)])
    entry_fee = SelectField("Entry fee", choices=_FEES, default="0")
    prize_pool = IntegerField("Prize pool", default=0, validators=[InputRequired(), NumberRange(0)])
    capacity = IntegerField(
        "Capacity", default=64, validators=[InputRequired(), NumberRange(4, 256)]
    )
    min_players = IntegerField(
        "Minimum players", default=8, validators=[InputRequired(), NumberRange(4, 256)]
    )


class TemplateForm(_TournamentFields):
    rrule = StringField(
        "Repeat (RRULE, IST)",
        validators=[DataRequired()],
        description="e.g. FREQ=DAILY;BYHOUR=19;BYMINUTE=30 or FREQ=WEEKLY;BYDAY=SU;BYHOUR=18",
    )
    reg_opens_before_min = IntegerField(
        "Registration opens (minutes before)",
        default=1440,
        validators=[InputRequired(), NumberRange(16)],
    )
    active = BooleanField("Active", default=True)


class TournamentForm(_TournamentFields):
    reg_opens_at = DateTimeLocalField(
        "Registration opens (IST)", format="%Y-%m-%dT%H:%M", validators=[DataRequired()]
    )
    starts_at = DateTimeLocalField(
        "Starts (IST)", format="%Y-%m-%dT%H:%M", validators=[DataRequired()]
    )


async def _fields(db: AsyncSession, data: dict[str, Any]) -> dict[str, Any]:
    """Validated columns shared by templates and tournaments."""
    slug = str(data.get("subject") or "").strip().lower() or None
    subject_id = None
    if slug is not None:
        subject_id = await db.scalar(select(Subject.id).where(Subject.slug == slug))
        if subject_id is None:
            raise ValueError(f"Unknown subject {slug!r}.")
    goal = str(data["goal"])
    if not rules.goal_allowed(goal, slug):
        raise ValueError("Exam 'any' is only allowed for Physics or Chemistry.")
    if int(data["min_players"]) > int(data["capacity"]):
        raise ValueError("Minimum players can't exceed the capacity.")
    return {
        "title": str(data["title"]).strip(),
        "description": str(data.get("description") or ""),
        "subject_id": subject_id,
        "goal": goal,
        "rounds": int(data["rounds"]),
        "entry_fee": int(data["entry_fee"]),
        "prize_pool": int(data["prize_pool"]),
        "capacity": int(data["capacity"]),
        "min_players": int(data["min_players"]),
    }


async def _form_values(db: AsyncSession, row: Any) -> dict[str, Any]:
    subject = await db.get(Subject, row.subject_id) if row.subject_id is not None else None
    return {
        "title": row.title,
        "description": row.description,
        "subject": subject.slug if subject else "",
        "goal": row.goal,
        "rounds": row.rounds,
        "entry_fee": str(row.entry_fee),
        "prize_pool": row.prize_pool,
        "capacity": row.capacity,
        "min_players": row.min_players,
    }


def _ist(value: datetime) -> datetime:
    """A naive form value is IST wall-clock time."""
    return value.replace(tzinfo=IST) if value.tzinfo is None else value


class TournamentTemplateAdmin(AuditedView, model=TournamentTemplate):
    name, name_plural, icon, category = (
        "Recurring tournament",
        "Recurring tournaments",
        "fa-solid fa-repeat",
        ARENA,
    )
    identity = "tournament-template"
    entity_type = "tournament_template"
    can_create = True
    form = TemplateForm
    column_list: ClassVar[list[Any]] = [
        TournamentTemplate.title,
        TournamentTemplate.goal,
        TournamentTemplate.rrule,
        TournamentTemplate.entry_fee,
        TournamentTemplate.prize_pool,
        TournamentTemplate.active,
    ]

    async def get_form_data_for_edit(self, obj: Any) -> dict[str, Any]:
        async with self.session_maker() as db:
            values = await _form_values(db, obj)
        template: TournamentTemplate = obj
        return {
            **values,
            "rrule": template.rrule,
            "reg_opens_before_min": template.reg_opens_before_min,
            "active": template.active,
        }

    async def _apply(self, db: AsyncSession, obj: Any, data: dict[str, Any]) -> None:
        for name, value in (await _fields(db, data)).items():
            setattr(obj, name, value)
        try:
            rules.parse_rrule(str(data["rrule"]))
        except rules.RRuleError as exc:
            raise ValueError(str(exc)) from exc
        obj.rrule = str(data["rrule"]).strip()
        obj.reg_opens_before_min = int(data["reg_opens_before_min"])
        obj.active = bool(data.get("active"))

    async def apply_create(
        self, db: AsyncSession, request: Request, obj: Any, data: dict[str, Any]
    ) -> None:
        await self._apply(db, obj, data)

    async def apply_update(
        self, db: AsyncSession, request: Request, obj: Any, data: dict[str, Any]
    ) -> Any:
        await self._apply(db, obj, data)
        return obj


class TournamentAdmin(AuditedView, model=Tournament):
    name, name_plural, icon, category = "Tournament", "Tournaments", "fa-solid fa-trophy", ARENA
    identity = "tournament"
    entity_type = "tournament"
    can_create = True
    form = TournamentForm
    column_list: ClassVar[list[Any]] = [
        Tournament.title,
        Tournament.status,
        Tournament.starts_at,
        Tournament.players,
        Tournament.entry_fee,
        Tournament.prize_pool,
        Tournament.current_round,
    ]
    column_default_sort: ClassVar[Any] = [(Tournament.starts_at, True)]
    column_searchable_list: ClassVar[list[Any]] = [Tournament.title]

    async def get_form_data_for_edit(self, obj: Any) -> dict[str, Any]:
        async with self.session_maker() as db:
            values = await _form_values(db, obj)
        t: Tournament = obj
        return {
            **values,
            "reg_opens_at": t.reg_opens_at.astimezone(IST).replace(tzinfo=None),
            "starts_at": t.starts_at.astimezone(IST).replace(tzinfo=None),
        }

    async def _apply(self, db: AsyncSession, obj: Any, data: dict[str, Any]) -> None:
        for name, value in (await _fields(db, data)).items():
            setattr(obj, name, value)
        reg_opens_at, starts_at = _ist(data["reg_opens_at"]), _ist(data["starts_at"])
        if reg_opens_at >= rules.at_risk_at(starts_at):
            raise ValueError("Registration must open at least 30 minutes before the start.")
        obj.reg_opens_at, obj.starts_at = reg_opens_at, starts_at
        obj.next_action_at = reg_opens_at

    async def apply_create(
        self, db: AsyncSession, request: Request, obj: Any, data: dict[str, Any]
    ) -> None:
        obj.status = TournamentStatus.SCHEDULED.value
        await self._apply(db, obj, data)

    async def apply_update(
        self, db: AsyncSession, request: Request, obj: Any, data: dict[str, Any]
    ) -> Any:
        if obj.status != TournamentStatus.SCHEDULED:
            raise ValueError("Only a tournament whose registration hasn't opened can be edited.")
        await self._apply(db, obj, data)
        return obj

    @action(
        name="cancel",
        label="Cancel and refund",
        confirmation_message="Cancel the selected tournaments and refund every player?",
    )
    async def cancel_action(self, request: Request) -> Response:
        context: AdminContext = request.state.admin_context
        ids = [pk for pk in request.query_params.get("pks", "").split(",") if pk]
        for pk in ids:
            async with self.session_maker(expire_on_commit=False) as db:
                t = await db.get(
                    Tournament, uuid.UUID(pk), with_for_update=True, populate_existing=True
                )
                if t is None or t.status in TERMINAL:
                    continue
                before = snapshot(t)
                await cancel(db, t, reason="admin", now=context.now())
                db.add(
                    audit_entry(
                        request,
                        action="tournament.cancelled",
                        entity_type=self.entity_type,
                        entity_id=pk,
                        before=before,
                        after=snapshot(t),
                    )
                )
                await db.commit()
        return RedirectResponse(
            request.url_for("admin:list", identity=self.identity), status_code=302
        )


VIEWS: tuple[type[ModelView], ...] = (TournamentAdmin, TournamentTemplateAdmin)
