# Biology status (first five chapters)

Scope was limited to five Biology chapters for now: The Living World, Biological Classification, Plant
Kingdom, Animal Kingdom and Morphology of Flowering Plants (500 questions each, 2,500 in all). The full
plan for all 34 NEET chapters is in `content/tools/biology_plan.yaml`; only these five are marked active.

**1,858 of 2,500 questions are written. One chapter is complete.**

| Chapter | Written | Status |
|---|---|---|
| The Living World | 500 / 500 | **Complete**, promoted into `content/questions/biology/` and validated |
| Animal Kingdom | 439 / 500 | Missing *classification basis* (61) |
| Morphology of Flowering Plants | 410 / 500 | Missing *flower* (90) |
| Biological Classification | 290 / 500 | Missing *protista* (70), *fungi* (90), *kingdom comparisons* (50) |
| Plant Kingdom | 219 / 500 | Missing *algae* (90), *bryophytes* (70), *gymnosperms* (70), *plant-group comparisons* (51) |

The other four chapters sit in `content/wip/biology/`, which the validator and seed export do not read.
`bio_setup.py promote <chapter>` moves a chapter into the validated bank once every topic reaches its
planned count.

## Blocked topics

Nine topics could not be written. Every attempt ended with the API error "Output blocked by content
filtering policy" on the writer's first response, before any file was written: 3–4 attempts on Sonnet 5.5
for each, then one attempt each on Opus 5.5. The content is ordinary NCERT biology and the same
instructions worked for 29 other topics. The block is not specific to one model and not deterministic per
topic (two topics that failed three times succeeded on the fourth try). Nothing was reworded to get around
it. To finish these topics, retry them later or write them by hand.

## Scope notes

- The current rationalised NCERT dropped some sections that the NEET syllabus still lists. Writers used
  the earlier text for these, so the `ncert: true` flag overstates the match with the current book there:
  root, stem and leaf modifications, the descriptions of the Fabaceae and Liliaceae families, and the
  "What is living?" section.
- 11 plant life-cycle questions were dropped because they relied on examples (*Fucus*, *Ectocarpus*,
  *Polysiphonia*, kelps) found only in the older text.
- Where NCERT simplifies, questions follow NCERT (for example "only humans are self-conscious", "no virus
  contains both RNA and DNA") and say "as per NCERT" in the stem.

## Checks run

- `validate.py` passes with The Living World in the validated bank. It requires stems to be unique across
  subjects, which caught two generic stems; `bank.py` now checks every subject.
- Every batch passed the writers' schema, duplicate and near-duplicate dry run and was merged through
  `bank.py`.
- **No independent re-solve of Biology answers was done** (the review was dropped at the author's request).
  Biology correctness rests on the writers' own NCERT checks and my scope review of each batch.

## Mix of what is written

Difficulty 8% / 12% / 45% / 25% / 10% for levels 1–5, answers A–D within one point of 25% each, statement-type
questions 32–33%, diagrams and graphs 10%, 85–88% marked as resting directly on NCERT.
