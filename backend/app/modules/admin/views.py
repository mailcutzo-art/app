"""The admin panel's model views.

Every write goes through ``AuditedView``: the change and its ``audit_log`` row (before and after
JSON, the admin's id and IP) commit in one transaction. Nothing is ever hard-deleted except
``app_config`` rows; content is retired instead.
"""

import json
import uuid
from datetime import UTC
from typing import Any, ClassVar

from markupsafe import Markup, escape
from sqladmin import ModelView, expose
from sqladmin.filters import ForeignKeyFilter, StaticValuesFilter
from sqladmin.helpers import get_object_identifier
from sqlalchemy import Select, select
from sqlalchemy.ext.asyncio import AsyncSession
from starlette.exceptions import HTTPException
from starlette.requests import Request
from starlette.responses import RedirectResponse, Response

from app.modules.admin.context import AdminContext, audit_entry, snapshot
from app.modules.admin.forms import (
    ANSWER_LETTERS,
    AppConfigForm,
    PassageForm,
    QuestionForm,
    UserForm,
    WordPuzzleForm,
)
from app.modules.content.editing import (
    InvalidEdit,
    bump_content_version,
    question_snapshot,
    revise_question,
)
from app.modules.content.models import (
    Chapter,
    ContentSource,
    ContentStatus,
    ExamGoal,
    Passage,
    Question,
    QuestionReport,
    ReportReason,
    ReportResolution,
    ReportStatus,
    Subject,
    Topic,
    WordPuzzle,
)
from app.modules.content.report_review import ReportNotOpen, resolve_report
from app.modules.system.models import AppConfig, AuditLog
from app.modules.system.runtime import check_runtime_value
from app.modules.users.authz import invalidate_authz
from app.modules.users.models import Role, User, UserStatus

CONTENT = "Content"
PEOPLE = "People"
SYSTEM = "System"


def _context(request: Request) -> AdminContext:
    context: AdminContext = request.state.admin_context
    return context


class AuditedView(ModelView):
    """Creates, updates and deletes that write an audit-log row in the same transaction.

    Subclasses change rows in ``apply_create`` / ``apply_update`` and raise ``ValueError`` with
    a message for the admin when a change isn't allowed (SQLAdmin shows it above the form).
    """

    entity_type: ClassVar[str]
    can_delete = False
    can_export = False
    page_size = 50
    page_size_options: ClassVar[list[int]] = [25, 50, 100]

    async def get_form_data_for_edit(self, obj: Any) -> dict[str, Any]:
        return snapshot(obj)

    async def apply_create(
        self, db: AsyncSession, request: Request, obj: Any, data: dict[str, Any]
    ) -> None:
        for name, value in data.items():
            setattr(obj, name, value)

    async def apply_update(
        self, db: AsyncSession, request: Request, obj: Any, data: dict[str, Any]
    ) -> Any:
        """Change ``obj``; returns the row that holds the result (a new one for versions)."""
        for name, value in data.items():
            setattr(obj, name, value)
        return obj

    async def after_commit(self, request: Request, obj: Any) -> None:
        """Side effects outside the database (cache invalidation), after the commit."""

    async def insert_model(self, request: Request, data: dict[str, Any]) -> Any:
        async with self.session_maker(expire_on_commit=False) as db:
            obj = self.model()
            await self.apply_create(db, request, obj, data)
            db.add(obj)
            await db.flush()
            db.add(
                audit_entry(
                    request,
                    action=f"{self.entity_type}.created",
                    entity_type=self.entity_type,
                    entity_id=str(get_object_identifier(obj)),
                    before=None,
                    after=snapshot(obj),
                )
            )
            await db.commit()
        await self.after_commit(request, obj)
        return obj

    async def update_model(self, request: Request, pk: str, data: dict[str, Any]) -> Any:
        async with self.session_maker(expire_on_commit=False) as db:
            obj = await db.scalar(self._stmt_by_identifier(pk).with_for_update())
            if obj is None:
                raise HTTPException(status_code=404)
            before = snapshot(obj)
            result = await self.apply_update(db, request, obj, data)
            await db.flush()
            if result is not obj:
                self._audit_version(db, request, obj, result, before)
            elif snapshot(obj) != before:
                db.add(
                    audit_entry(
                        request,
                        action=f"{self.entity_type}.updated",
                        entity_type=self.entity_type,
                        entity_id=str(get_object_identifier(obj)),
                        before=before,
                        after=snapshot(obj),
                    )
                )
            await db.commit()
        await self.after_commit(request, result)
        return result

    def _audit_version(
        self, db: AsyncSession, request: Request, old: Any, new: Any, before: dict[str, Any]
    ) -> None:
        db.add(
            audit_entry(
                request,
                action=f"{self.entity_type}.superseded",
                entity_type=self.entity_type,
                entity_id=str(get_object_identifier(old)),
                before=before,
                after=snapshot(new),
            )
        )

    async def delete_model(self, request: Request, pk: Any) -> None:
        if not self.can_delete:
            raise HTTPException(status_code=403)
        async with self.session_maker(expire_on_commit=False) as db:
            obj = await db.scalar(self._stmt_by_identifier(str(pk)).with_for_update())
            if obj is None:
                raise HTTPException(status_code=404)
            db.add(
                audit_entry(
                    request,
                    action=f"{self.entity_type}.deleted",
                    entity_type=self.entity_type,
                    entity_id=str(pk),
                    before=snapshot(obj),
                    after=None,
                )
            )
            await db.delete(obj)
            await db.commit()


