"""The per-question rules of ``content/tools/validate.py``, for questions that don't come from
the content files: importer rows and admin edits.

The api image does not ship ``content/``, so the rules live here too.
``tests/test_content_rules.py`` runs the same cases through the repository's validator and this
module and fails if they ever disagree.
"""

import hashlib
import re
import unicodedata
from collections.abc import Iterable, Sequence

from app.modules.content.markup import plain_text

MAX_STEM = 700
MIN_STEM = 10
MAX_BATTLE_STEM = 180
MAX_OPTION = 160
MIN_EXPLANATION = 10
MAX_EXPLANATION = 1500
OPTION_COUNT = 4
# Options are shuffled in battles and labelled A–D by position, so they must never point at
# each other (same pattern as the validator).
OPTION_XREF = re.compile(
    r"\b(all|none|both|neither) of (the )?(above|these)\b|\bboth \(?[A-D]\)? and \(?[A-D]\)?(\W|$)"
    r"|\boption \(?[A-D]\)?(\W|$)",
    re.IGNORECASE,
)
LATEX = re.compile(r"\\[a-zA-Z]+|\$")


def normalize(text: str) -> str:
    """The validator's comparison form: whitespace collapsed, lower case."""
    return re.sub(r"\s+", " ", text).strip().lower()


def markup_problem(text: str) -> str | None:
    """Unbalanced braces or LaTeX, as the validator reports them; ``None`` if the markup is fine."""
    depth = 0
    for ch in text:
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth < 0:
                return "unbalanced '}'"
    if depth:
        return "unbalanced '{'"
    if LATEX.search(text):
        return "LaTeX is not supported; use the markup in docs/content-format.md"
    return None


def question_problems(
    *,
    stem: str,
    options: Sequence[str],
    answer: int,
    explanation: str,
    difficulty: int,
    battle: bool,
    exams: Sequence[str] | None,
    subject_exams: Iterable[str],
) -> list[str]:
    """Everything wrong with one question, in the validator's words (empty when it's fine).

    ``battle`` is whether the question may be used in battles (``battle_pool`` other than
    ``none``); ``subject_exams`` are the exams that include its subject.
    """
    problems: list[str] = []
    if not MIN_STEM <= len(stem) <= MAX_STEM:
        problems.append(f"stem must be {MIN_STEM}–{MAX_STEM} characters (it has {len(stem)})")
    if len(options) != OPTION_COUNT:
        problems.append(f"expected {OPTION_COUNT} options, got {len(options)}")
    elif len({normalize(option) for option in options}) != OPTION_COUNT:
        problems.append("options must all be different")
    for index, option in enumerate(options):
        label = "ABCD"[index] if index < OPTION_COUNT else str(index + 1)
        if not 1 <= len(option) <= MAX_OPTION:
            problems.append(f"option {label} must be 1–{MAX_OPTION} characters")
        if OPTION_XREF.search(option):
            problems.append(
                f"option {label} {option!r} refers to other options, which are shuffled"
            )
    if not 0 <= answer < OPTION_COUNT:
        problems.append("answer must be one of the 4 options (A–D, or 0–3)")
    if not MIN_EXPLANATION <= len(explanation) <= MAX_EXPLANATION:
        problems.append(f"explanation must be {MIN_EXPLANATION}–{MAX_EXPLANATION} characters")
    if not 1 <= difficulty <= 5:
        problems.append("difficulty must be 1–5")
    if battle and len(stem) > MAX_BATTLE_STEM:
        problems.append(
            f"the stem is too long for a battle question ({len(stem)} > {MAX_BATTLE_STEM} "
            "characters); use battle_pool none"
        )
    if exams is not None:
        allowed = set(subject_exams)
        if not exams:
            problems.append("exams must list at least one exam, or be left empty for all")
        elif len(set(exams)) != len(exams):
            problems.append("exams must not repeat")
        elif not set(exams) <= allowed:
            problems.append(f"exams {list(exams)} aren't all in this subject ({sorted(allowed)})")
    for name, text in (("stem", stem), ("explanation", explanation)):
        issue = markup_problem(text)
        if issue:
            problems.append(f"{name}: {issue}")
    for index, option in enumerate(options[:OPTION_COUNT]):
        issue = markup_problem(option)
        if issue:
            problems.append(f"option {'ABCD'[index]}: {issue}")
    return problems


def _dedupe_form(text: str) -> str:
    """Markup, case, width variants and spacing removed: "H_2O" and "h2o" compare equal."""
    return " ".join(plain_text(unicodedata.normalize("NFKC", text)).casefold().split())


def dedupe_key(stem: str, options: Iterable[str]) -> str:
    """What makes two questions the same for the importer: the normalized stem and the set of
    normalized options (their order doesn't matter, since battles shuffle them)."""
    parts = [_dedupe_form(stem), *sorted(_dedupe_form(option) for option in options)]
    return hashlib.sha256("\x1f".join(parts).encode()).hexdigest()
