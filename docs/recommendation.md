# Recommended practice

A chapter holds about 500 questions, more than a student can work through, and with no guidance
a student can't tell which 50 matter most. Recommended practice solves this in two layers:

1. **The content layer (static, at seed time).** Each topic's questions are ranked once:
   an importance score, a **tier** (core, standard, extra) and a study order. The **core set**
   is about 20% of every topic (~100 of a 500-question chapter) and covers every idea
   (subtopic or tag cluster) with 3 or more questions. That gives the student a goal they can
   reach: "Core: 100 questions".
2. **The student layer (per session).** Each new chapter, topic or Self Challenge session spreads
   its questions over the topics in scope. It serves the core questions the student hasn't done
   yet, at their level, brings back mistakes that are due for review, and rotates topics so no
   topic is neglected.

Code: `backend/app/modules/content/priority.py` (content layer, run by the seed) and
`backend/app/modules/practice/recommend.py` (student layer, called from `selection.py`). Both are
pure functions with unit tests (`backend/tests/unit/test_priority.py`, `test_recommend.py`).

## 1. Content layer: ranking a topic

Inputs come from the chapter files (see `content-format.md`): `subtopic`, `tags`,
`difficulty`, `category`, `format`, `ncert` and `diagram`.

### Clusters: what "covering a topic" means

Ranking works on clusters of questions that test the same idea. That is the `subtopic`, unless
a topic has more than half as many distinct subtopics as questions. In 42 of the 84 full
chapters (most of Physics, about half of Chemistry) the subtopic describes the single question
("Average speed over equal distances and equal times") instead of grouping questions. In those
topics the cluster is the question's first tag that names an idea (`average-speed`,
`manipulating-k`), skipping labels such as `trap`, `graph`, `match`, `ncert-line` or
`multi-concept`. This turns 23,980 near-unique subtopics into 11,872 clusters.

### Importance (0–100)

| Signal | Points | Why |
|---|---|---|
| Base | 20 | |
| `ncert: true` / unknown / `false`, for concept and factual questions | 20 / 10 / 0 | NEET is set from NCERT text |
| Numericals and applications, whatever their `ncert` | 10 | Their flag says whether the situation is in the book, not whether the skill is in the syllabus (only 36% of Physics numericals are flagged) |
| Difficulty 1 / 2 / 3 / 4 / 5 | 6 / 12 / 16 / 12 / 4 | Medium is where most exam questions sit |
| Exam-pattern format (assertion-reason, statement pair, multi-statement, statements, match) | 8 (others 5) | Students must be fluent in the exam's formats |
| Cluster yield: `24 × ln(1 + size) / ln(1 + largest cluster)` | 0–24 | Authors wrote the most questions on what the exam keeps asking |
| Needs a figure the app can't draw yet | −10 | Practice-only and harder to read without art |

### Study order and tiers

The topic's questions are put in order one pick at a time:

1. **Whose turn.** Every cluster gets its first question before any gets a second (largest
   clusters first). After that the Sainte-Laguë rule on `sqrt(cluster size)` decides: a
   cluster with 25 questions gets more turns than one with 4, but not six times as many.
2. **Which question.** In that cluster, the highest importance, minus a penalty for repeating
   the category (6), difficulty band (4) or format (3) of a question already picked there,
   plus 12 points per question its category, and again its difficulty band, would still be
   behind its share of the topic. So any prefix of the order keeps the topic's own mix of
   difficulty and question types.
3. **Tiers.** The first `max(3, round(20% × topic size))` questions are **core** (tier 1), the
   next as many **standard** (tier 2), the rest **extra** (tier 3).

The ranking is deterministic (ties go to the smaller question id), so re-running the seed gives
the same result. The seed stores `importance`, `tier`, `topic_rank` and `cluster` on every
question.
Imported questions and passage questions aren't ranked (importance 50, tier 3, no rank).

### What it produces on the current bank (42,000 questions)

