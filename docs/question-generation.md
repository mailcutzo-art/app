# Writing NEET bank questions (brief for writers and generator agents)

Read [`content-format.md`](content-format.md) first: it is the schema. This page is the standard a
question must meet and the loop for adding a batch. Target: **500 questions per chapter**.

## Workflow (resumable)

1. `uv run --with pyyaml python content/tools/audit.py` shows what is done. It rebuilds
   `content/question_generation_progress.json` from the files; trust the files, not memory.
2. Write a batch (about 50 questions) as a YAML **list** of questions in the chapter-file format,
   **without `id`**, to a scratch file.
3. `uv run --with pyyaml --with pydantic python content/tools/bank.py add <subject> <chapter> <batch.yaml> --dry-run`
   Fix every rejection (schema, duplicate stem, near-duplicate, cross-referencing option, topic,
   battle length) and write a replacement that tests a **different idea**, not the same item re-worded.
4. Never edit chapter files by hand and never choose ids: `bank.py add` numbers from the highest
   existing id + 1, appends, and is idempotent (re-adding a batch adds nothing).

## What a NEET question is here

Original questions that could realistically appear in NEET UG, from the NCERT-based NEET syllabus
(NCERT is the primary source; stay inside it). Not a school-textbook bank, and not JEE/Olympiad:
a harder question has more **reasoning depth, concept integration, trap quality or interpretation**,
never more syllabus breadth or obscure facts. Do not copy previous-year questions; learn the
pattern and write new ones.

### Difficulty (`difficulty`, 1–5) — per batch aim for

| Share | `difficulty` | Meaning |
|---|---|---|
| 20% | 1–2 | Easy: direct understanding of an important basic idea |
| 45% | 3 | Standard NEET: a realistic exam question |
| 25% | 4 | Hard NEET: multi-step, combines concepts, conceptual trap |
| 10% | 5 | NEET+: hardest defensible-from-NCERT questions, strong students must think |

`time` (seconds): about 20 / 30 / 50 / 85 / 120 for difficulty 1 / 2 / 3 / 4 / 5.

### Formats (`format`) — use a format only where it makes academic sense

Roughly: `direct` 40–50%; the statement family (`statements`, `multi-statement`,
`statement-pair`, `assertion-reason`) 25–30%; the rest from `match`, `ordering`, `case`, `graph`,
`diagram`. Use the exact option wording of NEET for statement-pair and assertion–reason (see any
chapter file for the four standard options). Options never refer to each other ("all of the above",
"both A and B"); label statements I–IV and list items P–S / 1–4 instead.

### Question quality rules

- Exactly four plausible, distinct options and exactly one best answer. Distractors should be
  mistakes a student really makes (a skipped step, a confused term, a sign or unit slip), not
  obviously absurd. Avoid ambiguous options and two defensible answers.
- **Spread the correct answer evenly** over A/B/C/D (`answer` 0–3) within every batch. No pattern.
- Diversity beats volume. Two questions are the same if they need the same reasoning and differ
  only in numbers, names or species. Spend the 500 on different concepts, angles and traps in
  proportion to how important each concept is: major concepts get more questions, minor ones few.
- Science must be right: every reaction valid, every fact in NCERT (or a direct consequence of it),
  every number checked. Do each calculation in Python (or by hand twice) before saving the answer.
  Never invent a reaction, structure or fact to fill a slot.
- Explanation (1–4 sentences, mobile-sized): state the concept and why the answer is right; for
  numericals show the formula and the arithmetic; for statement types say which statements are
  right or wrong and why; for hard questions name the trap. It must agree with `answer`.
- `ncert: true` when the question rests directly on NCERT text. `battle: true` only for a single-idea
  question with a stem of at most 180 characters and no diagram; about 35–40% of questions.
- `subtopic` (a finer area) and `concept` (the single idea tested, one line) on every question;
  `tags` 1–3 short kebab-case labels; `formula` when a formula is used. Questions that need a
  figure use `format: diagram` or `graph` with a precise `diagram:` description (every label, value
  and arrow) and `battle: false`.
- Markup as in `content-format.md`: `H_2O`, `x^2`, Unicode symbols, no LaTeX. Quote options that
  look like numbers (`"12"`). Use a block scalar (`stem: |-`) for stems with one statement per line.
- Chemistry by branch. Physical: numericals, graphs, units, multi-step reasoning, no number-swap
  clones. Organic: products, reagents, conditions, mechanisms at NEET depth, stability/acidity
  orders, named reactions in the syllabus, conversions. Inorganic: NCERT statements, trends,
  exceptions, oxidation states, structures, colours. Biology: NCERT-statement, multi-statement,
  diagram, assertion–reason, match, sequencing, exceptions and commonly confused terms; hard means
  very similar options and combined NCERT ideas, never obscure facts.

## Batch file shape

```yaml
- topic: peptides-proteins        # a topic slug of the chapter (see the chapter file header)
  subtopic: Peptide bond
  concept: The peptide bond is a planar amide linkage with partial double-bond character
  category: concept               # concept | numerical | factual | application
  format: direct
  difficulty: 3
  time: 50
  ncert: true
  battle: true
  tags: [peptide-bond, amide]
  stem: ...
  options:
    - ...
    - ...
    - ...
    - ...
  answer: 2                       # 0-based
  explanation: ...
```
