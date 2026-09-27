# Content format

Question content lives in `content/` as YAML and is loaded into PostgreSQL by the backend seed
script. Admins can later import more through the admin panel using the same schema (CSV rows map
1:1 to the question fields below).

> **Physics and Chemistry** are being filled with the real NEET bank: every chapter in
> `syllabus.yaml` (50 in all) gets about 500 questions. **Biology and Maths** still hold the small
> test set (2 chapters, 8 questions each). Every subject has one passage and five words.

```
content/
  catalog.yaml                        goals (exams) and subjects
  syllabus.yaml                       every chapter of a subject: slug, name, order, class, id prefix
  questions/<subject>/<chapter>.yaml  one file per chapter, named after the chapter slug
  passages/<subject>.yaml             Fun & Learn comprehension passages
  words/<subject>.yaml                Guess-the-Word terms
  tools/validate.py                   schema + quality checks (run in CI)
  tools/export_seed.py                flat JSON seed files with ids (content/build/, not committed)
```

## How questions are organised

```
Exam (NEET, JEE) ─┬─ Subject (Physics…) ── Chapter (Kinematics…) ── Topic (Projectile motion…)
                  └─ a subject can belong to several exams (Physics and Chemistry are in both)
```

Every question points at exactly one **subject → chapter → topic**. Topics are the **module**
level of the database: the smallest unit a student revises on its own, and what personal tips refer
to ("Focus on Projectile motion"). A chapter has 2–12 topics, usually one per NCERT section. Each question also has a **difficulty** (1–5) and a **category**:

| Category | Meaning | Example |
|---|---|---|
| `concept` | Understanding a principle, definition or relationship, no calculation | "What does the slope of an x–t graph give?" |
| `numerical` | Needs a calculation, even a quick one | "How far does a car travel in 5 s at 2 m s⁻²?" |
| `factual` | Recall of a fact, name, value, unit or standard result | "What is the SI unit of velocity?" |
| `application` | Apply an idea to a new situation, compare statements, multi-step reasoning | "Which blood groups can the children have?" |

Categories power tips such as "Practise more Physics numericals".

## Text markup

Question stems, options and explanations use a tiny markup rendered natively by the app:

| Markup | Renders | Example |
|---|---|---|
| `x^2`, `x^{n+1}` | superscript (one character, or the braced group) | `m s^{-2}` → m s⁻² |
| `H_2O`, `a_{max}` | subscript | `H_2SO_4` → H₂SO₄ |
| `**bold**`, `*italic*` | emphasis (use italics for species names) | `*Escherichia coli*` |

Use Unicode for symbols: `θ λ Δ π μ Ω → ⇌ ° ± × ÷ ≈ ≤ ≥ √ ₹`. Don't use LaTeX in v1 content.
Use `−` (U+2212) for minus signs in running text; inside `^{}`/`_{}` a plain `-` is converted
automatically. Scripts nest (`d_{x^2−y^2}`, `e^{-x^2}`). A literal `*` in running text toggles
italics, but a lone `*` inside a script is kept, so antibonding orbitals are written `σ^{*}2s`,
`π^{*}2p`.

Stems keep their line breaks, so statement, assertion–reason and match questions put one item per
line. The app renders all of this with `QuizText` (design system); a question's `diagram` is shown
with `QuestionFigure` (the description in a "Figure" panel until artwork exists) and the
explanation and `formula` with `ExplanationCard`.

YAML tips: quote a value that contains `: ` (colon + space) or starts with `*`, and quote options
that look like numbers (`"12"`) so they stay text.

## Syllabus

`syllabus.yaml` lists every chapter of a subject in display order. A chapter file for that subject
must match its entry (`name`, `order`, `classes`), and its question ids use the entry's `prefix`:
`<subj>-<prefix>-<nnn>`, e.g. `phy-kin-001`. Chapters with no file yet are simply not seeded.

## Chapter file

```yaml
subject: physics            # slug from catalog.yaml
chapter:
  slug: kinematics          # unique within the subject, [a-z0-9-]; also the file name
  name: Motion in a Straight Line
  order: 2                  # display order within the subject
  classes: [11]             # NCERT class(es); must match syllabus.yaml
  topics:                   # 2–12 topics (modules); every topic needs at least 2 questions
    - slug: speed-velocity
      name: Speed and velocity
    - slug: equations-of-motion
      name: Equations of motion
questions:
  - id: phy-kin-005         # globally unique, stable: <subj>-<prefix>-<nnn>
    topic: equations-of-motion   # one of chapter.topics (the module)
    subtopic: Motion from rest     # optional: finer area within the topic
    concept: s = ut + ½at^2 with u = 0   # optional: the single idea tested
    category: numerical     # concept | numerical | factual | application
    format: direct          # optional, default direct; see "Formats" below
    exams: [jee]            # optional; omit = every exam that includes the subject
    difficulty: 2           # 1–2 easy, 3 medium, 4–5 hard
    time: 40                # optional: typical seconds to answer
    ncert: true             # optional: rests directly on NCERT text
    battle: true            # short enough to answer in 15 s in a live battle
    formula: s = ut + ½at^2  # optional: the formula used
    tags: [uniform-acceleration]   # optional free-form labels for search
    stem: A car starts from rest and accelerates uniformly at 2 m s^{-2}. How far does it travel in 5 s?
    options:                # exactly 4, all different
      - 10 m
      - 25 m
      - 50 m
      - 100 m
    answer: 1               # 0-based index of the single correct option
    explanation: Starting from rest (u = 0), s = ut + ½at^2 = ½ × 2 × 5^2 = 25 m.
```

