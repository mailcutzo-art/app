# Chemistry completion report

**CHEMISTRY STATUS: COMPLETE (21 of 21 chapters at 500 questions)**

Generated from the files by `content/tools/audit.py` (tracker: `content/question_generation_progress.json`)
and `content/tools/validate.py` (exits clean).

| | Chapters | Questions |
|---|---|---|
| Class 11 | 11 / 11 complete | 5,500 |
| Class 12 | 10 / 10 complete | 5,000 |
| **Total** | **21 / 21** | **10,500** |

## What was done

- **Audit** of the 9,989 questions on disk: 20 chapters were at 494–500, and Biomolecules did not exist.
- **Duplicates removed: 17.** Each repeated another question with only numbers, species or option
  order changed (for example `che-basic-310` vs `che-basic-111`, `che-amine-460` vs `che-amine-119`),
  or asked the same molecule twice across chapters (`che-goc-434` vs `che-ape-006`). Fifteen near-duplicate
  pairs that test different ideas were read side by side and kept (`content/tools/reviewed_pairs.txt`).
- **Missing questions generated: 528.** Biomolecules in full (500 across 12 topics) and 28 top-ups in 11
  chapters that the duplicate clean-up left short.
- **Incorrect or unclear questions corrected: 3**, by editing the wording: `che-amine-240` (a statement
  that contradicted NCERT's boiling-point comparison), `che-per-246` (a radius claim that Ne's van der
  Waals radius contradicts) and `che-pblock-414` (what "electrons surround Al" counts).
- **Writer output left out as outside the NCERT-based NEET syllabus:** osazone formation, Na–Hg reduction,
  pKa/pI arithmetic, CIP descriptors, protecting-group synthesis, biotin and folic acid, codon-table and
  reading-frame problems. About 40 questions were dropped for this reason; 12 of them are kept as seed
  material for Biology's Molecular Basis of Inheritance.

## Quality checks run

| Check | Result |
|---|---|
| Schema, ids, distinct options, markup, battle lengths, answer spread (`validate.py`) | pass |
| Every chapter 500/500, ids unique, no exact duplicate stems across the subject | pass |
| Near-duplicates (4-word shingle similarity ≥ 0.7 on stem + options, across all chapters) | 0 unreviewed |
| Numerical questions whose answer number is missing from the explanation | 15 of 2,008, all checked by hand and correct |
| Explanations naming an option letter that disagrees with the key | 0 |
| **Independent blind solve** of 500 sampled questions from the original bank (weighted to numerical and hard items; reviewers never saw the key) | **500 / 500 agree with the key** |
| Control for that method: 12 stems with a number altered, 12 untouched | 10 / 12 altered ones caught outright, the other 2 noted the inconsistency; no false alarms |
| Independent blind solve of 100 of the 528 new questions | 100 / 100 agree with the key (one reviewer slip checked and the key was right) |

## What was not verified

- About 428 of the 528 new questions (most of Biomolecules and the 28 top-ups) were **not** independently
  re-solved. They were checked by their writers (numbers verified in Python), by the dry-run schema and
  duplicate checks, and by my scope review of each batch. The independent review was stopped at your request.
- The original bank was spot-checked on 500 of about 9,990 questions (5%), not fully re-solved.
- 140 diagram questions carry a text description only; no artwork exists.

## Difficulty, format and balance (whole Chemistry bank)

| `difficulty` | Share | Target |
|---|---|---|
| 1–2 easy | 26.8% | 20% |
| 3 standard | 49.9% | 45% |
| 4 hard | 22.8% | 25% |
| 5 NEET+ | 0.6% | 10% |

The original bank was written on a 1–4 scale and has almost no level-5 questions, so NEET+ is **under target
bank-wide** (the 528 new questions follow the 20/45/25/10 mix: 8% at level 5 in Biomolecules). Raising the
older chapters would mean writing roughly 900 new level-5 questions or re-grading existing ones; it was not
done.

Formats: direct 54%, statement family 27% (assertion–reason 7%, multi-statement 7%, statements 7%,
statement-pair 6%), case 6%, ordering 5%, match 5%, graph 3%, diagram 1%. Correct answers: A 25.2%,
B 24.9%, C 25.4%, D 24.5%. 72% rest directly on NCERT text; 39% are battle-length.
