"""Add generated batches to a chapter file, or remove questions, safely and repeatably.

    uv run --with pyyaml --with pydantic python content/tools/bank.py add chemistry biomolecules batch.yaml
    uv run --with pyyaml --with pydantic python content/tools/bank.py add ... --dry-run
    uv run --with pyyaml --with pydantic python content/tools/bank.py remove chemistry basic-concepts che-basic-310 ...

``batch.yaml`` is a YAML list of questions in the chapter-file format (see docs/content-format.md)
with the ``id`` left out (an id is ignored). ``add``:

* validates every question with the same models and rules as ``validate.py``,
* rejects a question whose stem already exists anywhere in the subject, or that is a near
  duplicate (4-word-shingle Jaccard >= 0.7 on stem + options after masking numbers) of an existing
  or earlier-in-batch question,
* numbers the accepted questions from the chapter's highest existing id + 1 (never reuses a number),
* appends them to the chapter file, leaving the existing text untouched, and
* writes the rejected ones with the reasons to ``<batch>.rejects.yaml`` so they can be rewritten.

Running the same batch twice adds nothing the second time (its stems already exist).
``remove`` deletes the named questions' text blocks and leaves every other question untouched.
"""

import argparse
import re
import sys
from collections import Counter
from pathlib import Path

import yaml
from pydantic import ValidationError

sys.path.insert(0, str(Path(__file__).resolve().parent))
import validate as V  # noqa: E402

ROOT = V.ROOT
JACCARD = 0.7
KEY_ORDER = [
    "id", "topic", "subtopic", "concept", "category", "format", "exams", "difficulty", "time",
    "ncert", "battle", "formula", "diagram", "tags", "stem", "options", "answer", "explanation",
]  # fmt: skip


def _mask(text: str) -> list[str]:
    t = re.sub(r"[0-9]+(\.[0-9]+)?", "#", text.lower())
    return re.sub(r"[^a-z#]+", " ", t).strip().split()


def _shingles(q: dict) -> set[str]:
    w = _mask(str(q["stem"]) + " " + " ".join(map(str, q["options"])))
    return {" ".join(w[i : i + 4]) for i in range(max(1, len(w) - 3))}


def _stem_key(stem: str) -> str:
    return re.sub(r"[^a-z0-9]+", "", stem.lower())


class _Dumper(yaml.SafeDumper):
    def increase_indent(self, flow=False, indentless=False):  # indent list items under their key
        return super().increase_indent(flow, False)


def _str(dumper: yaml.SafeDumper, s: str):  # literal block for multi-line stems, as in the bank
    if "\n" in s:
        return dumper.represent_scalar("tag:yaml.org,2002:str", s, style="|")
    return dumper.represent_scalar("tag:yaml.org,2002:str", s)


_Dumper.add_representer(str, _str)


class _Flow(list):
    """Short lists kept inline (`tags: [a, b]`), as in the existing chapter files."""


_Dumper.add_representer(
    _Flow, lambda d, v: d.represent_sequence("tag:yaml.org,2002:seq", list(v), flow_style=True)
)


def _dump(q: dict) -> str:
    ordered = {k: q[k] for k in KEY_ORDER if k in q}
    for k in ("tags", "exams"):
        if k in ordered:
            ordered[k] = _Flow(ordered[k])
    text = yaml.dump(
        [ordered], Dumper=_Dumper, allow_unicode=True, sort_keys=False, width=10_000,
        default_flow_style=False, indent=2,
    )  # fmt: skip
    return "".join("  " + line if line.strip() else line for line in text.splitlines(True))


def _dirs(subject: str) -> list[Path]:
    """Validated chapters live in questions/, chapters still being written in wip/ (not validated)."""
    return [d for d in (ROOT / "questions" / subject, ROOT / "wip" / subject) if d.is_dir()]


def _chapter_path(subject: str, chapter: str) -> Path:
    for d in _dirs(subject):
        if (d / f"{chapter}.yaml").exists():
            return d / f"{chapter}.yaml"
    raise SystemExit(f"no chapter file for {subject}/{chapter} in questions/ or wip/")


def _subject_questions(subject: str) -> list[dict]:
    out = []
    for d in _dirs(subject):
        for path in sorted(d.glob("*.yaml")):
            out.extend(yaml.safe_load(path.read_text())["questions"] or [])
    return out


def _prefix(subject: str, slug: str) -> str:
    """The id prefix of a chapter: from syllabus.yaml, or from the Biology plan while it is in wip/."""
    syllabus = yaml.safe_load((ROOT / "syllabus.yaml").read_text()) or {}
    entry = next((c for c in syllabus.get(subject, []) if c["slug"] == slug), None)
    if entry is None:
        plan = yaml.safe_load((ROOT / "tools" / "biology_plan.yaml").read_text())
        entry = next(c for c in plan if c["slug"] == slug)
    return f"{subject[:3]}-{entry['prefix']}-"