class ReadOnlyView(ModelView):
    can_create = False
    can_edit = False
    can_delete = False
    can_export = False
    page_size = 50
    page_size_options: ClassVar[list[int]] = [25, 50, 100]


# People ---------------------------------------------------------------------------------


class UserAdmin(AuditedView, model=User):
    name, name_plural, icon, category = "User", "Users", "fa-solid fa-user", PEOPLE
    entity_type = "user"
    can_create = False
    form = UserForm
    column_list: ClassVar[list[Any]] = [
        User.handle,
        User.display_name,
        User.email,
        User.status,
        User.roles,
        User.created_at,
        User.last_seen_at,
    ]
    column_searchable_list: ClassVar[list[Any]] = [User.handle, User.email, User.display_name]
    column_sortable_list: ClassVar[list[Any]] = [User.handle, User.created_at, User.last_seen_at]
    column_default_sort: ClassVar[Any] = [(User.created_at, True)]
    column_filters: ClassVar[list[Any]] = [
        StaticValuesFilter(User.status, [(status.value, status.value) for status in UserStatus])
    ]

    async def get_form_data_for_edit(self, obj: Any) -> dict[str, Any]:
        user: User = obj
        until = (
            user.banned_until.astimezone(UTC).replace(tzinfo=None) if user.banned_until else None
        )
        return {
            "status": user.status,
            "roles": list(user.roles),
            "ban_reason": user.ban_reason or "",
            "banned_until": until,
        }

    async def apply_update(
        self, db: AsyncSession, request: Request, obj: Any, data: dict[str, Any]
    ) -> Any:
        user: User = obj
        me = request.state.admin_id
        status = str(data["status"])
        roles = sorted({Role.USER.value, *(str(role) for role in data.get("roles") or [])})
        if user.status in (UserStatus.PENDING_DELETION, UserStatus.DELETED):
            raise ValueError("This account is being deleted; it can't be changed here.")
        if status not in {s.value for s in UserStatus}:
            raise ValueError("Choose a status.")
        if user.id == me and (status != UserStatus.ACTIVE or Role.ADMIN not in roles):
            raise ValueError("You can't ban, restrict or demote yourself.")
        reason = data.get("ban_reason") or None
        until = data.get("banned_until")
        if status == UserStatus.BANNED:
            if reason is None:
                raise ValueError("A ban needs a reason.")
            until = until.replace(tzinfo=UTC) if until is not None else None
            if until is not None and until <= _context(request).now():
                raise ValueError("A temporary ban must end in the future.")
        else:
            reason, until = None, None
        revoke = (
            status == UserStatus.BANNED
            and (user.status != status or user.ban_reason != reason or user.banned_until != until)
        ) or set(user.roles) != set(roles)
        user.status, user.roles = status, roles
        user.ban_reason, user.banned_until = reason, until
        if revoke:
            # Every access token in circulation stops working, and refresh is refused while
            # the ban lasts, so the player is signed out everywhere.
            user.token_version += 1
        return user

    async def after_commit(self, request: Request, obj: Any) -> None:
        await invalidate_authz(_context(request).redis, obj.id)


