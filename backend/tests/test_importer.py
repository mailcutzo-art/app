"""The question importer: CSV and JSON parsing, validation, duplicates, near duplicates,
idempotency, dry runs, audit, and the command-line tool."""

import csv
import importlib.util
import io
import json
from pathlib import Path
from types import ModuleType
from typing import Any

import pytest
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.clock import utc_now
from app.core.config import Settings
from app.modules.content import importer
from app.modules.content.editing import content_hash
from app.modules.content.importer import (
    ImportFormat,
    ImportOptions,
    ImportReport,
    RowStatus,
    detect_format,
    file_digest,
    import_questions,
    parse_file,
)
from app.modules.content.models import Question, Subject
from app.modules.system.models import AppConfig, AuditLog

BACKEND_DIR = Path(__file__).resolve().parents[1]

GOOD: dict[str, Any] = {
    "subject": "physics",
    "chapter": "kinematics",
    "topic": "equations-of-motion",
    "category": "numerical",
    "difficulty": 3,
    "stem": "A ball is dropped from rest. How far does it fall in the first 2 s? (g = 10 m s^{-2})",
    "options": ["10 m", "20 m", "40 m", "5 m"],
    "answer": 1,
    "explanation": "From rest, s = gt^2 / 2 = 10 * 2^2 / 2 = 20 m.",
}
SECOND: dict[str, Any] = {
    **GOOD,
    "id": "phy-imp-002",
    "topic": "speed-velocity",
    "category": "concept",
    "difficulty": 2,
    "stem": "Which quantity can be negative: distance travelled or displacement?",
    "options": ["Distance only", "Displacement only", "Both", "Neither"],
    "answer": "B",
    "explanation": "Displacement is a vector along an axis and can be negative; distance can't.",
    "exams": ["neet", "jee"],
    "battle_pool": "shared",
    "tags": ["vectors", "sign-convention"],
}
# A question from the test bank (phy-lom-001), with its options in another order.
EXISTING: dict[str, Any] = {
    **GOOD,
    "chapter": "laws-of-motion",
    "topic": "newtons-laws",
    "category": "concept",
    "stem": "Passengers lurch forward when a moving bus brakes suddenly. Which law explains this?",
    "options": [
        "Newton's third law",
        "Newton's first law (inertia)",
        "The law of gravitation",
        "Newton's second law",
    ],
    "answer": 1,
    "explanation": "By inertia the passengers keep moving forward while the bus slows down.",
}

OPTION_COLUMNS = ("option_a", "option_b", "option_c", "option_d")
CSV_HEADER = [
    "id",
    "subject",
    "chapter",
    "topic",
    "category",
    "difficulty",
    "exams",
    "battle_pool",
    "stem",
    "option_a",
    "option_b",
    "option_c",
    "option_d",
    "answer",
    "explanation",
    "tags",
]


def to_csv(*rows: dict[str, Any], header: list[str] = CSV_HEADER) -> bytes:
    out = io.StringIO()
    writer = csv.DictWriter(out, fieldnames=header, extrasaction="ignore")
    writer.writeheader()
    for row in rows:
        answer = row["answer"]
        writer.writerow(
            {
                **{name: value for name, value in row.items() if name != "options"},
                **dict(zip(OPTION_COLUMNS, row["options"], strict=False)),
                "answer": "ABCD"[answer] if isinstance(answer, int) else answer,
                "exams": "|".join(row.get("exams") or []),
                "tags": "|".join(row.get("tags") or []),
            }
        )
    return out.getvalue().encode()


def to_json(*rows: dict[str, Any]) -> bytes:
    return json.dumps(list(rows), ensure_ascii=False).encode()


async def run(
    db: AsyncSession,
    data: bytes,
    fmt: ImportFormat,
    **options: Any,
) -> ImportReport:
    rows, problems = parse_file(data, fmt)
    return await import_questions(
        db,
        rows,
        ImportOptions(**{"dry_run": False, **options}),
        source_name=f"test.{fmt.value}",
        source_digest=file_digest(data),
        actor_id=None,
        ip="127.0.0.1",
        now=utc_now(),
        file_problems=problems,
    )


