"""Blind independent review of questions: pack them without the key, then grade the answers.

    # choose ids (all of a chapter, the ones added after a given number, or a seeded sample)
    uv run --with pyyaml python content/tools/review_pack.py sample chemistry --per-chapter 25 --seed 1 --out ids.txt
    uv run --with pyyaml python content/tools/review_pack.py ids chemistry biomolecules --out ids.txt
    # a reviewer gets only the blind pack: stems, options and figure descriptions, never the
    # answer, explanation or concept
    uv run --with pyyaml python content/tools/review_pack.py pack chemistry ids.txt --out blind.json
    # the reviewer writes {"<id>": {"a": "B", "note": "..."}} ("a": null = no/multiple correct answers)
    uv run --with pyyaml python content/tools/review_pack.py grade chemistry answers.json

``grade`` compares every reviewer answer with the key and lists each disagreement with the
question's explanation, so a person (or a second reviewer) can decide who is right.
"""

import argparse
import json
import random
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]


def load(subject: str) -> list[tuple[str, dict]]:
    out = []
    for path in sorted((ROOT / "questions" / subject).glob("*.yaml")):
        data = yaml.safe_load(path.read_text())
        out.extend((data["chapter"]["slug"], q) for q in data["questions"] or [])
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("sample")
    s.add_argument("subject")
    s.add_argument("--per-chapter", type=int, default=25)
    s.add_argument("--seed", type=int, default=1)
    s.add_argument("--hard-share", type=float, default=0.6, help="share drawn from numerical/difficulty>=4")
    s.add_argument("--max-id", type=int, default=500, help="only ids numbered up to this (the old bank)")
    s.add_argument("--out", required=True)
    i = sub.add_parser("ids")
    i.add_argument("subject")
    i.add_argument("chapter", nargs="+")
    i.add_argument("--min-id", type=int, default=0)
    i.add_argument("--out", required=True)
    p = sub.add_parser("pack")
    p.add_argument("subject")
    p.add_argument("ids")
    p.add_argument("--out", required=True)
    g = sub.add_parser("grade")
    g.add_argument("subject")
    g.add_argument("answers")
    args = ap.parse_args()

    qs = load(args.subject)
    if args.cmd == "sample":
        rng = random.Random(args.seed)
        chosen: list[str] = []
        by: dict[str, list[dict]] = {}
        for slug, q in qs:
            if int(q["id"].rsplit("-", 1)[1]) <= args.max_id:
                by.setdefault(slug, []).append(q)
        for slug, items in sorted(by.items()):
            hard = [q for q in items if q["category"] == "numerical" or q["difficulty"] >= 4]
            rest = [q for q in items if q not in hard]
            k = round(args.per_chapter * args.hard_share)
            pick = rng.sample(hard, min(k, len(hard)))
            pick += rng.sample(rest, min(args.per_chapter - len(pick), len(rest)))
            chosen += [q["id"] for q in pick]
        Path(args.out).write_text("\n".join(chosen) + "\n")
        print(f"{len(chosen)} ids -> {args.out}")
    elif args.cmd == "ids":
        want = set(args.chapter)
        ids = [
            q["id"] for slug, q in qs
            if slug in want and int(q["id"].rsplit("-", 1)[1]) > args.min_id
        ]  # fmt: skip
        Path(args.out).write_text("\n".join(ids) + "\n")
        print(f"{len(ids)} ids -> {args.out}")
    elif args.cmd == "pack":
        wanted = Path(args.ids).read_text().split()
        index = {q["id"]: q for _, q in qs}
        pack = []
        for qid in wanted:
            q = index[qid]
            item = {"id": qid, "stem": q["stem"], "options": {"ABCD"[n]: str(o) for n, o in enumerate(q["options"])}}
            if q.get("diagram"):
                item["figure_description"] = q["diagram"]
            pack.append(item)
        Path(args.out).write_text(json.dumps(pack, ensure_ascii=False, indent=1))
        print(f"{len(pack)} questions -> {args.out}")
    else:
        index = {q["id"]: q for _, q in qs}
        answers = json.loads(Path(args.answers).read_text())
        agree = bad = flagged = 0
        for qid, a in answers.items():
            q = index[qid]
            key = "ABCD"[q["answer"]]
            if a.get("a") == key:
                agree += 1
                continue
            bad += 1
            print(f"\n{qid}  key={key}  reviewer={a.get('a')}  d{q['difficulty']} {q['category']}")
            print("  STEM:", q["stem"].replace("\n", " ")[:300])
            print("  OPTS:", {"ABCD"[n]: str(o)[:60] for n, o in enumerate(q["options"])})
            print("  KEY EXPL:", q["explanation"][:400])
            print("  REVIEWER:", a.get("note", "")[:400])
        print(f"\n{len(answers)} reviewed: {agree} agree, {bad} disagree ({100 * bad / max(1, len(answers)):.1f}%)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
