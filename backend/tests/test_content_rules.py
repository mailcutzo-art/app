"""``app.modules.content.rules`` agrees with ``content/tools/validate.py`` on single questions.

Each case replaces one question of a valid chapter file and runs the repository's validator on
it; the importer's rules must accept and reject exactly the same questions.
"""

import shutil
from pathlib import Path
from typing import Any

import pytest
import yaml

from app.modules.content.loader import load_validator
from app.modules.content.rules import dedupe_key, markup_problem, question_problems
from tests.helpers import CONTENT_DIR

CHAPTER = Path("questions") / "physics" / "kinematics.yaml"
BASE: dict[str, Any] = {
    "id": "phy-kin-001",
    "topic": "speed-velocity",
    "category": "concept",
    "difficulty": 1,
    "battle": True,
    "stem": "A runner completes one lap of a circular track. What is the runner's displacement?",
    "options": ["Zero", "Equal to the circumference", "Equal to the diameter", "The radius"],
    "answer": 0,
    "explanation": "Displacement is the change in position; the runner ends at the start.",
}

CASES: list[tuple[str, dict[str, Any]]] = [
    ("valid", {}),
    ("valid with markup", {"stem": "Water is H_2O and speed is in m s^{-1}. Which is a vector?"}),
    ("valid exams", {"exams": ["neet"]}),
    ("three options", {"options": ["Zero", "One", "Two"]}),
    ("five options", {"options": ["Zero", "One", "Two", "Three", "Four"]}),
    ("same options", {"options": ["Zero", "zero ", "One", "Two"]}),
    ("answer out of range", {"answer": 4}),
    ("negative answer", {"answer": -1}),
    ("short stem", {"stem": "Too short"}),
    ("long stem", {"battle": False, "stem": "Why? " * 141}),
    ("long battle stem", {"stem": "x" * 181}),
    ("longest battle stem", {"stem": "x" * 180}),
    ("short explanation", {"explanation": "Because."}),
    ("long explanation", {"explanation": "x" * 1501}),
    ("empty option", {"options": ["", "One", "Two", "Three"]}),
    ("long option", {"options": ["x" * 161, "One", "Two", "Three"]}),
    ("all of the above", {"options": ["Zero", "One", "Two", "All of the above"]}),
    ("both a and b", {"options": ["Zero", "One", "Two", "Both A and B"]}),
    ("latex", {"stem": "What is \\frac{1}{2} of the track length?"}),
    ("dollar", {"explanation": "It costs $5 to run this far around the track."}),
    ("unbalanced", {"options": ["x^{2", "One", "Two", "Three"]}),
    ("closing brace", {"stem": "What is x}^2 on this circular track, then?"}),
    ("difficulty 0", {"difficulty": 0}),
    ("difficulty 6", {"difficulty": 6}),
    ("repeated exams", {"exams": ["neet", "neet"]}),
    ("no exams", {"exams": []}),
]


def _validator_accepts(tmp_path: Path, case: dict[str, Any]) -> bool:
    root = tmp_path / "content"
    shutil.copytree(CONTENT_DIR, root)
    path = root / CHAPTER
    data = yaml.safe_load(path.read_text())
    data["questions"][0] = {**BASE, **case}
    path.write_text(yaml.safe_dump(data, allow_unicode=True))
    _, problems = load_validator(root).load(root, only={path.resolve()})
    return not problems


def _rules_accept(case: dict[str, Any]) -> bool:
    question = {**BASE, **case}
    return not question_problems(
        stem=question["stem"],
        options=question["options"],
        answer=question["answer"],
        explanation=question["explanation"],
        difficulty=question["difficulty"],
        battle=question["battle"],
        exams=question.get("exams"),
        subject_exams={"neet", "jee"},
    )


@pytest.mark.parametrize(("name", "case"), CASES, ids=[name for name, _ in CASES])
def test_the_rules_match_the_validator(tmp_path: Path, name: str, case: dict[str, Any]) -> None:
    expected = _validator_accepts(tmp_path, case)

    assert _rules_accept(case) is expected
    assert expected is name.startswith(("valid", "longest"))


def test_markup_problems() -> None:
    assert markup_problem("d_{x^2-y^2}") is None
    assert markup_problem("x^{2") == "unbalanced '{'"
    assert markup_problem("x}") == "unbalanced '}'"
    assert markup_problem("$x$") is not None


def test_the_dedupe_key_ignores_markup_case_spacing_and_option_order() -> None:
    key = dedupe_key("What is H_2O?", ["Water", "Ice", "Steam", "Fog"])

    assert dedupe_key("  what is  H2O? ", ["fog", "STEAM", "Ice", "Water"]) == key
    fullwidth = "What is \uff28_2\uff2f?"
    assert dedupe_key(fullwidth, ["Water", "Ice", "Steam", "Fog"]) == key
    assert dedupe_key("What is H_2O?", ["Water", "Ice", "Steam", "Mist"]) != key