def statuses(report: ImportReport) -> list[str]:
    return [row.status.value for row in report.rows]


async def imported(db: AsyncSession) -> list[Question]:
    rows = await db.scalars(
        select(Question)
        .where(Question.source == "import")
        .order_by(Question.seq)
        .execution_options(populate_existing=True)
    )
    return list(rows)


async def import_audits(db: AsyncSession) -> list[AuditLog]:
    return list(await db.scalars(select(AuditLog).where(AuditLog.action == "questions.imported")))


# --- Importing -------------------------------------------------------------------------------


async def test_a_csv_dry_run_reports_every_row_and_writes_nothing(db_session: AsyncSession) -> None:
    bad = {**GOOD, "stem": "Another question with two same options here?"}
    bad["options"] = ["1 m", "1 M", "2 m", "3 m"]
    unknown_topic = {**SECOND, "id": "phy-imp-009", "topic": "orbits", "stem": "Unknown topic?"}
    data = to_csv(GOOD, SECOND, bad, unknown_topic)

    report = await run(db_session, data, ImportFormat.CSV, dry_run=True)

    assert statuses(report) == ["ok", "ok", "error", "error"]
    assert [row.row for row in report.rows] == [2, 3, 4, 5]
    assert report.rows[2].messages == ["options must all be different"]
    assert report.rows[3].messages == ["chapter kinematics has no topic 'orbits'"]
    assert report.rows[1].external_id == "phy-imp-002"
    assert report.rows[0].external_id.startswith("imp-phy-")
    assert report.imported == 0
    assert report.summary().startswith("Dry run, nothing written. 4 rows: ok 2, error 2")
    assert await imported(db_session) == []
    assert await import_audits(db_session) == []


async def test_a_csv_import_adds_questions_for_review(db_session: AsyncSession) -> None:
    physics = await db_session.scalar(select(Subject).where(Subject.slug == "physics"))
    assert physics is not None
    last_seq = await db_session.scalar(
        select(func.max(Question.seq)).where(Question.subject_id == physics.id)
    )
    version = await db_session.get(AppConfig, "content_version")
    assert version is not None
    before_version = dict(version.value)

    report = await run(db_session, to_csv(GOOD, SECOND), ImportFormat.CSV)

    assert statuses(report) == ["ok", "ok"]
    assert report.imported == 2
    first, second = await imported(db_session)
    assert [first.seq, second.seq] == [last_seq + 1, last_seq + 2]
    assert first.status == second.status == "review"
    assert first.external_id == report.rows[0].external_id
    assert (first.answer, second.answer) == (1, 1)
    assert first.exams is None
    assert second.exams == ["neet", "jee"]
    assert (first.battle_pool, second.battle_pool) == ("none", "shared")
    assert second.tags == ["vectors", "sign-convention"]
    assert first.stem == GOOD["stem"]
    assert first.content_hash == content_hash(GOOD["stem"], GOOD["options"], 1)
    assert "Equations of motion" in first.search_text
    assert "kinematics" in first.search_text
    assert first.supersedes_id is None
    [audit] = await import_audits(db_session)
    assert audit.entity_type == "question_import"
    assert audit.entity_id == file_digest(to_csv(GOOD, SECOND))
    assert audit.after["imported"] == [first.external_id, "phy-imp-002"]
    assert audit.after["status"] == "review"
    assert audit.after["counts"]["ok"] == 2
    await db_session.refresh(version)
    assert version.value == before_version  # nothing players see changed


async def test_a_json_import_can_publish(db_session: AsyncSession) -> None:
    version = await db_session.get(AppConfig, "content_version")
    assert version is not None
    before = version.value["version"]
    wrapped = json.dumps({"questions": [GOOD, SECOND]}).encode()

    report = await run(db_session, wrapped, ImportFormat.JSON, publish=True)

    assert statuses(report) == ["ok", "ok"]
    assert [row.row for row in report.rows] == [1, 2]
    rows = await imported(db_session)
    assert [row.status for row in rows] == ["published", "published"]
    await db_session.refresh(version)
    assert version.value["version"] != before