# Content --------------------------------------------------------------------------------


class _ChapterFilter:
    """Chapters of the subject chosen in the subject filter (all chapters otherwise)."""

    has_operator = False
    template = "sqladmin/filters/lookup_filter.html"
    title = "Chapter"
    parameter_name = "chapter"

    async def lookups(self, request: Request, model: Any, run_query: Any) -> list[tuple[str, str]]:
        stmt = select(Chapter.id, Chapter.name).order_by(Chapter.subject_id, Chapter.sort)
        subject = request.query_params.get("subject", "")
        if subject.isdigit():
            stmt = stmt.where(Chapter.subject_id == int(subject))
        return [("__all", "All")] + [(str(key), name) for key, name in await run_query(stmt)]

    async def get_filtered_query(self, query: Select[Any], value: Any, model: Any) -> Any:
        if isinstance(value, str) and value.isdigit():
            return query.where(model.chapter_id == int(value))
        return query


def _stem_preview(model: Any, attribute: Any) -> str:
    stem: str = model.stem
    return stem if len(stem) <= 90 else stem[:89] + "…"


def _options_detail(model: Any, attribute: Any) -> Markup:
    items = []
    for index, option in enumerate(model.options):
        mark = " ✓" if index == model.answer else ""
        items.append(f"<li>{ANSWER_LETTERS[index]}. {escape(option)}{escape(mark)}</li>")
    return Markup("<ol style='list-style:none;padding:0'>" + "".join(items) + "</ol>")  # noqa: S704 - escaped above


