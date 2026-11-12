# Biology status

The plan for all 34 NEET chapters is in `content/tools/biology_plan.yaml` (500 questions each).
**21 chapters are complete (10,500 questions)**, promoted into `content/questions/biology/` and validated.
The other 13 are empty skeletons in `content/wip/biology/`, which the validator and seed export do not
read. `bio_setup.py promote <chapter>` moves a chapter into the validated bank once every topic reaches its
planned count; `bio_setup.py status` shows progress.

## Complete

The Living World, Biological Classification, Plant Kingdom, Animal Kingdom, Morphology of Flowering Plants,
Anatomy of Flowering Plants, Structural Organisation in Animals, **Cell: The Unit of Life**, Biomolecules,
Cell Cycle and Cell Division, Transport in Plants, Mineral Nutrition, Photosynthesis in Higher Plants,
Respiration in Plants, Plant Growth and Development, Breathing and Exchange of Gases, Body Fluids and
Circulation, Excretory Products and their Elimination, **Locomotion and Movement**, **Neural Control and
Coordination**, **Principles of Inheritance and Variation**.

## Still to write (empty skeletons in `wip/biology/`)

Chemical Coordination, Sexual Reproduction in Flowering Plants, Human Reproduction, Reproductive Health,
Molecular Basis of Inheritance, Evolution, Human Health and Disease, Microbes in Human Welfare,
Biotechnology: Principles, Biotechnology: Applications, Organisms and Populations, Ecosystem,
Biodiversity and Conservation.

## Checks run on Cell, Inheritance, Locomotion and Neural Control (added together)

- `validate.py` passes; every batch went through `bank.py` (schema, duplicate and near-duplicate checks).
- Mix per chapter: difficulty 8 / 12 / 45 / 25 / 10 % for levels 1-5, answer positions within one point of 25 %
  each, about 38 % battle questions, 84-90 % marked as resting directly on NCERT, 31-33 % statement-type
  questions, 10-11 % diagram and graph questions.
- **Blind review:** 520 of the new questions (weighted toward hard and numerical ones) were answered by
  independent reviewers who saw only the stems and options. 518 matched the key (99.6 %). One
  assertion-reason item (`bio-gen-456`) was ambiguous and was rewritten; the other disagreement
  (`bio-neural-255`) is NCERT's own wording and was left alone. The remaining ~1,100 new questions were
  not independently re-solved.

## Scope notes

- Four questions in Neural Control (nerve impulse, saltatory conduction in myelinated fibres) go slightly
  beyond what NCERT states and are marked `ncert: false`.
- Several derived calculations (skin-colour ratios, probabilities, sarcomere models with arbitrary units)
  are marked `ncert: false`; they follow from NCERT principles but are not quoted from the book.
- The current rationalised NCERT dropped some sections the NEET syllabus still lists, so `ncert: true`
  can overstate the match with the current book for a few older-edition facts.
- Writers worked from memory of NCERT without the textbook to hand, and flagged a few lines worth a
  spot-check: thalassemia gene loci (HBA1/HBA2 on chromosome 16, HBB on 11), the "26 vertebrae" count,
  the 8% / 0.4% colour-blindness figures and the 15 x 20 nm prokaryotic ribosome size.