async def test_importing_the_same_file_again_adds_nothing(db_session: AsyncSession) -> None:
    data = to_json(GOOD, SECOND)
    first = await run(db_session, data, ImportFormat.JSON)
    shuffled = {**GOOD, "options": list(reversed(GOOD["options"])), "answer": 2}

    again = await run(db_session, data, ImportFormat.JSON)
    as_csv = await run(db_session, to_csv(shuffled), ImportFormat.CSV)

    assert first.imported == 2
    assert statuses(again) == ["duplicate", "duplicate"]
    assert again.imported == 0
    assert not again.blocked
    assert again.rows[1].match == "phy-imp-002"
    assert statuses(as_csv) == ["duplicate"]
    assert as_csv.rows[0].match == first.rows[0].external_id
    assert len(await imported(db_session)) == 2
    assert len(await import_audits(db_session)) == 1


async def test_questions_already_in_the_bank_are_duplicates(db_session: AsyncSession) -> None:
    marked_up = {**GOOD, "stem": "  " + GOOD["stem"].replace("s^{-2}", "s^-2").upper()}

    report = await run(db_session, to_json(EXISTING, GOOD, GOOD, marked_up), ImportFormat.JSON)

    assert statuses(report) == ["duplicate", "ok", "duplicate", "duplicate"]
    assert report.rows[0].match == "phy-lom-001"
    assert report.rows[0].messages == ["already in the bank as phy-lom-001"]
    assert report.rows[2].match == "row 2"
    assert report.imported == 1


async def test_near_duplicates_are_held_back_unless_allowed(db_session: AsyncSession) -> None:
    near = {
        **EXISTING,
        "stem": (
            "Passengers lurch forward when a moving bus brakes suddenly. Which law explains it?"
        ),
        "options": [
            "Newton's second law",
            "Newton's first law (inertia)",
            "Newton's third law",
            "The law of gravitation",
        ],
    }
    same_stem = {**EXISTING, "options": ["Inertia", "Momentum", "Friction", "Gravity"]}
    other = {**GOOD}

    held = await run(db_session, to_json(near, same_stem, other), ImportFormat.JSON)
    allowed = await run(
        db_session, to_json(near, same_stem, other), ImportFormat.JSON, allow_near_duplicates=True
    )

    assert statuses(held) == ["near_duplicate", "near_duplicate", "ok"]
    assert held.rows[0].match == "phy-lom-001"
    assert held.rows[0].similarity is not None
    assert 0.9 < held.rows[0].similarity < 1
    assert "very similar to phy-lom-001" in held.rows[0].messages[0]
    assert (held.rows[1].match, held.rows[1].similarity) == ("phy-lom-001", 1.0)
    assert held.blocked
    assert held.imported == 0
    assert held.summary().startswith("Nothing imported")
    assert allowed.imported == 3
    assert statuses(allowed) == ["near_duplicate", "near_duplicate", "ok"]


async def test_near_duplicates_are_only_looked_for_in_the_same_subject(
    db_session: AsyncSession,
) -> None:
    in_maths = {
        **EXISTING,
        "subject": "maths",
        "chapter": "trigonometry",
        "topic": "identities",
        "exams": ["jee"],
    }

    report = await run(db_session, to_json(in_maths), ImportFormat.JSON, dry_run=True)

    assert statuses(report) == ["ok"]


@pytest.mark.parametrize(
    ("changes", "message"),
    [
        ({"options": ["1", "2", "3"]}, "expected 4 options, got 3"),
        ({"answer": 4}, "answer must be one of the 4 options"),
        ({"answer": "E"}, "answer: Input should be a valid integer"),
        ({"difficulty": 6}, "difficulty must be 1–5"),
        ({"category": "trivia"}, "category: Input should be"),
        ({"stem": "Too short"}, "stem must be 10–700 characters"),
        ({"stem": "What is \\frac{1}{2} of 10 m?"}, "LaTeX is not supported"),
        ({"stem": "Balance x^{2 in this stem, please?"}, "stem: unbalanced '{'"),
        ({"explanation": "Short."}, "explanation must be 10–1500 characters"),
        ({"options": ["1 m", "2 m", "3 m", "None of the above"]}, "refers to other options"),
        ({"battle_pool": "shared", "stem": "Long " * 40 + "?"}, "too long for a battle"),
        ({"exams": ["neet", "neet"]}, "exams must not repeat"),
        ({"exams": ["cbse"]}, "exams.0: Input should be 'neet' or 'jee'"),
        ({"subject": "history"}, "unknown subject 'history'"),
        ({"chapter": "optics"}, "physics has no chapter 'optics'"),
        ({"id": "Not An Id"}, "id: String should match pattern"),
        ({"colour": "blue"}, "colour: Extra inputs are not permitted"),
        ({"battle_pool": "sometimes"}, "battle_pool: Input should be"),
    ],
)
async def test_invalid_rows_say_why(
    db_session: AsyncSession, changes: dict[str, Any], message: str
) -> None:
    report = await run(db_session, to_json({**GOOD, **changes}), ImportFormat.JSON, dry_run=True)

    [row] = report.rows
    assert row.status is RowStatus.ERROR
    assert any(message in text for text in row.messages), row.messages