class QuestionAdmin(AuditedView, model=Question):
    name, name_plural, icon, category = (
        "Question",
        "Questions",
        "fa-solid fa-circle-question",
        CONTENT,
    )
    entity_type = "question"
    can_create = False  # new questions come through the importer
    form = QuestionForm
    column_list: ClassVar[list[Any]] = [
        Question.external_id,
        Question.stem,
        Question.status,
        Question.category,
        Question.difficulty,
        Question.battle_pool,
        Question.subject_id,
        Question.chapter_id,
        Question.updated_at,
    ]
    column_details_list: ClassVar[list[Any]] = [
        Question.id,
        Question.external_id,
        Question.status,
        Question.kind,
        Question.subject_id,
        Question.chapter_id,
        Question.topic_id,
        Question.passage_id,
        Question.category,
        Question.exams,
        Question.difficulty,
        Question.battle_pool,
        Question.stem,
        Question.options,
        Question.explanation,
        Question.tags,
        Question.seq,
        Question.source,
        Question.supersedes_id,
        Question.content_hash,
        Question.created_at,
        Question.updated_at,
    ]
    column_formatters: ClassVar[dict[Any, Any]] = {Question.stem: _stem_preview}
    column_formatters_detail: ClassVar[dict[Any, Any]] = {Question.options: _options_detail}
    column_searchable_list: ClassVar[list[Any]] = [Question.external_id, Question.search_text]
    column_sortable_list: ClassVar[list[Any]] = [
        Question.external_id,
        Question.difficulty,
        Question.updated_at,
        Question.seq,
    ]
    column_default_sort: ClassVar[Any] = [(Question.updated_at, True)]
    column_filters: ClassVar[list[Any]] = [
        ForeignKeyFilter(
            Question.subject_id,
            Subject.name,
            foreign_model=Subject,
            title="Subject",
            parameter_name="subject",
        ),
        _ChapterFilter(),
        StaticValuesFilter(
            Question.status, [(status.value, status.value) for status in ContentStatus]
        ),
        StaticValuesFilter(
            Question.source, [(source.value, source.value) for source in ContentSource]
        ),
    ]

    async def get_form_data_for_edit(self, obj: Any) -> dict[str, Any]:
        question: Question = obj
        return {
            "topic_id": question.topic_id,
            "category": question.category,
            "difficulty": question.difficulty,
            "exams": list(question.exams or []),
            "battle_pool": question.battle_pool,
            "status": question.status,
            "stem": question.stem,
            **{
                f"option_{letter.lower()}": text
                for letter, text in zip("ABCD", question.options, strict=True)
            },
            "answer": ANSWER_LETTERS[question.answer],
            "explanation": question.explanation,
            "tags": ", ".join(question.tags),
        }

    async def apply_update(
        self, db: AsyncSession, request: Request, obj: Any, data: dict[str, Any]
    ) -> Any:
        question: Question = obj
        changes: dict[str, Any] = {
            "category": data["category"],
            "difficulty": data["difficulty"],
            "exams": list(data.get("exams") or []) or None,
            "battle_pool": data["battle_pool"],
            "status": data["status"],
            "stem": data["stem"],
            "options": [str(data[f"option_{letter}"]).strip() for letter in "abcd"],
            "answer": ANSWER_LETTERS.index(str(data["answer"])),
            "explanation": data["explanation"],
            "tags": [tag.strip() for tag in str(data.get("tags") or "").split(",") if tag.strip()],
        }
        topic_id = data.get("topic_id")
        if topic_id is not None and topic_id != question.topic_id:
            topic = await db.get(Topic, topic_id)
            if topic is None:
                raise ValueError(f"There is no topic {topic_id}.")
            changes["topic_id"], changes["chapter_id"] = topic.id, topic.chapter_id
        try:
            revision = await revise_question(db, question, changes, now=_context(request).now())
        except InvalidEdit as exc:
            raise ValueError("; ".join(exc.problems)) from exc
        if revision.changed and ContentStatus.PUBLISHED in (
            revision.before["status"],
            revision.question.status,
        ):
            await bump_content_version(db, now=_context(request).now())
        return revision.question

    def _audit_version(
        self, db: AsyncSession, request: Request, old: Any, new: Any, before: dict[str, Any]
    ) -> None:
        # The new version's own row, and the old one's retirement.
        db.add(
            audit_entry(
                request,
                action="question.superseded",
                entity_type="question",
                entity_id=str(old.id),
                before=before,
                after=question_snapshot(old),
            )
        )
        db.add(
            audit_entry(
                request,
                action="question.created",
                entity_type="question",
                entity_id=str(new.id),
                before=None,
                after=question_snapshot(new),
            )
        )


class SubjectAdmin(ReadOnlyView, model=Subject):
    name, name_plural, icon, category = "Subject", "Subjects", "fa-solid fa-book", CONTENT
    column_list: ClassVar[list[Any]] = [
        Subject.id,
        Subject.slug,
        Subject.name,
        Subject.tone,
        Subject.sort,
    ]
    column_default_sort: ClassVar[Any] = [(Subject.sort, False)]


class ExamAdmin(ReadOnlyView, model=ExamGoal):
    name, name_plural, icon, category = "Exam", "Exams", "fa-solid fa-graduation-cap", CONTENT
    column_list: ClassVar[list[Any]] = [ExamGoal.id, ExamGoal.slug, ExamGoal.name]


