"""Export the content YAML as flat, database-ready seed files (see docs/content-format.md).

Run from the repo root after validate.py passes:

    uv run --with pyyaml python content/tools/export_seed.py [--out content/build/seed]

Writes one JSON array per table, in load order:

    goals.json      exam goals (NEET, JEE)
    subjects.json   subjects, with the goals that include them
    chapters.json   chapters -> subject_id
    modules.json    modules (chapter topics) -> chapter_id, subject_id
    questions.json  questions -> module_id, chapter_id, subject_id, with options and answer

Every id is a UUIDv5 derived from the content's slugs and question id, so re-running the export
gives the same ids and a seed script can upsert on them.
"""

from __future__ import annotations

import argparse
import json
import sys
import uuid
from pathlib import Path
from typing import Any

import yaml

ROOT = Path(__file__).resolve().parents[1]
NAMESPACE = uuid.uuid5(uuid.NAMESPACE_URL, "quiz-arena/content")


def _id(*parts: str) -> str:
    return str(uuid.uuid5(NAMESPACE, "/".join(parts)))


def _load(path: Path) -> Any:
    with path.open(encoding="utf-8") as f:
        return yaml.safe_load(f)


def _difficulty_band(difficulty: int) -> str:
    return "easy" if difficulty <= 2 else "medium" if difficulty == 3 else "hard"


def build() -> dict[str, list[dict[str, Any]]]:
    catalog = _load(ROOT / "catalog.yaml")
    goals = [
        {"id": _id("goal", g["slug"]), "slug": g["slug"], "name": g["name"], "order": i}
        for i, g in enumerate(catalog["goals"], start=1)
    ]
    subjects = [
        {
            "id": _id("subject", s["slug"]),
            "slug": s["slug"],
            "name": s["name"],
            "tone": s.get("tone"),
            "icon": s.get("icon"),
            "order": i,
            "goal_ids": [
                _id("goal", g["slug"]) for g in catalog["goals"] if s["slug"] in g["subjects"]
            ],
        }
        for i, s in enumerate(catalog["subjects"], start=1)
    ]

    chapters: list[dict[str, Any]] = []
    modules: list[dict[str, Any]] = []
    questions: list[dict[str, Any]] = []
    for path in sorted((ROOT / "questions").glob("*/*.yaml")):
        data = _load(path)
        subject, chapter = data["subject"], data["chapter"]
        subject_id = _id("subject", subject)
        chapter_id = _id("chapter", subject, chapter["slug"])
        chapters.append(
            {
                "id": chapter_id,
                "subject_id": subject_id,
                "slug": chapter["slug"],
                "name": chapter["name"],
                "order": chapter["order"],
                "classes": chapter.get("classes"),
            }
        )
        module_ids = {}
        for i, topic in enumerate(chapter["topics"], start=1):
            module_ids[topic["slug"]] = _id("module", subject, chapter["slug"], topic["slug"])
            modules.append(
                {
                    "id": module_ids[topic["slug"]],
                    "chapter_id": chapter_id,
                    "subject_id": subject_id,
                    "slug": topic["slug"],
                    "name": topic["name"],
                    "order": i,
                }
            )
        for q in data["questions"]:
            question_id = _id("question", q["id"])
            questions.append(
                {
                    "id": question_id,
                    "code": q["id"],
                    "subject_id": subject_id,
                    "chapter_id": chapter_id,
                    "module_id": module_ids[q["topic"]],
                    "subtopic": q.get("subtopic"),
                    "concept": q.get("concept"),
                    "category": q["category"],
                    "format": q.get("format", "direct"),
                    "exams": q.get("exams"),
                    "difficulty": q["difficulty"],
                    "difficulty_band": _difficulty_band(q["difficulty"]),
                    "battle": q.get("battle", False),
                    "time_seconds": q.get("time"),
                    "ncert": q.get("ncert"),
                    "formula": q.get("formula"),
                    "requires_diagram": bool(q.get("diagram")),
                    "diagram_description": q.get("diagram"),
                    "tags": q.get("tags", []),
                    "stem": q["stem"],
                    "options": [
                        {
                            "id": _id("option", q["id"], str(i)),
                            "position": i,
                            "text": text,
                            "is_correct": i == q["answer"],
                        }
                        for i, text in enumerate(q["options"])
                    ],
                    "correct_option": "ABCD"[q["answer"]],
                    "explanation": q["explanation"],
                }
            )
    return {
        "goals": goals,
        "subjects": subjects,
        "chapters": chapters,
        "modules": modules,
        "questions": questions,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--out", type=Path, default=ROOT / "build" / "seed")
    args = parser.parse_args()
    tables = build()
    args.out.mkdir(parents=True, exist_ok=True)
    for name, rows in tables.items():
        with (args.out / f"{name}.json").open("w", encoding="utf-8") as f:
            json.dump(rows, f, ensure_ascii=False, indent=1)
            f.write("\n")
    print(", ".join(f"{len(rows)} {name}" for name, rows in tables.items()) + f" → {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