| | |
|---|---|
| Core per 500-question chapter | 97–102 (median 100) |
| Core per topic | 3–28 (median 10) |
| Clusters with ≥ 3 questions that have a core question | 100% (4,687 of 4,687) |
| All clusters with a core question | 63% (the rest are mostly single questions) |
| Difficulty, bank → core | Physics easy/medium/hard 26/51/23% → 26/52/22%; Chemistry 27/50/23 → 27/53/20; Biology 22/46/31 → 22/48/30 |
| Category, bank → core | Physics numerical 42% → 36%, concept 37 → 39; Chemistry numerical 20 → 16, factual 19 → 23; Biology concept 51 → 56, application 19 → 15 |
| Core questions on NCERT text | 79% |

Numericals and applications are a little behind their share in the core set because concept
and fact clusters are more numerous than numerical ones, and covering every cluster comes first.
Raising `MIX_POINTS` barely changes this; giving numericals their own cluster turns would.

## 2. Student layer: building a session

`POST /v1/practice/sessions` with mode `chapter`, `topic` or `challenge` uses it by default
(`"selection": "recommended"`). `"selection": "unseen_first"` keeps the old random draw.

1. **Reviews.** Mistakes due for review (Leitner boxes, see `data-model.md`) in scope take up to
   `max(1, round(20% × count))` slots.
2. **Split the rest across topics.** Each topic in scope gets a weight
   `sqrt(questions available) × need`, where

   ```
   need = 0.3
        + 0.9 × (core questions not yet answered correctly ÷ core questions)
        + 0.6 × (1 − smoothed accuracy in the topic)      smoothed = (correct + 2) / (answers + 4)
        + 0.3 × min(1, days since last practised ÷ 7)    1 if never practised
   need × 0.5 when the topic has no unseen questions left
   ```

   - If there are at least as many slots as topics, every topic gets one and the rest go by the
     Sainte-Laguë rule on the weights (never more than a topic has).
   - Otherwise a weighted random draw without replacement picks which topics this session
     visits. Needy topics come up more often, and every topic still comes round.
3. **Pick within each topic.** Unseen questions are scored:

   ```
   score = tier points (core 2, standard 1, extra 0)
         + 0.5 × importance / 100
         + 0.6 × difficulty fit           1 − |difficulty − target| / 4
         + 0.3 if the student hasn't met this cluster (idea) yet
         − 0.8 × picks of this cluster already in the session
         + random jitter up to 0.15       so two sessions differ
   target difficulty = 1 + 4 × clamp((smoothed accuracy − 0.3) / 0.6, 0, 1)
   ```

   A newcomer starts around 2.3 (easy to medium), 75% accuracy aims at 4, 90% at 5. Core
   questions come first, at the student's level, with ideas varied. A topic with nothing
   unseen left serves refreshers: those answered wrong last time, then the longest ago.
4. **Order.** New questions go easy to hard with the topics interleaved, then the reviews, then
   the refreshers.

Filters still apply first: `difficulty` (easy/medium/hard), `unseen_only` (which also skips
reviews), the player's exam and the practice pool.

### What the student sees

- The catalog gives `core_count` per chapter and topic, and `/v1/me/progress` gives `core_done`
  per chapter (core questions answered correctly at least once). The app can show
  "Core 34 / 100" instead of "500 questions".
- "Practice this chapter" with 10 questions: about one core question per topic, at the right
  difficulty, mistakes back when due. After about 10 sessions the core set is done and the
  sessions move on to standard, then extra questions, the weakest and longest-unseen topics
  first.
- "Practice this topic": the topic's core questions first, one per idea before any repeats.

## Tuning and next steps

The constants are named at the top of both modules. Tune them by measuring:

- **Calibrate difficulty from answers.** `question_stats.p_correct` (rebuilt nightly) can
  replace authored difficulty once a question has enough answers.
- **Discrimination.** Questions that strong students get right and weak students get wrong
  are the best for learning; a nightly job could add that to importance.
- **Better subtopics.** Where subtopics are unique per question, tags stand in. Giving those
  chapters 5–15 real subtopics per topic would make clusters, coverage and "subtopic not met"
  sharper.
- **Past-paper flags.** If questions get a `pyq` field (years the idea appeared in NEET), it
  should become the strongest importance signal.
- **Measure.** Compare accuracy on core questions in later sessions, and chapter completion,
  between `recommended` and `unseen_first` sessions.