class ChapterAdmin(ReadOnlyView, model=Chapter):
    name, name_plural, icon, category = "Chapter", "Chapters", "fa-solid fa-bookmark", CONTENT
    column_list: ClassVar[list[Any]] = [
        Chapter.id,
        Chapter.subject_id,
        Chapter.slug,
        Chapter.name,
        Chapter.sort,
        Chapter.is_active,
    ]
    column_searchable_list: ClassVar[list[Any]] = [Chapter.slug, Chapter.name]
    column_default_sort: ClassVar[Any] = [(Chapter.subject_id, False), (Chapter.sort, False)]
    column_filters: ClassVar[list[Any]] = [
        ForeignKeyFilter(
            Chapter.subject_id,
            Subject.name,
            foreign_model=Subject,
            title="Subject",
            parameter_name="subject",
        )
    ]


class TopicAdmin(ReadOnlyView, model=Topic):
    name, name_plural, icon, category = "Topic", "Topics", "fa-solid fa-tag", CONTENT
    column_list: ClassVar[list[Any]] = [
        Topic.id,
        Topic.chapter_id,
        Topic.slug,
        Topic.name,
        Topic.sort,
        Topic.is_active,
    ]
    column_searchable_list: ClassVar[list[Any]] = [Topic.slug, Topic.name]
    column_default_sort: ClassVar[Any] = [(Topic.chapter_id, False), (Topic.sort, False)]
    column_filters: ClassVar[list[Any]] = [_ChapterFilter()]


class PassageAdmin(AuditedView, model=Passage):
    name, name_plural, icon, category = "Passage", "Passages", "fa-solid fa-scroll", CONTENT
    entity_type = "passage"
    can_create = False
    form = PassageForm
    column_list: ClassVar[list[Any]] = [
        Passage.external_id,
        Passage.title,
        Passage.subject_id,
        Passage.difficulty,
        Passage.status,
        Passage.updated_at,
    ]
    column_searchable_list: ClassVar[list[Any]] = [Passage.external_id, Passage.title]
    column_filters: ClassVar[list[Any]] = [
        StaticValuesFilter(
            Passage.status, [(status.value, status.value) for status in ContentStatus]
        )
    ]

    async def get_form_data_for_edit(self, obj: Any) -> dict[str, Any]:
        passage: Passage = obj
        return {
            "title": passage.title,
            "body": passage.body,
            "difficulty": passage.difficulty,
            "status": passage.status,
        }


class WordPuzzleAdmin(AuditedView, model=WordPuzzle):
    name, name_plural, icon, category = "Word", "Guess the Word", "fa-solid fa-spell-check", CONTENT
    entity_type = "word_puzzle"
    can_create = True
    form = WordPuzzleForm
    column_list: ClassVar[list[Any]] = [
        WordPuzzle.external_id,
        WordPuzzle.word,
        WordPuzzle.clue,
        WordPuzzle.subject_id,
        WordPuzzle.difficulty,
        WordPuzzle.status,
    ]
    column_searchable_list: ClassVar[list[Any]] = [WordPuzzle.word, WordPuzzle.external_id]
    column_filters: ClassVar[list[Any]] = [
        ForeignKeyFilter(
            WordPuzzle.subject_id,
            Subject.name,
            foreign_model=Subject,
            title="Subject",
            parameter_name="subject",
        ),
        StaticValuesFilter(
            WordPuzzle.status, [(status.value, status.value) for status in ContentStatus]
        ),
    ]

    async def get_form_data_for_edit(self, obj: Any) -> dict[str, Any]:
        word: WordPuzzle = obj
        return {
            "external_id": word.external_id,
            "subject_id": word.subject_id,
            "word": word.word,
            "clue": word.clue,
            "difficulty": word.difficulty,
            "status": word.status,
        }

    async def apply_create(
        self, db: AsyncSession, request: Request, obj: Any, data: dict[str, Any]
    ) -> None:
        await self._check(db, data, current=None)
        await super().apply_create(db, request, obj, data)
        obj.source = ContentSource.IMPORT.value

    async def apply_update(
        self, db: AsyncSession, request: Request, obj: Any, data: dict[str, Any]
    ) -> Any:
        await self._check(db, data, current=obj)
        return await super().apply_update(db, request, obj, data)

    @staticmethod
    async def _check(db: AsyncSession, data: dict[str, Any], current: WordPuzzle | None) -> None:
        if await db.get(Subject, data["subject_id"]) is None:
            raise ValueError(f"There is no subject {data['subject_id']}.")
        taken = await db.scalar(
            select(WordPuzzle.id).where(WordPuzzle.external_id == data["external_id"])
        )
        if taken is not None and (current is None or taken != current.id):
            raise ValueError(f"The id {data['external_id']} is already used.")


