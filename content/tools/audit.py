"""Audit the question bank and (re)write question_generation_progress.json.

Run from the repo root (read-only except for the tracker; safe to re-run at any time):

    uv run --with pyyaml python content/tools/audit.py            # table + tracker
    uv run --with pyyaml python content/tools/audit.py --pairs    # also list duplicate pairs
    uv run --with pyyaml python content/tools/audit.py --subject chemistry

For every chapter in syllabus.yaml it reports the expected count, the questions on disk, the
next free id number, structural problems, exact/near duplicates and the NEET level mix, then
assigns a status: COMPLETE, PARTIALLY_COMPLETE, NOT_STARTED or NEEDS_REVIEW. The tracker is
rebuilt from the files, never trusted, so an interrupted run resumes from what is really saved.
"""

import argparse
import json
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
TRACKER = ROOT / "question_generation_progress.json"
TARGET = 500
# Existing banks may be a few questions short of 500 after duplicate clean-up; the project
# counts a chapter complete only at the full target.
NEAR_DUP_JACCARD = 0.7
LEVEL = {1: "easy", 2: "easy", 3: "standard_neet", 4: "hard_neet", 5: "neet_plus"}


def norm_numbers(s: str) -> str:
    s = re.sub(r"[0-9]+(\.[0-9]+)?", "#", s.lower())
    return re.sub(r"[^a-z#]+", " ", s).strip()


def shingles(text: str) -> set[str]:
    w = norm_numbers(text).split()
    return {" ".join(w[i : i + 4]) for i in range(max(1, len(w) - 3))}


def exact_key(q: dict) -> str:
    return re.sub(r"[^a-z0-9]+", "", str(q["stem"]).lower())


def near_pairs(qs: list[dict]) -> list[tuple[str, str, float]]:
    sh = [shingles(q["stem"] + " " + " ".join(map(str, q["options"]))) for q in qs]
    inv: dict[str, list[int]] = defaultdict(list)
    out = []
    for i, s in enumerate(sh):
        cand: Counter = Counter()
        for g in s:
            for j in inv[g]:
                cand[j] += 1
        for j, n in cand.items():
            if n >= NEAR_DUP_JACCARD * min(len(s), len(sh[j])):
                jac = len(s & sh[j]) / len(s | sh[j])
                if jac >= NEAR_DUP_JACCARD:
                    out.append((qs[j]["id"], qs[i]["id"], round(jac, 2)))
        for g in s:
            inv[g].append(i)
    return out


def reviewed_pairs() -> set[frozenset]:
    """Pairs a human judged distinct (tools/reviewed_pairs.txt), so they are not flagged again."""
    path = ROOT / "tools" / "reviewed_pairs.txt"
    out = set()
    for line in path.read_text().splitlines() if path.exists() else []:
        ids = line.split("#")[0].split()
        if len(ids) == 2:
            out.add(frozenset(ids))
    return out


def load_subject(subject: str, syllabus: dict) -> dict[str, list[dict]]:
    out = {}
    for entry in syllabus[subject]:
        p = ROOT / "questions" / subject / f"{entry['slug']}.yaml"
        out[entry["slug"]] = (yaml.safe_load(p.read_text())["questions"] or []) if p.exists() else []
    return out


def global_dups(by_chapter: dict[str, list[dict]]) -> tuple[dict, dict]:
    """Exact and near duplicates across the whole subject, charged to the later question's chapter."""
    flat = [(slug, q) for slug, qs in by_chapter.items() for q in qs]
    owner = {q["id"]: slug for slug, q in flat}
    first: dict[str, str] = {}
    exact: dict[str, list] = defaultdict(list)
    for _, q in flat:
        k = exact_key(q)
        if k in first:
            exact[owner[q["id"]]].append((first[k], q["id"]))
        else:
            first[k] = q["id"]
    near: dict[str, list] = defaultdict(list)
    for a, b, j in near_pairs([q for _, q in flat]):
        if frozenset((a, b)) not in reviewed_pairs():
            near[owner[b]].append((a, b, j))
    return exact, near


