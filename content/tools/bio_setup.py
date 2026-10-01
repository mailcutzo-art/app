"""Biology plan tooling.

    uv run --with pyyaml python content/tools/bio_setup.py check            # validate the plan
    uv run --with pyyaml python content/tools/bio_setup.py setup            # syllabus + chapter files
    uv run --with pyyaml python content/tools/bio_setup.py assign <chapter> <topic>   # a writer's brief
    uv run --with pyyaml python content/tools/bio_setup.py status           # topic progress

``setup`` is idempotent: it adds the ``biology:`` section to syllabus.yaml once, creates missing chapter
files with their topics and no questions, and rewrites the header of an existing chapter file (keeping
its questions) so it matches the plan. Topic slugs are ``<chapter prefix>-<slug>`` unless the plan marks
``keep: true`` (the four slugs the original test questions use).
"""

import json
import re
import sys
from collections import Counter
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
PLAN = ROOT / "tools" / "biology_plan.yaml"
QDIR = ROOT / "questions" / "biology"
TARGET = 500
MIX = (0.20, 0.45, 0.25, 0.10)  # easy (1-2), standard (3), hard (4), NEET+ (5)


def load_plan() -> list[dict]:
    plan = yaml.safe_load(PLAN.read_text())
    for ch in plan:
        for t in ch["topics"]:
            t["slug"] = t["s"] if t.get("keep") else f"{ch['prefix']}-{t['s']}"
    return plan


def problems(plan: list[dict]) -> list[str]:
    out, slugs, prefixes, names = [], set(), set(), set()
    for ch in plan:
        total = sum(t["c"] for t in ch["topics"])
        if total != TARGET:
            out.append(f"{ch['slug']}: topics sum to {total}, not {TARGET}")
        if not 2 <= len(ch["topics"]) <= 12:
            out.append(f"{ch['slug']}: {len(ch['topics'])} topics (need 2-12)")
        if ch["prefix"] in prefixes or not re.fullmatch(r"[a-z0-9]+", ch["prefix"]):
            out.append(f"{ch['slug']}: bad or repeated prefix {ch['prefix']}")
        prefixes.add(ch["prefix"])
        if ch["slug"] in names:
            out.append(f"repeated chapter slug {ch['slug']}")
        names.add(ch["slug"])
        for t in ch["topics"]:
            if t["slug"] in slugs:
                out.append(f"repeated topic slug {t['slug']}")
            slugs.add(t["slug"])
            if len(t["slug"]) > 48 or len(t["n"]) > 60:
                out.append(f"{t['slug']}: slug or name too long")
    return out


def existing(slug: str) -> list[dict]:
    p = QDIR / f"{slug}.yaml"
    return (yaml.safe_load(p.read_text())["questions"] or []) if p.exists() else []


def header(ch: dict, order: int) -> str:
    topics = "".join(
        f"    - slug: {t['slug']}\n      name: {json.dumps(t['n'], ensure_ascii=False)}\n" for t in ch["topics"]
    )
    return (
        f"subject: biology\nchapter:\n  slug: {ch['slug']}\n  name: {json.dumps(ch['name'], ensure_ascii=False)}\n"
        f"  order: {order}\n  classes: {ch['classes']}\n  topics:\n{topics}questions:"
    )


def cmd_setup(plan: list[dict]) -> int:
    bad = problems(plan)
    if bad:
        print("\n".join(bad))
        return 1
    syl_path = ROOT / "syllabus.yaml"
    text = syl_path.read_text()
    if "\nbiology:" not in text:
        lines = ["", "biology:"]
        for n, ch in enumerate(plan, 1):
            lines.append(
                f"  - {{slug: {ch['slug']}, prefix: {ch['prefix']}, order: {n}, classes: {ch['classes']}, "
                f"name: {json.dumps(ch['name'], ensure_ascii=False)}}}"
            )
        syl_path.write_text(text.rstrip("\n") + "\n" + "\n".join(lines) + "\n")
        print("syllabus.yaml: added biology section")
    QDIR.mkdir(parents=True, exist_ok=True)
    for n, ch in enumerate(plan, 1):
        p = QDIR / f"{ch['slug']}.yaml"
        if p.exists():
            body = p.read_text()
            body = body[body.index("\nquestions:") + len("\nquestions:") :]
            p.write_text(header(ch, n) + body)
            print(f"rewrote header of {p.name}")
        else:
            p.write_text(header(ch, n) + "\n")
    return 0