# The report review queue ---------------------------------------------------------------


def _review_link(model: Any, attribute: Any) -> Markup | str:
    if model.status != ReportStatus.OPEN:
        return str(model.resolution or model.status)
    return Markup('<a class="btn btn-sm btn-primary" href="{}">Review</a>').format(
        f"resolve/{model.id}"
    )


class QuestionReportAdmin(ReadOnlyView, model=QuestionReport):
    name, name_plural, icon, category = (
        "Question report",
        "Question reports",
        "fa-solid fa-flag",
        CONTENT,
    )
    identity = "question-report"
    column_list: ClassVar[list[Any]] = [
        QuestionReport.created_at,
        QuestionReport.reason,
        QuestionReport.note,
        QuestionReport.question_id,
        QuestionReport.status,
        QuestionReport.id,
    ]
    column_labels: ClassVar[dict[Any, str]] = {QuestionReport.id: "Review"}
    column_formatters: ClassVar[dict[Any, Any]] = {QuestionReport.id: _review_link}
    column_default_sort: ClassVar[Any] = [(QuestionReport.created_at, False)]
    column_filters: ClassVar[list[Any]] = [
        StaticValuesFilter(
            QuestionReport.status,
            [(status.value, status.value) for status in ReportStatus],
            default_value=ReportStatus.OPEN.value,
        ),
        StaticValuesFilter(
            QuestionReport.reason, [(reason.value, reason.value) for reason in ReportReason]
        ),
    ]

    @expose("/resolve/{pk}", methods=["GET", "POST"])
    async def resolve(self, request: Request) -> Response:
        try:
            report_id = uuid.UUID(request.path_params["pk"])
        except ValueError as exc:
            raise HTTPException(status_code=404) from exc
        context = _context(request)
        error = None
        if request.method == "POST":
            form = await request.form()
            choice = str(form.get("resolution") or "")
            if choice not in {resolution.value for resolution in ReportResolution}:
                error = "Choose how the report was resolved."
            else:
                async with self.session_maker(expire_on_commit=False) as db:
                    try:
                        await resolve_report(
                            db,
                            report_id,
                            ReportResolution(choice),
                            note=str(form.get("note") or ""),
                            admin_id=request.state.admin_id,
                            ip=context.client_ip(request),
                            now=context.now(),
                        )
                    except ReportNotOpen:
                        error = "This report was already closed."
                    else:
                        if choice == ReportResolution.RETIRED:
                            await bump_content_version(db, now=context.now())
                        await db.commit()
                if error is None:
                    return RedirectResponse(
                        request.url_for("admin:list", identity=self.identity), status_code=302
                    )
        async with self.session_maker(expire_on_commit=False) as db:
            report = await db.get(QuestionReport, report_id)
            if report is None:
                raise HTTPException(status_code=404)
            question = await db.get_one(Question, report.question_id)
            open_reports = list(
                await db.scalars(
                    select(QuestionReport)
                    .where(
                        QuestionReport.question_id == report.question_id,
                        QuestionReport.status == ReportStatus.OPEN.value,
                    )
                    .order_by(QuestionReport.created_at)
                )
            )
            live = await db.scalar(
                select(Question).where(
                    Question.external_id == question.external_id,
                    Question.status != ContentStatus.RETIRED.value,
                )
            )
        return await self.templates.TemplateResponse(
            request,
            "admin/resolve_report.html",
            {
                "title": "Review a question report",
                "report": report,
                "question": question,
                "live": live,
                "open_reports": open_reports,
                "letters": ANSWER_LETTERS,
                "resolutions": list(ReportResolution),
                "error": error,
                "model_view": self,
            },
            status_code=400 if error else 200,
        )