def cmd_add(args: argparse.Namespace) -> int:
    path = _chapter_path(args.subject, args.chapter)
    batch_path = Path(args.batch)
    chapter = yaml.safe_load(path.read_text())
    chapter["questions"] = chapter["questions"] or []
    topics = {t["slug"] for t in chapter["chapter"]["topics"]}
    prefix = _prefix(args.subject, args.chapter)
    existing = _subject_questions(args.subject)
    # validate.py requires stems to be unique across every subject, so compare against all of them
    stems = {_stem_key(q["stem"]) for q in existing}
    for other in sorted(p.name for p in (ROOT / "questions").iterdir() if p.is_dir()):
        if other != args.subject:
            stems |= {_stem_key(q["stem"]) for q in _subject_questions(other)}
    index = [(q["id"], _shingles(q)) for q in existing]
    inv: dict[str, list[int]] = {}
    for i, (_, s) in enumerate(index):
        for g in s:
            inv.setdefault(g, []).append(i)
    next_no = max(
        (int(q["id"][len(prefix) :]) for q in chapter["questions"] if q["id"].startswith(prefix)),
        default=0,
    ) + 1

    try:
        batch = yaml.safe_load(batch_path.read_text())
    except yaml.YAMLError as e:
        print(f"{batch_path}: not valid YAML, fix and re-run:\n{e}")
        return 2
    if not isinstance(batch, list):
        print("batch must be a YAML list of questions")
        return 2
    accepted, rejected = [], []
    for n, raw in enumerate(batch, 1):
        why = []
        q = dict(raw)
        q["id"] = f"{prefix}{next_no + len(accepted):03d}"
        try:
            model = V.Question.model_validate(q)
        except ValidationError as e:
            why.append("schema: " + "; ".join(f"{'.'.join(map(str, x['loc']))}: {x['msg']}" for x in e.errors()))
            model = None
        if model:
            if q["topic"] not in topics:
                why.append(f"unknown topic {q['topic']!r}")
            if model.battle and len(model.stem) > V.MAX_BATTLE_STEM:
                why.append("battle stem too long")
            if model.battle and model.diagram:
                why.append("battle question with a diagram")
            if model.format == V.Format.DIAGRAM and not model.diagram:
                why.append("diagram format without a diagram")
            for t in [model.stem, model.explanation, *model.options]:
                issue = V._markup_problem(t)
                if issue:
                    why.append(issue)
            for o in model.options:
                if V.OPTION_XREF.search(o):
                    why.append(f"option refers to other options: {o!r}")
            if _stem_key(model.stem) in stems:
                why.append("duplicate stem")
            else:
                s = _shingles(q)
                cand: Counter = Counter()
                for g in s:
                    for j in inv.get(g, []):
                        cand[j] += 1
                for j, c in cand.items():
                    if c >= JACCARD * min(len(s), len(index[j][1])):
                        jac = len(s & index[j][1]) / len(s | index[j][1])
                        if jac >= JACCARD:
                            why.append(f"near duplicate of {index[j][0]} ({jac:.2f})")
                            break
        if why:
            rejected.append({"batch_position": n, "reasons": why, "question": raw})
            continue
        accepted.append(q)
        stems.add(_stem_key(q["stem"]))
        index.append((q["id"], _shingles(q)))
        for g in index[-1][1]:
            inv.setdefault(g, []).append(len(index) - 1)

    print(f"{args.chapter}: {len(accepted)} accepted, {len(rejected)} rejected of {len(batch)}")
    for r in rejected[:40]:
        print(f"  #{r['batch_position']}: {'; '.join(r['reasons'])}")
    if rejected and not args.dry_run:
        out = batch_path.with_suffix(".rejects.yaml")
        out.write_text(yaml.dump(rejected, allow_unicode=True, sort_keys=False, width=10_000))
        print(f"  rejects written to {out}")
    if accepted and not args.dry_run:
        text = re.sub(r"^questions:[ ]*(\[\])?[ ]*$", "questions:", path.read_text(), flags=re.M)
        if not text.endswith("\n"):
            text += "\n"
        path.write_text(text + "".join(_dump(q) for q in accepted))
        print(f"  appended {accepted[0]['id']} .. {accepted[-1]['id']}")
    return 0


def cmd_remove(args: argparse.Namespace) -> int:
    path = _chapter_path(args.subject, args.chapter)
    lines = path.read_text().splitlines(True)
    drop, removed, i = set(args.ids), [], 0
    out = []
    while i < len(lines):
        m = re.match(r"^  - id: (\S+)\s*$", lines[i])
        if m and m.group(1) in drop:
            removed.append(m.group(1))
            i += 1
            while i < len(lines) and not re.match(r"^  - id: ", lines[i]):
                i += 1
            continue
        out.append(lines[i])
        i += 1
    missing = drop - set(removed)
    if missing:
        print(f"not found in {args.chapter}: {sorted(missing)}")
        return 1
    path.write_text("".join(out))
    print(f"removed {len(removed)} from {args.chapter}: {' '.join(removed)}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("add")
    a.add_argument("subject")
    a.add_argument("chapter")
    a.add_argument("batch")
    a.add_argument("--dry-run", action="store_true")
    r = sub.add_parser("remove")
    r.add_argument("subject")
    r.add_argument("chapter")
    r.add_argument("ids", nargs="+")
    args = ap.parse_args()
    return cmd_add(args) if args.cmd == "add" else cmd_remove(args)


if __name__ == "__main__":
    sys.exit(main())
