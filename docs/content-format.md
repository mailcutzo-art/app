# Content format

Question content lives in `content/` as YAML and is loaded into PostgreSQL by the backend seed
script. Admins can later import more through the admin panel using the same schema (CSV rows map
1:1 to the question fields below).

> **Current content is a small test set** (2 chapters per subject, 8 questions each, one passage
> and five words per subject). It exists to exercise every feature end to end. The real question
> bank will be imported later.

```
content/
  catalog.yaml                        goals (exams) and subjects
  questions/<subject>/<chapter>.yaml  one file per chapter, named after the chapter slug
  passages/<subject>.yaml             Fun & Learn comprehension passages
  words/<subject>.yaml                Guess-the-Word terms
  tools/validate.py                   schema + quality checks (run in CI)
```

## How questions are organised

```
Exam (NEET, JEE) ─┬─ Subject (Physics…) ── Chapter (Kinematics…) ── Topic (Projectile motion…)
                  └─ a subject can belong to several exams (Physics and Chemistry are in both)
```

Every question points at exactly one **subject → chapter → topic**. Topics are the smallest unit
a student revises on its own, and they are what personal tips refer to ("Focus on Projectile
motion"). Each question also has a **difficulty** (1–5) and a **category**:

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
automatically. A literal `*` always toggles italics, so write "antibonding π orbital" rather than
"π*".

YAML tips: quote a value that contains `: ` (colon + space) or starts with `*`, and quote options
that look like numbers (`"12"`) so they stay text.

## Chapter file

```yaml
subject: physics            # slug from catalog.yaml
chapter:
  slug: kinematics          # unique within the subject, [a-z0-9-]; also the file name
  name: Motion in a Straight Line
  order: 1                  # display order within the subject
  topics:                   # 2–8 topics; every topic needs at least 2 questions.
                            # Topic slugs are unique within the subject: the app and
                            # API name a topic by subject and slug.
    - slug: speed-velocity
      name: Speed and velocity
    - slug: equations-of-motion
      name: Equations of motion
questions:
  - id: phy-kin-005         # globally unique, stable: <subj>-<chap>-<nnn>
    topic: equations-of-motion   # one of chapter.topics
    category: numerical     # concept | numerical | factual | application
    exams: [jee]            # optional; omit = every exam that includes the subject
    difficulty: 2           # 1 (easy) … 5 (hard)
    battle: true            # short enough to answer in 15 s in a live battle
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

Rules checked by `content/tools/validate.py`:

- 4 options, all distinct (case- and space-insensitive), exactly one `answer` index in 0–3.
- Every question has a topic from its chapter, a category and an explanation of at least 10
  characters. `exams`, when given, only names exams that include the subject.
- `id` is unique across all files and follows `<subj>-<chap>-<nnn>`.
- No duplicate stems (normalized) anywhere; no duplicate chapter slugs or orders in a subject.
- Balanced `{}` in markup; no LaTeX commands (`\frac`, `$…$`).
- Stems ≤ 300 characters; options ≤ 120; battle questions ≤ 180-character stems.
- Each chapter has at least 7 questions with `battle: true` (one Quick Battle). A real bank should
  have 15+ per chapter so players rarely see repeats.
- Each chapter uses at least 2 categories, and answer positions are spread out (no chapter has
  more than 45% of answers at one index).

Writing guidance: questions are original, syllabus-aligned (NCERT class 11–12 scope), with one
unambiguous correct answer and plausible distractors. Battle questions test one idea and need no
long calculation. Explanations teach: state the concept, then the step that gets the answer.

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