# System ---------------------------------------------------------------------------------


class AppConfigAdmin(AuditedView, model=AppConfig):
    name, name_plural, icon, category = "Setting", "App config", "fa-solid fa-sliders", SYSTEM
    identity = "app-config"
    entity_type = "app_config"
    can_create = True
    can_delete = True  # removing a key falls back to the environment setting
    form = AppConfigForm
    column_list: ClassVar[list[Any]] = [AppConfig.key, AppConfig.value, AppConfig.updated_at]
    column_details_list: ClassVar[list[Any]] = [
        AppConfig.key,
        AppConfig.value,
        AppConfig.updated_at,
    ]

    async def get_form_data_for_edit(self, obj: Any) -> dict[str, Any]:
        row: AppConfig = obj
        return {"key": row.key, "value": json.dumps(row.value, ensure_ascii=False)}

    @staticmethod
    def _value(data: dict[str, Any]) -> tuple[str, Any]:
        key = str(data["key"]).strip()
        value = json.loads(str(data["value"]))
        problem = check_runtime_value(key, value)
        if problem is not None:
            raise ValueError(problem)
        return key, value

    async def apply_create(
        self, db: AsyncSession, request: Request, obj: Any, data: dict[str, Any]
    ) -> None:
        key, value = self._value(data)
        if await db.get(AppConfig, key) is not None:
            raise ValueError(f"{key} already exists; edit it instead.")
        obj.key, obj.value = key, value

    async def apply_update(
        self, db: AsyncSession, request: Request, obj: Any, data: dict[str, Any]
    ) -> Any:
        key, value = self._value(data)
        if key != obj.key:
            raise ValueError("The key can't be renamed; add a new setting instead.")
        obj.value = value
        return obj


class AuditLogAdmin(ReadOnlyView, model=AuditLog):
    name, name_plural, icon, category = "Audit entry", "Audit log", "fa-solid fa-scroll", SYSTEM
    identity = "audit-log"
    column_list: ClassVar[list[Any]] = [
        AuditLog.created_at,
        AuditLog.action,
        AuditLog.entity_type,
        AuditLog.entity_id,
        AuditLog.actor_id,
        AuditLog.ip,
    ]
    column_details_list: ClassVar[list[Any]] = [
        AuditLog.id,
        AuditLog.created_at,
        AuditLog.action,
        AuditLog.entity_type,
        AuditLog.entity_id,
        AuditLog.actor_id,
        AuditLog.ip,
        AuditLog.before,
        AuditLog.after,
    ]
    column_searchable_list: ClassVar[list[Any]] = [AuditLog.entity_id, AuditLog.action]
    column_default_sort: ClassVar[Any] = [(AuditLog.created_at, True)]
    column_filters: ClassVar[list[Any]] = [
        StaticValuesFilter(
            AuditLog.entity_type,
            [
                (name, name)
                for name in (
                    "user",
                    "question",
                    "question_report",
                    "question_import",
                    "passage",
                    "word_puzzle",
                    "app_config",
                )
            ],
        )
    ]


VIEWS: tuple[type[ModelView], ...] = (
    QuestionReportAdmin,
    QuestionAdmin,
    PassageAdmin,
    WordPuzzleAdmin,
    SubjectAdmin,
    ExamAdmin,
    ChapterAdmin,
    TopicAdmin,
    UserAdmin,
    AppConfigAdmin,
    AuditLogAdmin,
)