def audit_chapter(subject: str, entry: dict, qs: list, exact: list, near: list) -> dict:
    rec = {
        "classes": entry["classes"],
        "target": TARGET,
        "existing": 0,
        "valid": 0,
        "duplicates": 0,
        "near_duplicates": 0,
        "missing": TARGET,
        "next_id_number": 1,
        "levels": {},
        "problems": [],
        "pairs": [],
        "status": "NOT_STARTED",
    }
    if not qs:
        return rec
    rec["existing"] = len(qs)
    nums, bad = [], 0
    prefix = f"{ {'chemistry': 'che', 'biology': 'bio', 'physics': 'phy', 'maths': 'mat'}[subject] }-{entry['prefix']}-"
    ids = Counter(q["id"] for q in qs)
    for q in qs:
        ok = True
        if not q["id"].startswith(prefix):
            ok = False
        else:
            nums.append(int(q["id"][len(prefix) :]))
        opts = [re.sub(r"\s+", "", str(o).lower()) for o in q["options"]]
        if len(q["options"]) != 4 or len(set(opts)) != 4:
            ok = False
        if q.get("answer") not in (0, 1, 2, 3):
            ok = False
        if len(str(q.get("explanation", ""))) < 10:
            ok = False
        if ids[q["id"]] > 1:
            ok = False
        bad += not ok
    rec["valid"] = len(qs) - bad
    rec["next_id_number"] = max(nums, default=0) + 1
    rec["duplicates"] = len(exact)
    pairs = [(a, b, 1.0) for a, b in exact] + near
    rec["near_duplicates"] = len(near)
    rec["pairs"] = pairs
    rec["levels"] = dict(Counter(LEVEL[q["difficulty"]] for q in qs))
    rec["missing"] = max(0, TARGET - rec["valid"] + rec["duplicates"])
    if bad:
        rec["problems"].append(f"{bad} structurally invalid questions")
    if rec["duplicates"] or rec["near_duplicates"]:
        rec["status"] = "NEEDS_REVIEW"
    elif rec["valid"] >= TARGET:
        rec["status"] = "COMPLETE"
    else:
        rec["status"] = "PARTIALLY_COMPLETE"
    if bad or rec["duplicates"]:
        rec["status"] = "NEEDS_REVIEW"
    return rec


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--subject", action="append")
    ap.add_argument("--pairs", action="store_true")
    args = ap.parse_args()
    syllabus = yaml.safe_load((ROOT / "syllabus.yaml").read_text())
    subjects = args.subject or [s for s in ("chemistry", "biology") if s in syllabus]
    tracker: dict = {"target_per_chapter": TARGET}
    for subject in subjects:
        tracker[subject] = {}
        by_chapter = load_subject(subject, syllabus)
        exact, near = global_dups(by_chapter)
        for entry in syllabus[subject]:
            slug = entry["slug"]
            rec = audit_chapter(subject, entry, by_chapter[slug], exact[slug], near[slug])
            for cl in entry["classes"][:1]:
                tracker[subject].setdefault(f"class_{cl}", {})[entry["name"]] = rec
            print(
                f"{subject:9} | Class {'/'.join(map(str, entry['classes'])):5} | {entry['name'][:42]:42} "
                f"| {rec['existing']:3}/{rec['target']} valid {rec['valid']:3} dup {rec['duplicates']} "
                f"near {rec['near_duplicates']:2} missing {rec['missing']:3} | {rec['status']}"
            )
            if args.pairs:
                for a, b, j in rec["pairs"]:
                    print(f"      near-dup {a} ~ {b} ({j})")
    for subject in subjects:
        for cl, chapters in tracker[subject].items():
            for rec in chapters.values():
                rec.pop("pairs", None)
    TRACKER.write_text(json.dumps(tracker, indent=2, ensure_ascii=False) + "\n")
    print(f"wrote {TRACKER.relative_to(ROOT.parent)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
