# Biology writers: extra rules

Read [`question-generation.md`](question-generation.md) first (standard, formats, difficulty mix,
workflow). These rules add to it and come from what went wrong in Chemistry.

## Scope: NCERT only

- The source is the **NCERT Class 11 / Class 12 Biology** textbook (current, rationalised edition) as
  tested by **NEET UG**. If a fact is not in NCERT, do not use it, however well known. Do not write a
  question whose key is a textbook fact outside NCERT, and do not use a recalled-but-unsure
  detail (a number, a date, a species name, a vitamin list) you cannot place in NCERT.
- **Never contradict NCERT.** If NCERT simplifies, the question follows NCERT, not a more precise
  textbook. No hypothetical premise whose answer opposes NCERT's statement.
- Difficulty comes from **very similar options, combined statements from different parts of the
  chapter, exceptions, diagrams, sequence/order, cause and effect, and commonly confused terms**,
  never from obscure facts. A NEET+ (5) question should make a strong student think and still be
  defensible from NCERT text.
- Names: use the scientific and common names, examples and numbers that NCERT itself uses.

## Mix (per topic, as the assignment prints it)

NEET Biology is NCERT-statement heavy. Aim for: `direct` about 35–40%; statement family
(`statements`, `multi-statement`, `statement-pair`, `assertion-reason`) **30–35%**; `match` 5–8%;
`ordering` (process/sequence) 5–8%; `diagram` and `graph` 8–12% (describe the figure fully in
`diagram:`, set `battle: false`); `case` 4–6%. Not overwhelmingly direct recall.

- Numerical questions only where NCERT has real quantities (genetics crosses and ratios, lung
  volumes, population growth, species–area, DNA/chromosome counts through cell division, energy
  flow, ATP counts, Hardy–Weinberg). Verify every number in Python.
- Matching and statement questions must have one unambiguous best option. When a statement is
  debatable in modern biology but fixed in NCERT, avoid it.
- Do not ask the same fact twice with a different wording. Cover different NCERT lines, different
  organisms, different comparison pairs, different diagrams and different exceptions.

## Lessons from Chemistry (do not repeat)

- Writers invented scope (osazones, pKa arithmetic, R/S descriptors, codon tables). In Biology the
  equivalent is advanced detail beyond NCERT: molecular mechanisms NCERT does not name, enzyme
  names, hormone side effects, taxonomic splits NCERT does not use, textbook-only figures.
- A hypothetical that makes the key oppose NCERT was rejected. A derived calculation based on NCERT
  numbers was fine.
- Do not re-word a question already in your topic. Read the existing questions of your topic first.

## Figure descriptions

`diagram:` (at least 40 characters) must let an illustrator draw the figure: every label, arrow,
value and position. Use for cell organelles, life cycles, stage-wise division, anatomy sections,
flowcharts, graphs (axes, units, curve shape), pedigrees (symbols, generations), ecological pyramids,
food webs. Questions that need a figure are `battle: false`.

## Writer protocol (what a topic writer does)

1. Run the assignment command it was given (`bio_setup.py assign <chapter> <topic>`) and follow it exactly:
   the number of questions, the difficulty counts, the answer-position counts, the output file and the
   dry-run command. Read this brief, `question-generation.md` and `content-format.md`, and skim one chapter
   file in `content/questions/chemistry/` for style.
2. Every question needs `topic` (the slug in the assignment), `subtopic`, `concept` (at most 120
   characters), `category`, `format`, `difficulty`, `time` (20/30/50/85/120 for difficulty 1–5), `ncert`,
   `battle` (stem at most 180 characters, no diagram, about 35–40% true), `tags`, `stem`, four `options`,
   `answer` and an `explanation` that agrees with the key. About 85% should be `ncert: true`.
3. Write the YAML list (no `id`) to the output file. Quote strings containing `: ` or starting with `*`,
   and numeric-looking options. Run the dry-run command and replace every rejected question with a
   genuinely different one until none is rejected.
4. Do not run `add` without `--dry-run`, do not edit repo files, do not use git. Reply with three lines:
   the number written, the final dry-run line, and any doubts about NCERT fidelity.