def split(n: int) -> list[int]:
    e = round(MIX[0] * n)
    d3 = round(MIX[1] * n)
    d4 = round(MIX[2] * n)
    d5 = n - e - d3 - d4
    d1 = round(e * 0.4)
    return [d1, e - d1, d3, d4, d5]


def cmd_assign(plan: list[dict], chapter: str, topic: str) -> int:
    ch = next(c for c in plan if c["slug"] == chapter)
    t = next(t for t in ch["topics"] if t["s"] == topic or t["slug"] == topic)
    have = [q for q in existing(chapter) if q["topic"] == t["slug"]]
    n = t["c"] - len(have)
    d = split(n)
    base, extra = divmod(n, 4)
    pos = [base + (1 if i < extra else 0) for i in range(4)]
    out = Path("/tmp/claude-0/-home-user-app/e4ab6a93-22ed-5393-9b24-bcd6f28ab419/scratchpad/gen")
    f = out / f"bio_{chapter}__{t['s']}.yaml"
    print(f"""ASSIGNMENT: write exactly {n} NEW questions
 Subject: biology. Chapter: {ch['name']} (slug `{chapter}`, NCERT Class {'/'.join(map(str, ch['classes']))} Biology).
 Topic: {t['n']}  (slug `{t['slug']}`).
 Scope (NCERT content for this topic): {t['k']}
 Difficulty mix to write: difficulty 1: {d[0]}, 2: {d[1]}, 3: {d[2]}, 4: {d[3]}, 5: {d[4]}
 Correct-answer positions (`answer` 0..3) to use: {pos[0]}, {pos[1]}, {pos[2]}, {pos[3]}
 Output file: {f}
 Check command (from /home/user/app):
   uv run --with pyyaml --with pydantic python content/tools/bank.py add biology {chapter} {f} --dry-run
""")
    if have:
        print(f"Already in this topic ({len(have)}): do not repeat these ideas.")
        for q in have:
            print(f"  - [{q['id']}] {q['stem'].replace(chr(10), ' ')[:140]}")
    return 0


def cmd_status(plan: list[dict]) -> int:
    done = 0
    for ch in plan:
        c = Counter(q["topic"] for q in existing(ch["slug"]))
        total = sum(c.values())
        done += total
        print(f"{ch['slug']:32} {total:4}/{TARGET}  " + " ".join(f"{t['s']}:{c[t['slug']]}/{t['c']}" for t in ch["topics"] if c[t["slug"]] < t["c"]))
    print(f"total {done}/{TARGET * len(plan)}")
    return 0


def cmd_queue(plan: list[dict], limit: int) -> int:
    """Topics still to write: merged / file written (in progress or ready to merge) / not started."""
    gen = Path("/tmp/claude-0/-home-user-app/e4ab6a93-22ed-5393-9b24-bcd6f28ab419/scratchpad/gen")
    todo = []
    for ch in plan:
        c = Counter(q["topic"] for q in existing(ch["slug"]))
        for t in ch["topics"]:
            if c[t["slug"]] >= t["c"]:
                continue
            f = gen / f"bio_{ch['slug']}__{t['s']}.yaml"
            todo.append((ch["slug"], t["s"], "written" if f.exists() else "new", t["c"] - c[t["slug"]]))
    new = [x for x in todo if x[2] == "new"]
    print(f"{len(todo)} topics unmerged: {sum(x[2] == 'written' for x in todo)} written, {len(new)} not started")
    for ch, t, st, n in new[:limit]:
        print(f"  {ch} {t}  ({n})")
    return 0


def main() -> int:
    plan = load_plan()
    cmd = sys.argv[1] if len(sys.argv) > 1 else "check"
    if cmd == "check":
        bad = problems(plan)
        print("\n".join(bad) if bad else f"plan ok: {len(plan)} chapters, {sum(len(c['topics']) for c in plan)} topics")
        return 1 if bad else 0
    if cmd == "setup":
        return cmd_setup(plan)
    if cmd == "assign":
        return cmd_assign(plan, sys.argv[2], sys.argv[3])
    if cmd == "status":
        return cmd_status(plan)
    if cmd == "queue":
        return cmd_queue(plan, int(sys.argv[2]) if len(sys.argv) > 2 else 20)
    return 2


if __name__ == "__main__":
    sys.exit(main())
