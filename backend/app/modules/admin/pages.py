"""Admin pages that aren't a table: the question importer."""

from sqladmin import BaseView, expose
from starlette.datastructures import UploadFile
from starlette.requests import Request
from starlette.responses import Response

from app.modules.admin.context import AdminContext, admin_id
from app.modules.content.importer import (
    CSV_OPTIONAL,
    CSV_REQUIRED,
    MAX_FILE_BYTES,
    MAX_ROWS,
    ImportOptions,
    ImportReport,
    detect_format,
    file_digest,
    import_questions,
    parse_file,
)


class ImportQuestionsPage(BaseView):
    name = "Import questions"
    icon = "fa-solid fa-file-import"
    category = "Content"

    @expose("/import-questions", methods=["GET", "POST"])
    async def import_page(self, request: Request) -> Response:
        report: ImportReport | None = None
        error: str | None = None
        filename = ""
        options = ImportOptions()
        if request.method == "POST":
            # The context manager closes the uploaded file's temporary storage.
            async with request.form(
                max_files=1, max_fields=20, max_part_size=MAX_FILE_BYTES + 1
            ) as form:
                upload = form.get("file")
                options = ImportOptions(
                    dry_run=form.get("dry_run") == "on",
                    publish=form.get("status") == "published",
                    skip_invalid=form.get("skip_invalid") == "on",
                    allow_near_duplicates=form.get("allow_near_duplicates") == "on",
                )
                data = b""
                if isinstance(upload, UploadFile) and upload.filename:
                    filename = upload.filename
                    data = await upload.read(MAX_FILE_BYTES + 1)
            if filename:
                report = await self._run(request, filename, data, options)
            else:
                error = "Choose a CSV or JSON file."
        return await self.templates.TemplateResponse(
            request,
            "admin/import.html",
            {
                "title": "Import questions",
                "report": report,
                "error": error,
                "filename": filename,
                "options": options,
                "csv_required": CSV_REQUIRED,
                "csv_optional": CSV_OPTIONAL,
                "max_rows": MAX_ROWS,
                "max_mb": MAX_FILE_BYTES // (1024 * 1024),
            },
            status_code=400 if error else 200,
        )

    @staticmethod
    async def _run(
        request: Request, filename: str, data: bytes, options: ImportOptions
    ) -> ImportReport:
        context: AdminContext = request.state.admin_context
        rows, problems = parse_file(data, detect_format(filename, data))
        async with context.sessionmaker() as db:
            report = await import_questions(
                db,
                rows,
                options,
                source_name=filename,
                source_digest=file_digest(data),
                actor_id=admin_id(request),
                ip=context.client_ip(request),
                now=context.now(),
                file_problems=problems,
            )
            if report.imported:
                await db.commit()
        return report
