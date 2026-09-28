"""Import questions from a CSV or JSON file (format: docs/content-format.md).

    uv run python scripts/import_questions.py questions.csv              # dry run: report only
    uv run python scripts/import_questions.py questions.csv --commit     # import (status review)
    uv run python scripts/import_questions.py questions.json --commit --publish --as root@x.com

Every row is reported as ok, error (with the reasons), duplicate or near_duplicate. Nothing is
written unless ``--commit`` is given and no row has an error or is a near duplicate; add
``--skip-invalid`` to import the good rows anyway and ``--allow-near-duplicates`` to import near
duplicates too. Duplicates are always skipped, so running the same file again adds nothing.
``--report out.json`` writes the full per-row report as JSON. The import is audit-logged, with
the admin named by ``--as`` (an email address or handle) as its author.

Exit status: 0 when nothing blocks the import, 1 when rows have problems, 2 for usage errors.
"""

import argparse
import asyncio
import json
import sys
from collections.abc import Sequence
from pathlib import Path

from app.core.clock import utc_now
from app.core.config import get_settings
from app.core.resources import open_resources
from app.modules.content.importer import (
    ImportFormat,
    ImportOptions,
    ImportReport,
    detect_format,
    file_digest,
    import_questions,
    parse_file,
)
from app.modules.users import service
from app.modules.users.models import Role


class NotAnAdmin(Exception):
    pass


async def run(
    data: bytes, name: str, fmt: ImportFormat | None, options: ImportOptions, actor: str | None
) -> ImportReport:
    """Check (and unless a dry run, import) the file's questions in one transaction."""
    rows, problems = parse_file(data, fmt or detect_format(name, data))
    async with (
        open_resources(get_settings(), component="import-questions") as resources,
        resources.sessionmaker() as db,
    ):
        actor_id = None
        if actor is not None:
            user = await service.find_user(db, actor)
            if user is None or Role.ADMIN not in user.roles:
                raise NotAnAdmin(actor)
            actor_id = user.id
        report = await import_questions(
            db,
            rows,
            options,
            source_name=name,
            source_digest=file_digest(data),
            actor_id=actor_id,
            ip=None,
            now=utc_now(),
            file_problems=problems,
        )
        if report.imported:
            await db.commit()
    return report


def print_report(report: ImportReport) -> None:
    for problem in report.file_problems:
        print(f"✗ {problem}")
    for row in report.rows:
        if row.status.value == "ok" and not row.messages:
            mark = "imported" if row.imported else "ok"
            print(f"  row {row.row}: {mark} {row.external_id}")
            continue
        mark = "✗" if row.status.value == "error" else "!"
        label = f" {row.external_id}" if row.external_id else ""
        print(f"{mark} row {row.row}: {row.status.value}{label}: {'; '.join(row.messages)}")
    print(report.summary())


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Import questions from a CSV or JSON file.")
    parser.add_argument("file", type=Path)
    parser.add_argument("--format", choices=[f.value for f in ImportFormat], default=None)
    parser.add_argument("--commit", action="store_true", help="write (default: dry run)")
    parser.add_argument("--publish", action="store_true", help="status published, not review")
    parser.add_argument("--skip-invalid", action="store_true")
    parser.add_argument("--allow-near-duplicates", action="store_true")
    parser.add_argument("--as", dest="actor", help="the admin doing the import (email or handle)")
    parser.add_argument("--report", type=Path, help="also write the report as JSON here")
    args = parser.parse_args(argv)
    if not args.file.is_file():
        print(f"error: no file {args.file}", file=sys.stderr)
        return 2
    fmt = ImportFormat(args.format) if args.format else None
    options = ImportOptions(
        dry_run=not args.commit,
        publish=args.publish,
        skip_invalid=args.skip_invalid,
        allow_near_duplicates=args.allow_near_duplicates,
    )
    data = args.file.read_bytes()
    try:
        report = asyncio.run(run(data, args.file.name, fmt, options, args.actor))
    except NotAnAdmin as exc:
        print(f"error: {exc.args[0]!r} is not an admin", file=sys.stderr)
        return 2
    except LookupError as exc:  # an email shared by several accounts
        print(f"error: {exc}", file=sys.stderr)
        return 2
    print_report(report)
    if args.report is not None:
        args.report.write_text(json.dumps(report.as_dict(), ensure_ascii=False, indent=2))
    return 1 if report.blocked else 0


if __name__ == "__main__":
    sys.exit(main())