A question that needs a figure adds `diagram:`, a description precise enough to draw it from
(every label, value and arrow). The app has no images yet, so these are practice-only
(`battle: false`) and the description is what an illustrator or SVG generator works from; the
export marks them `requires_diagram`.

### Formats

| `format` | Shape |
|---|---|
| `direct` | A plain single-idea question |
| `statements` | The four options are statements; pick the correct (or incorrect) one |
| `multi-statement` | Statements I–IV in the stem; options like "I and III only" |
| `statement-pair` | Statement I / Statement II with the four standard options |
| `assertion-reason` | Assertion (A) / Reason (R) with the four standard options |
| `match` | List I (P–S) against List II (1–4); options like "P-2, Q-4, R-1, S-3" |
| `ordering` | Arrange in increasing or decreasing order |
| `graph` | Read or choose a graph |
| `diagram` | Needs the figure in `diagram` |
| `case` | An experiment or real-life situation |

Options are shuffled in battles and labelled A–D by position, so an option must never refer to
another one ("All of the above", "Both A and B"). Label statements I–IV and list items P–S / 1–4
instead. Multi-line stems use a YAML block scalar (`stem: |-`), one statement per line.

Rules checked by `content/tools/validate.py`:

- 4 options, all distinct (case- and space-insensitive), exactly one `answer` index in 0–3.
- Every question has a topic from its chapter, a category and an explanation of at least 10
  characters. `exams`, when given, only names exams that include the subject.
- `id` is unique across all files and follows `<subj>-<chap>-<nnn>`.
- No duplicate stems (normalized) anywhere; no duplicate chapter slugs or orders in a subject.
- Balanced `{}` in markup; no LaTeX commands (`\frac`, `$…$`).
- Stems ≤ 700 characters; options ≤ 160; battle questions ≤ 180-character stems and no diagram.
- Options don't refer to other options; a `diagram` format question has a `diagram`.
- Chapters of a subject in `syllabus.yaml` match their entry and use its id prefix.
- Each chapter has at least 7 questions with `battle: true` (one Quick Battle). A real bank should
  have 15+ per chapter so players rarely see repeats.
- Each chapter uses at least 2 categories, and answer positions are spread out (no chapter has
  more than 45% of answers at one index).

Validate one chapter with a summary of its difficulty, category, format, answer and topic mix:
`uv run --with pyyaml --with pydantic python content/tools/validate.py --stats
content/questions/physics/waves.yaml`.

Writing guidance: questions are original, syllabus-aligned (NCERT class 11–12 scope), with one
unambiguous correct answer and plausible distractors. Battle questions test one idea and need no
long calculation. Explanations teach: state the concept, then the step that gets the answer.

## Seed export

`content/tools/export_seed.py` turns the YAML into one JSON array per table, in load order:
`goals`, `subjects` (with `goal_ids`), `chapters` (→ `subject_id`), `modules` (the topics,
→ `chapter_id`, `subject_id`) and `questions` (→ `module_id`, `chapter_id`, `subject_id`, with
`options[]` carrying `is_correct`, plus `difficulty_band`, `requires_diagram` and the metadata
above). Ids are UUIDv5 values derived from slugs and question ids, so they are stable across
exports and a seed script can upsert on them.

```bash
uv run --with pyyaml python content/tools/export_seed.py     # → content/build/seed/*.json
```

## Passages (Fun & Learn)

```yaml
subject: biology
passages:
  - id: bio-passage-01
    title: Mitochondria, the cell's power plants
    chapter: cell            # optional: a chapter slug of this subject
    difficulty: 2
    body: >-                 # folded: single line breaks join, blank lines start a paragraph
      Two to four short paragraphs, 300–2400 characters …
    questions:               # 3–5
      - id: bio-passage-01-q1
        category: factual    # required, as for chapter questions
        difficulty: 1        # optional; defaults to the passage's difficulty
        stem: …
        options: [ … ]
        answer: 0
        explanation: …
```

Passage questions have no `topic`, `exams` or `battle` field.

## Words (Guess the Word)

```yaml
subject: chemistry
words:
  - id: che-word-001
    word: ISOTOPE            # 3–12 letters A–Z, no spaces
    clue: Atoms of the same element with different numbers of neutrons.
    difficulty: 2
```
