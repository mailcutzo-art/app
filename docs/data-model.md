# Data model: content, answers and progress

PostgreSQL tables for questions and everything recorded when someone answers one. Identity,
matches, tournaments, coins and social tables are summarised in `docs/plan.md` ("Data model
outline").

Conventions:
- Primary keys are UUIDv7 unless noted. Small lookup tables use integer ids.
- Timestamps are `timestamptz`.
- Enumerations are `text` with a `CHECK` constraint, which is easier to extend than Postgres
  enums.

## Content

```
goals ──< goal_subjects >── subjects ──< chapters ──< topics
                                 │           │          │
                                 └──────── questions ───┘   (every question: subject, chapter, topic)
                                             │
                               passages ─────┘ (passage questions)        word_puzzles
```

### `goals`, `subjects`, `goal_subjects`
- `goals` holds the exams: `id smallint`, `slug` (`neet`, `jee`) and `name`.
- `subjects`: `id smallint`, `slug`, `name`, `tone` (the pastel colour), `icon` and `sort`.
- `goal_subjects (goal_id, subject_id)` is many-to-many: Physics and Chemistry belong to both
  exams.

### `chapters`, `topics`
- `chapters`: `id int`, `subject_id`, `slug` (unique per subject), `name`, `sort` and `is_active`.
- `topics`: `id int`, `chapter_id`, `slug` (unique per chapter), `name` and `sort`. A topic is the
  smallest unit a student revises on its own, and the unit tips talk about ("Focus on Projectile
  motion").

### `questions`

| Column | Type | Meaning |
|---|---|---|
| `id` | uuid | |
| `external_id` | text | Stable id from content files or imports, e.g. `phy-kin-001`. Unique among non-retired rows |
| `subject_id` | smallint | Subject |
| `chapter_id` | int | Chapter. Only a passage question may have none |
| `topic_id` | int, null | Topic. Required except for passage questions |
| `passage_id` | uuid, null | Set for Fun & Learn passage questions |
| `kind` | text | `mcq_single` or `passage_mcq` |
| `category` | text | `concept`, `numerical`, `factual` or `application` |
| `exams` | text[], null | Exams it suits. `null` = every exam that includes the subject |
| `difficulty` | smallint | 1 (easy) … 5 (hard) |
| `battle_pool` | text | `none` (practice only), `shared` (practice and battles) or `reserved` (battles only, never sent to practice) |
| `status` | text | `draft`, `review`, `published` or `retired` |
| `stem` | text | Question text in quiz markup |
| `options` | text[4] | The four options in authored order. `CHECK (cardinality(options) = 4)` |
| `answer` | smallint | Index of the correct option, 0–3. With `options`, this guarantees exactly one correct answer |
| `explanation` | text | Shown after answering |
| `tags` | text[] | Free-form labels for search |
| `search_text` | text | Stem and options with markup stripped, for search (trigram and full-text indexes) |
| `content_hash` | text | SHA-256 of stem, options and answer, so imports are idempotent |
| `supersedes_id` | uuid, null | Published questions are never edited. A correction creates a new row pointing at the old one, and the old row is retired, so past answers still point at exactly what was asked |
| `seq` | int | Dense number per subject. `UNIQUE (subject_id, seq)` |
| `created_at`, `updated_at` | timestamptz | |

Indexes:
- partial indexes on `(chapter_id, difficulty)` and `(topic_id)` for published questions;
- a partial index on published battle questions (`battle_pool <> 'none'`);
- GIN trigram and `simple` full-text indexes on `search_text`.

### `question_stats`
One row per question, rebuilt nightly from the answers, so there are no hot counters on popular
questions.

| Column | Meaning |
|---|---|
| `attempts`, `correct` | All-time totals |
| `typical_ms` | Median time of correct answers over the last 90 days (null until 20 timed correct answers) |
| `timed_correct` | How many timed correct answers `typical_ms` is based on |
| `p_correct` | Share answered correctly; used to calibrate difficulty |

### `passages`, `word_puzzles`
- `passages`: `id`, `external_id`, `subject_id`, `chapter_id` (optional), `title`, `body`,
  `difficulty` and `status`. Their questions live in `questions` with `kind = passage_mcq`.
- `word_puzzles`: `id`, `external_id`, `subject_id`, `word` (`^[A-Z]{3,12}$`), `clue`,
  `difficulty` and `status`.

### `question_reports`
A player's report on a question (`reason`: wrong_answer, typo, unclear or other; optional
`note`), at most one open per player and question. The admin review queue closes reports:
`status` becomes `resolved` (outcome `fixed` or `retired`) or `dismissed` (outcome `rejected`),
with `resolution`, `resolution_note` (internal), `resolved_by` and `resolved_at`; open reports
have none of these (a CHECK enforces it). A partial index on `created_at` of open reports serves
the queue.

Test content is loaded from `content/` by the seed command, which runs the same checks as
`content/tools/validate.py`. The seed upserts by `external_id`, and a changed question becomes a
new row that supersedes the old one. Imported questions (`source = import`, see
`content-format.md`) and admin edits follow the same rule: a published question is never changed;
an edit adds a new version with the next `seq` and retires the old row.

## Answers

### `question_attempts`: one row per answer, in every mode
Partitioned by month on `answered_at`. A default partition catches anything outside the created
ranges, and the worker creates the next months' partitions ahead of time.

| Column | Type | Meaning |
|---|---|---|
| `id` | uuid | |
| `user_id` | uuid | Who answered |
| `question_id` | uuid | Which question (the exact version asked) |
| `subject_id`, `chapter_id`, `topic_id` | | Copied from the question at answer time, so grouping needs no joins and history stays stable if content is reorganised |
| `category`, `difficulty` | | Copied from the question too |
| `mode` | text | Practice: `chapter`, `topic`, `category`, `challenge`, `review`, `bookmarks` or `fun_learn`. Live: `quick_rated`, `quick_casual`, `bot`, `friend`, `group` or `tournament` |
| `session_id` | uuid | The practice session or the match |
| `position` | smallint | The question number within it |
| `selected_option` | smallint, null | The option picked, as its authored index (never the shuffled screen position); null if none |
| `outcome` | text | `correct`, `wrong`, `skipped` or `timeout` |
| `time_ms` | int | Time from the question appearing to the answer. Live games use the server's latency-adjusted time; practice uses the app's measurement, capped at 10 minutes. A timeout records the full limit |
| `time_limit_ms` | int, null | The limit, or null for untimed practice |
| `speed` | text, null | `fast`, `slow` or `even` (below) |
| `speed_basis` | text, null | `opponents` (multiplayer) or `typical` (solo, against the question's typical time) |
| `peer_time_ms` | int, null | What it was compared with: the opponent's time, the group's median, or the typical time |
| `answer_changes` | smallint | How often the pick changed before submitting (challenge) |
| `first_try` | bool | The user's first attempt at this question |
| `points` | smallint, null | Battle points |
| `answered_at` | timestamptz | When |
| `ist_day` | date | The day in India time, for streaks and missions |

Indexes: `(user_id, answered_at desc)` for tips, and `(question_id, answered_at)` for the nightly
stats.

**De-duplication.** Retries and offline uploads must never count twice. A unique key can't span
partitions, so two small tables do it:
- `attempt_keys (user_id, client_answer_id)` is the primary key the app's answer id is claimed in.
- `practice_answers (session_id, position)` records the first answer per question of a practice
  session. The resume endpoint reads it too.
- Match answers are unique per `(match_id, user_id, question)` in `match_answers`.

**How `speed` is decided**
- **Multiplayer games** (basis `opponents`): the player's time is compared with the other human
  players who were connected when the question opened: the opponent in a 1v1, or the median time
  of those who answered in a group.
  - More than 250 ms sooner is `fast`, more than 250 ms later is `slow`, and closer than that is
    `even`. 250 ms is inside network jitter, so it isn't counted either way.
  - Answering when nobody else did is `fast`, and timing out while someone answered is `slow`.
  - Bot opponents, disconnected players and late joiners don't count; with nobody to compare,
    `speed` is null.
- **Solo practice** (basis `typical`): compared with the question's `typical_ms` once it has 20
  timed correct answers. Under 0.75× is `fast`, over 1.25× is `slow`, and in between is `even`.
- **Correctness is stored separately.** So tips can tell "slow but right" (knows it, needs speed)
  from "fast but wrong" (rushing).

### `practice_sessions`
- **Columns:**
  - `id`, `user_id`, `mode`, `subject_id` and `title`;
  - `settings` (jsonb, the validated request);
  - `question_ids` (uuid[] in order), and `option_orders` (the shuffled display order per question,
    so a resumed session looks the same);
  - `created_at`, `expires_at` and `finished_at`.
- **Index:** `(user_id, created_at desc) WHERE finished_at IS NULL` finds "Continue practice".

## Per-user progress

### `user_questions`: one row per user and question they have met
It answers "have I seen this?", "is it due for review?" and "is it bookmarked?" in one place.

| Column | Meaning |
|---|---|
| `user_id`, `question_id` | Primary key |
| `first_at`, `last_at` | First and latest attempt |
| `attempts`, `correct` | Counts for this question |
| `last_outcome` | Outcome of the latest attempt |
| `review_box`, `review_due_at` | Leitner review. A wrong answer puts the question in box 1. Boxes come due after 1, 3, 7, 14 and 30 days; a correct review moves it up a box and a wrong one back to box 1. Graduating from box 5 clears both columns |
| `bookmarked_at` | Set while bookmarked (at most 5,000 per user) |

Partial indexes: `(user_id, review_due_at) WHERE review_box IS NOT NULL` and
`(user_id, bookmarked_at desc) WHERE bookmarked_at IS NOT NULL`.

### Running totals
These are updated in the same transaction as the answers, only for answers that were actually
inserted (never for duplicates).

| Table | Key | Used for |
|---|---|---|
| `user_topic_stats` | user, topic | Weak topics, fast-but-wrong, strengths |
| `user_chapter_stats` | user, chapter | Strong / Needs work labels, speed vs opponents per chapter, "try medium questions" |
| `user_category_stats` | user, subject, category | "Practise more Physics numericals" |
| `user_daily_stats` | user, IST day, subject | Streaks, missions, this-week comparisons |

The first three share these columns:
- `attempts`, `correct`, `time_ms`, `correct_time_ms` and `last_at`;
- `fast`, `slow` and `even` against opponents;
- `typical_compared`, `typical_log_ratio_sum` (so the average of log(time ÷ typical) gives how much
  slower or faster than other students), and `fast_wrong`;
- `easy_attempts` and `easy_correct` (difficulty 1–2).

`user_chapter_stats` also keeps `seen`, the number of distinct questions answered.

### `user_tips`
`(user_id, tip_key)`, with `hidden_until` and `reason` (`acted` for 24 h, `dismissed` for 7 days).
Tips themselves are computed on request from the running totals and the last 30 days of answers
(cached for 10 minutes), so the rules can change without migrating data.