async def test_exams_must_include_the_subject(db_session: AsyncSession) -> None:
    maths = {
        **GOOD,
        "subject": "maths",
        "chapter": "trigonometry",
        "topic": "identities",
        "exams": ["neet"],
    }

    report = await run(db_session, to_json(maths), ImportFormat.JSON, dry_run=True)

    assert report.rows[0].messages == ["exams ['neet'] aren't all in this subject (['jee'])"]


async def test_ids_must_be_new_and_stems_unique_in_the_file(db_session: AsyncSession) -> None:
    taken = {**GOOD, "id": "phy-lom-001"}
    twice = {**SECOND, "stem": "Is displacement a vector or a scalar quantity?"}
    same_stem = {**GOOD, "id": "phy-imp-777", "options": ["1 m", "2 m", "3 m", "4 m"]}

    report = await run(
        db_session, to_json(taken, SECOND, twice, same_stem), ImportFormat.JSON, dry_run=True
    )

    assert statuses(report) == ["error", "ok", "error", "error"]
    assert report.rows[0].messages == ["id phy-lom-001 is already used by another question"]
    assert report.rows[2].messages == ["id phy-imp-002 is also used by row 2"]
    assert report.rows[3].messages == ["the same stem as row 1, with other options"]


async def test_errors_block_the_import_unless_skipped(db_session: AsyncSession) -> None:
    data = to_json(GOOD, {**SECOND, "difficulty": 9})

    blocked = await run(db_session, data, ImportFormat.JSON)
    nothing = await imported(db_session)
    skipped = await run(db_session, data, ImportFormat.JSON, skip_invalid=True)

    assert blocked.imported == 0
    assert nothing == []
    assert skipped.imported == 1
    assert [row.imported for row in skipped.rows] == [True, False]
    assert skipped.summary().startswith("Imported 1 questions.")


@pytest.mark.parametrize(
    ("data", "fmt", "problem"),
    [
        (b"subject,stem\nphysics,x\n", ImportFormat.CSV, "missing columns: chapter, topic"),
        (
            to_csv(GOOD, header=[*CSV_HEADER, "colour"]),
            ImportFormat.CSV,
            "unknown columns: colour",
        ),
        (b"\xff\xfe", ImportFormat.CSV, "the file must be UTF-8 text"),
        (b"[{", ImportFormat.JSON, "not valid JSON"),
        (b'{"items": []}', ImportFormat.JSON, "expected a JSON list of questions"),
        (b"[]", ImportFormat.JSON, "the file has no questions"),
        (",".join(CSV_HEADER).encode() + b"\n", ImportFormat.CSV, "the file has no questions"),
    ],
)
async def test_unusable_files_are_refused_as_a_whole(
    db_session: AsyncSession, data: bytes, fmt: ImportFormat, problem: str
) -> None:
    report = await run(db_session, data, fmt)

    assert report.rows == []
    assert any(problem in text for text in report.file_problems), report.file_problems
    assert report.blocked
    assert report.summary().startswith("The file can't be imported")


