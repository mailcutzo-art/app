# Biology status

The plan for all 34 NEET chapters is in `content/tools/biology_plan.yaml` (500 questions each).
**All 34 chapters are complete (17,000 questions)**, promoted into `content/questions/biology/` and validated.
`bio_setup.py promote <chapter>` moves a chapter into the validated bank once every topic reaches its
planned count; `bio_setup.py status` shows progress.

## Complete

The Living World, Biological Classification, Plant Kingdom, Animal Kingdom, Morphology of Flowering Plants,
Anatomy of Flowering Plants, Structural Organisation in Animals, **Cell: The Unit of Life**, Biomolecules,
Cell Cycle and Cell Division, Transport in Plants, Mineral Nutrition, Photosynthesis in Higher Plants,
Respiration in Plants, Plant Growth and Development, Breathing and Exchange of Gases, Body Fluids and
Circulation, Excretory Products and their Elimination, **Locomotion and Movement**, **Neural Control and
Coordination**, **Principles of Inheritance and Variation**, **Organisms and Populations**, **Ecosystem**, **Biodiversity and Conservation**, **Chemical Coordination and Integration**,
**Sexual Reproduction in Flowering Plants**, **Human Reproduction**, **Reproductive Health**, **Molecular Basis
of Inheritance**, **Evolution**, **Human Health and Disease**, **Microbes in Human Welfare**,
**Biotechnology: Principles and Processes**, **Biotechnology and its Applications**.

## Still to write

Nothing: all 34 planned chapters are in `content/questions/biology/`. The last three (Organisms and
Populations, Ecosystem, Biodiversity and Conservation) were written at the original 20 / 45 / 25 / 10 % mix,
at a high NEET level.

## Difficulty

The first 21 chapters were written to 20 / 45 / 25 / 10 % for levels 1-5, which is harder than Physics and
Chemistry (about 27 / 50 / 23 / 1 %). From Chemical Coordination onward (the last ten chapters) the mix is 27 / 50 / 22 / 1 %
(`bio_setup.py` `MIX`), matching the other subjects.

## Checks run on the newest seventeen chapters

- `validate.py` passes; every batch went through `bank.py` (schema, duplicate and near-duplicate checks).
- Mix per chapter: difficulty 8 / 12 / 45 / 25 / 10 % for levels 1-5, answer positions within one point of 25 %
  each, about 38 % battle questions, 84-90 % marked as resting directly on NCERT, 31-33 % statement-type
  questions, 10-11 % diagram and graph questions.
- **Blind review (Cell, Inheritance, Locomotion, Neural Control):** 520 of the new questions (weighted toward hard and numerical ones) were answered by
  independent reviewers who saw only the stems and options. 518 matched the key (99.6 %). One
  assertion-reason item (`bio-gen-456`) was ambiguous and was rewritten; the other disagreement
  (`bio-neural-255`) is NCERT's own wording and was left alone. The remaining ~1,100 new questions were
  not independently re-solved.
- **Blind review (Chemical Coordination, Sexual Reproduction in Flowering Plants, Human Reproduction,
  Reproductive Health, Molecular Basis of Inheritance):** 500 questions, weighted toward hard and numerical
  ones, were answered blind; 499 matched the key (99.8 %). The one mismatch (`bio-reprohealth-302`) follows
  NCERT's own MTP Act box; the reviewer used the later 2021 amendment. One figure description
  (`bio-molbasis-196`) was corrected. About 2,000 of these 2,500 questions were not independently re-solved.
- **Blind review (Evolution, Human Health and Disease, Microbes in Human Welfare, Biotechnology: Principles,
  Biotechnology: Applications):** 500 questions, weighted toward hard and numerical ones, were answered blind;
  499 matched the key (99.8 %). The one mismatch (`bio-biotech2-365`, "gene targeting involves gene
  amplification") rested on a line that could not be confirmed in NCERT, so it was replaced, as was
  `bio-health-254` (a parenting-style claim not found in NCERT). About 2,000 of these 2,500 questions were not
  independently re-solved.
- **Blind review (Organisms and Populations, Ecosystem, Biodiversity and Conservation):** 510 questions, weighted
  toward hard and numerical ones, were answered blind; 507 matched the key (99.4 %). The three that did not
  (`bio-orgpop-258`, `bio-orgpop-377`, `bio-ecosys-117`) were genuinely ambiguous (a loosely worded Gause
  assertion, an individual-vs-population statement, and a trophic-level match where fishes and lions can sit at
  two levels) and were replaced with unambiguous questions.

## Scope notes

- The current rationalised NCERT has dropped several ecology sections (abiotic factors and adaptations, biomes,
  the body text on nutrient cycling). The writers used the earlier edition for those, so a few questions in
  Organisms and Populations and Ecosystem are marked `ncert: false`; NEET still lists these topics.

- Four questions in Neural Control (nerve impulse, saltatory conduction in myelinated fibres) go slightly
  beyond what NCERT states and are marked `ncert: false`.
- Several derived calculations (skin-colour ratios, probabilities, sarcomere models with arbitrary units)
  are marked `ncert: false`; they follow from NCERT principles but are not quoted from the book.
- The current rationalised NCERT dropped some sections the NEET syllabus still lists, so `ncert: true`
  can overstate the match with the current book for a few older-edition facts.
- Writers worked from memory of NCERT without the textbook to hand, and flagged a few lines worth a
  spot-check: thalassemia gene loci (HBA1/HBA2 on chromosome 16, HBB on 11), the "26 vertebrae" count,
  the 8% / 0.4% colour-blindness figures and the 15 x 20 nm prokaryotic ribosome size.
