# Content format

Starter content lives in `content/` as YAML and is loaded into PostgreSQL by the backend seed
script. Admins can later import more through the admin panel using the same schema (CSV rows map
1:1 to the question fields below).

```
content/
  catalog.yaml                      goals and subjects
  questions/<subject>/<chapter>.yaml  one file per chapter
  passages/<subject>.yaml           Fun & Learn comprehension passages
  words/<subject>.yaml              Guess-the-Word terms
  tools/validate.py                 schema + quality checks (run in CI)
```

## Text markup

Question stems, options and explanations use a tiny markup rendered natively by the app:

| Markup | Renders | Example |
|---|---|---|
| `x^2`, `x^{n+1}` | superscript | `m s^{-2}` → m s⁻² |
| `H_2O`, `a_{max}` | subscript | `H_2SO_4` → H₂SO₄ |
| `**bold**`, `*italic*` | emphasis | |

Use Unicode for symbols: `θ λ Δ π μ Ω → ⇌ ° ± × ÷ ≈ ≤ ≥ √`. Don't use LaTeX in v1 content.
Use `−` (U+2212) for minus signs in running text; inside `^{}`/`_{}` a plain `-` is converted
automatically.

## Chapter file

```yaml
subject: physics            # slug from catalog.yaml
chapter:
  slug: kinematics          # unique within the subject, [a-z0-9-]
  name: Motion in a Straight Line
  order: 2                  # display order within the subject
questions:
  - id: phy-kin-001         # globally unique, stable: <subj>-<chap>-<nnn>
    difficulty: 2           # 1 (easy) … 5 (hard)
    battle: true            # short enough to answer in 15 s in a live battle
    tags: [acceleration]
    stem: A car accelerates uniformly from rest to 20 m s^{-1} in 5 s. What is its acceleration?
    options:                # exactly 4, all different
      - 2 m s^{-2}
      - 4 m s^{-2}
      - 5 m s^{-2}
      - 100 m s^{-2}
    answer: 1               # 0-based index of the single correct option
    explanation: a = (v − u)/t = (20 − 0)/5 = 4 m s^{-2}.
```

Rules checked by `content/tools/validate.py`:

- 4 options, all distinct (case- and space-insensitive), exactly one `answer` index in 0–3.
- Every question has an explanation of at least 10 characters.
- `id` is unique across all files and follows `<subj>-<chap>-<nnn>`.
- No duplicate stems (normalized) anywhere.
- Balanced `{}` in markup; no LaTeX commands (`\frac`, `$…$`).
- Stems ≤ 300 characters; options ≤ 120; battle questions ≤ 180-character stems.
- Each chapter has at least 15 questions with `battle: true`.
- Answer positions are spread out (no chapter has more than 45% of answers at one index).

Writing guidance: questions are original, syllabus-aligned (NCERT class 11–12 scope), with one
unambiguous correct answer and plausible distractors. Battle questions test one idea and need no
long calculation. Explanations teach: state the concept, then the step that gets the answer.

## Passages (Fun & Learn)

```yaml
subject: biology
passages:
  - id: bio-passage-01
    title: How enzymes speed up reactions
    difficulty: 2
    body: |
      Two to four short paragraphs, 120–250 words …
    questions:               # 3–5, same fields as chapter questions minus `battle`
      - id: bio-passage-01-q1
        stem: …
        options: [ … ]
        answer: 0
        explanation: …
```

## Words (Guess the Word)

```yaml
subject: chemistry
words:
  - id: chem-word-001
    word: ISOTOPE            # 3–12 letters A–Z, no spaces
    clue: Atoms of the same element with different numbers of neutrons.
    difficulty: 2
```