async def test_limits(db_session: AsyncSession, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(importer, "MAX_ROWS", 1)
    monkeypatch.setattr(importer, "MAX_FILE_BYTES", 10_000)

    too_many = await run(db_session, to_json(GOOD, SECOND), ImportFormat.JSON)
    too_big = await run(db_session, b" " * 10_001, ImportFormat.JSON)

    assert too_many.file_problems == ["the file has 2 questions; import at most 1 at once"]
    assert too_big.file_problems == ["the file is larger than 0 MB"]


async def test_csv_answers_are_letters_and_rows_are_numbered_by_line(
    db_session: AsyncSession,
) -> None:
    numeric = to_csv({**GOOD, "answer": "1"})
    blank_lines = to_csv(GOOD).replace(b"\r\n", b"\r\n\r\n", 1)
    ragged = to_csv(GOOD) + b"a,b,c,d,e,f,g,h,i,j,k,l,m,n,o,p,q\r\n"

    number = await run(db_session, numeric, ImportFormat.CSV, dry_run=True)
    blanks = await run(db_session, blank_lines, ImportFormat.CSV, dry_run=True)
    extra = await run(db_session, ragged, ImportFormat.CSV, dry_run=True)

    assert number.rows[0].messages == ["answer: write the letter A, B, C or D"]
    assert [row.row for row in blanks.rows] == [3]
    assert statuses(extra) == ["ok", "error"]
    assert extra.rows[1].messages == ["the row has more cells than the header"]


def test_the_format_is_detected_from_the_name_or_the_content() -> None:
    assert detect_format("bank.JSON", b"") is ImportFormat.JSON
    assert detect_format("bank.csv", b"[") is ImportFormat.CSV
    assert detect_format(None, b"\xef\xbb\xbf  [ {}]") is ImportFormat.JSON
    assert detect_format("upload", b"subject,chapter") is ImportFormat.CSV


async def test_the_example_files_in_the_docs_are_valid(db_session: AsyncSession) -> None:
    docs = (BACKEND_DIR.parent / "docs" / "content-format.md").read_text()
    csv_example = docs.split("```csv\n", 1)[1].split("```", 1)[0].encode()
    json_example = docs.split("```json\n", 1)[1].split("```", 1)[0].encode()

    from_csv = await run(db_session, csv_example, ImportFormat.CSV, dry_run=True)
    from_json = await run(db_session, json_example, ImportFormat.JSON, dry_run=True)

    assert statuses(from_csv) == ["ok", "ok"], [row.messages for row in from_csv.rows]
    assert statuses(from_json) == ["ok"], [row.messages for row in from_json.rows]


# --- The command-line tool -------------------------------------------------------------------


def _cli() -> ModuleType:
    spec = importlib.util.spec_from_file_location(
        "import_questions_cli", BACKEND_DIR / "scripts" / "import_questions.py"
    )
    assert spec is not None
    assert spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_the_cli_dry_run_prints_the_report(
    settings: Settings,
    engine: Any,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    cli = _cli()
    monkeypatch.setattr(cli, "get_settings", lambda: settings)
    path = tmp_path / "bank.csv"
    path.write_bytes(to_csv(GOOD, EXISTING, {**GOOD, "difficulty": 0, "stem": "Bad row here?"}))
    report_path = tmp_path / "report.json"

    status = cli.main([str(path), "--report", str(report_path)])

    out = capsys.readouterr().out
    assert status == 1
    assert "row 2: ok imp-phy-" in out
    assert "! row 3: duplicate phy-lom-001: already in the bank as phy-lom-001" in out
    assert "✗ row 4: error" in out
    assert "Dry run, nothing written. 3 rows: ok 1, error 1, duplicate 1" in out
    report = json.loads(report_path.read_text())
    assert report["dry_run"] is True
    assert [row["status"] for row in report["rows"]] == ["ok", "duplicate", "error"]


def test_the_cli_refuses_bad_arguments(
    settings: Settings,
    engine: Any,
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    cli = _cli()
    monkeypatch.setattr(cli, "get_settings", lambda: settings)
    path = tmp_path / "bank.json"
    path.write_bytes(to_json(GOOD))

    missing = cli.main([str(tmp_path / "nope.csv")])
    not_admin = cli.main([str(path), "--as", "nobody@example.com"])

    err = capsys.readouterr().err
    assert missing == not_admin == 2
    assert "no file" in err
    assert "'nobody@example.com' is not an admin" in err
