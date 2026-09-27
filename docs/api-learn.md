# REST API: Learn and practice (v1)

The endpoints behind the Learn tab, practice sessions, bookmarks, reviews and coach tips. They
follow the backend conventions:
- Every request needs `Authorization: Bearer <access token>`.
- Bodies are JSON with unknown fields rejected.
- Errors use the standard envelope `{"error": {"code", "message", "details", "request_id"}}`.
  A 422 carries per-field messages in `details.fields`.
- Lists use cursors: `?cursor=&limit=` → `{"items": [...], "next_cursor": "…" | null}`.
- Times are ISO 8601 UTC strings; durations are integer milliseconds (`*_ms`).
- Question ids (`ref`) are opaque strings.

Content organisation (see `docs/content-format.md`): exam (`goal`) → subject → chapter → topic →
question. Each question has a `difficulty` (1–5), a `category` (`concept`, `numerical`, `factual`,
`application`) and, optionally, the exams it suits.

## Catalog

### `GET /v1/catalog?goal=neet`
Subjects, chapters and topics of one exam (default: the user's goal), with the number of
questions this exam's players can get. It is the same for every user of that exam: served with an
`ETag`, and `If-None-Match` gets `304`.

```json
{
  "goal": "neet",
  "version": "4f1c2a",
  "subjects": [
    {
      "slug": "physics", "name": "Physics", "tone": "sky", "icon": "physics",
      "question_count": 16,
      "chapters": [
        {
          "slug": "kinematics", "name": "Motion in a Straight Line", "order": 1,
          "question_count": 8, "battle_ready": true,
          "topics": [
            {"slug": "speed-velocity", "name": "Speed and velocity", "question_count": 4},
            {"slug": "equations-of-motion", "name": "Equations of motion", "question_count": 4}
          ]
        }
      ]
    }
  ]
}
```

`battle_ready` means the chapter has enough battle questions (at least 7) to be offered for
battles.

### `GET /v1/me/progress?goal=neet`
The user's own progress for the Learn tab. It is small and never cached by the server.

```json
{
  "subjects": [
    {
      "slug": "physics", "answered": 23, "correct": 15,
      "chapters": [
        {"slug": "kinematics", "answered": 12, "correct": 7, "seen": 6, "label": "needs_work"}
      ]
    }
  ],
  "reviews_due": 3,
  "continue": {"session_id": "…", "title": "Physics · Motion in a Straight Line", "answered": 12, "count": 20},
  "tip": {"key": "weak_topic:…", "message": "Focus on Projectile motion. You got 4 of 11 right.", "action": "practice", "params": {"subject": "physics", "topic": "projectile-motion", "count": "10"}}
}
```

- `answered` and `correct` count all answers. `seen` counts distinct questions.
- `label` is a single word for the chapter list, never a chart:
  - `strong`: at least 10 answers and smoothed accuracy ≥ 75%.
  - `needs_work`: at least 5 answers and smoothed accuracy ≤ 50%.
  - `null`: otherwise.
  - Smoothed accuracy is (correct + 2) / (answered + 4).
- `continue` is the latest unfinished practice session, or `null`.
- `tip` is the top coach tip, or `null`.

## Practice sessions

### `POST /v1/practice/sessions`
Needs an `Idempotency-Key` header: a retry with the same key returns the same session.

```json
{
  "mode": "chapter",
  "subject": "physics",
  "chapters": ["kinematics"],
  "topic": null,
  "category": null,
  "count": 10,
  "difficulty": "mixed",
  "timed": false,
  "per_question_s": null,
  "time_limit_s": null,
  "marking": "none",
  "unseen_only": false
}
```

**Fields by mode**

| `mode` | Uses | Feedback |
|---|---|---|
| `chapter` | `subject` and `chapters` (one or more; empty = the whole subject) | After each question |
| `topic` | `subject` and `topic` | After each question |
| `category` | `subject` and `category` (e.g. only numericals) | After each question |
| `review` | `subject` optional; serves questions due for review | After each question |
| `bookmarks` | `subject` optional; serves bookmarked questions | After each question |
| `challenge` | `subject`, `chapters`, `time_limit_s` and `marking` | At the end |
| `passage` | `passage_id` (Fun & Learn); the response also has `passage` | After each question |

**Common settings**

| Field | Values |
|---|---|
| `count` | 5–50. The app offers 10/20/30, plus 50 for challenge |
| `difficulty` | `mixed`, `easy` (1–2), `medium` (3) or `hard` (4–5) |
| `timed` | Adds a per-question limit, `per_question_s`: 20, 30, 45 or 60. The app uses it for "Try a timed practice set" tips |
| `time_limit_s` | Challenge only: 300, 600, 900, 1800 or 3600 |
| `marking` | `none`, or `neet` (+4 / −1 for challenge) |
| `unseen_only` | Only questions the user has never answered |

**Question selection**
- It uses only questions suited to the user's exam, never ones reserved for battles.
- Unseen questions come first, then those seen longest ago.
- If fewer questions match than requested, the session is shorter and `"short": true`. If none
  match, the response is `409 NO_QUESTIONS`.
- Users can create at most 30 sessions an hour (`429`).

**Response `201`**

```json
{
  "session_id": "…",
  "mode": "chapter",
  "title": "Physics · Motion in a Straight Line",
  "feedback": "instant",
  "created_at": "2026-09-27T15:00:00Z",
  "expires_at": "2026-09-28T15:00:00Z",
  "per_question_ms": null,
  "time_limit_ms": null,
  "marking": "none",
  "short": false,
  "questions": [
    {
      "ref": "q_01929f…",
      "position": 1,
      "stem": "A car starts from rest and accelerates uniformly at 2 m s^{-2}. How far does it travel in 5 s?",
      "options": [{"id": 2, "text": "50 m"}, {"id": 0, "text": "10 m"}, {"id": 3, "text": "100 m"}, {"id": 1, "text": "25 m"}],
      "answer": 1,
      "explanation": "Starting from rest (u = 0), s = ut + ½at^2 = ½ × 2 × 5^2 = 25 m.",
      "difficulty": 2,
      "category": "numerical",
      "chapter": {"slug": "kinematics", "name": "Motion in a Straight Line"},
      "topic": {"slug": "equations-of-motion", "name": "Equations of motion"},
      "bookmarked": false
    }
  ]
}
```

- Options come in shuffled display order. Each option's `id` is its position as authored, and
  `answer` is the `id` of the correct option. Practice answers are shipped with the questions so
  feedback is instant and sessions work offline. Battles never do this (see `docs/protocol.md`).
- Text fields use the quiz markup (`^{}`, `_{}`, `*italic*`, `**bold**`).
- Sessions expire 24 h after creation. A challenge also ends at `created_at + time_limit` (plus
  60 s of grace).

### `GET /v1/practice/sessions/{id}`
Returns the same body as creation, plus `"answers": [{"position", "selected_option", "outcome",
"time_ms"}]` and `"finished": false`. The app uses it to resume a session ("Continue practice").
Finished sessions stay readable, with their answers for review, for 90 days.

### `GET /v1/me/practice/sessions?cursor=`
Practice history, newest first (Profile → History → Practice):
`{"items": [{"session_id", "mode", "title", "created_at", "finished_at", "answered", "correct",
"score", "max_score"}], "next_cursor"}`.

A worker finishes expired unfinished sessions with a partial summary, so they leave "Continue
practice" and appear here. `continue` in progress never points at an expired session.

### `POST /v1/practice/sessions/{id}/answers`
Uploads answers, one at a time or in batches of up to 50. The app queues them while offline, so
this is idempotent.

```json
{
  "answers": [
    {
      "client_answer_id": "6b0e…",
      "ref": "q_01929f…",
      "position": 1,
      "selected_option": 1,
      "skipped": false,
      "timed_out": false,
      "time_ms": 5320,
      "answer_changes": 0,
      "answered_at": "2026-09-27T15:00:07.412Z"
    }
  ]
}
```

- `selected_option` is an option `id`, or `null` when skipped or timed out. The server works out
  correctness itself; the client never says whether an answer was right.
- `time_ms` is measured by the app from when the question appeared to the tap. The server caps it
  at 10 minutes, or at the per-question limit.
- `answer_changes` counts how often the pick changed before submitting (challenge).
- `answered_at` is clamped into the session's lifetime.
- **Late uploads.** Answers are judged by their clamped `answered_at`, not by upload time. An answer
  given while the session was alive is accepted for up to 7 days after the session expired, so a
  phone that was offline for a while loses nothing. `session_expired` means the answer itself came
  after expiry.
- **De-duplication.** Answers are de-duplicated by `client_answer_id`, and only the first answer
  per `position` counts.

**Response `200`**

```json
{
  "results": [{"client_answer_id": "6b0e…", "status": "accepted", "outcome": "correct"}],
  "xp": {"delta": 2, "total": 1234, "level": 4, "into_level": 34, "for_next": 250, "capped": false, "resets_at": null}
}
```

- `status` is one of:
  - `accepted`;
  - `duplicate`, which is safe to drop from the queue;
  - `rejected`, with `reason`: `unknown_question`, `position_mismatch`, `session_expired` or
    `time_up`. Also drop it.
- `outcome` is `correct`, `wrong`, `skipped` or `timeout`.
- **What each accepted answer does.**
  - It is recorded with its subject, chapter, topic, category, difficulty, time, and a speed
    label against the question's typical time (once there is enough data).
  - It updates the running totals.
  - It moves wrong answers into review.
  - It awards practice XP: 2 for a correct answer, 1 otherwise, up to 300 XP a day.

### `POST /v1/practice/sessions/{id}/finish`
Idempotent. It ends the session; answers not yet uploaded should be sent first.

```json
{
  "session_id": "…",
  "answered": 18, "correct": 12, "skipped": 2,
  "time_ms": 312000,
  "score": 44, "max_score": 80,
  "topics": [{"slug": "equations-of-motion", "name": "Equations of motion", "answered": 9, "correct": 5}],
  "xp": {"delta": 30, "total": 1264, "level": 4, "into_level": 64, "for_next": 250},
  "tip": {"key": "…", "message": "You're often slower than your opponents in Kinematics. Try a timed practice set.", "action": "timed_practice", "params": {"subject": "physics", "chapter": "kinematics"}}
}
```

`score` and `max_score` are only set with `marking: neet` (+4 / −1). `topics` is a short list for
the result screen, not a chart. `tip` is the one coach tip most relevant to this session.

## Coach tips

### `GET /v1/me/tips`

```json
{
  "unlocked": true,
  "answers_needed": 0,
  "tips": [
    {"key": "weak_topic:…", "rule": "weak_topic", "message": "Focus on Projectile motion. You got 4 of 11 right.", "action": "practice", "params": {"subject": "physics", "topic": "projectile-motion", "count": "10"}}
  ]
}
```

- **Before unlocking.** Before 20 answers, `unlocked` is false, `tips` is empty and
  `answers_needed` says how many more.
- **Up to 5 tips**, in the order the plan describes.
- **What each `action` opens in the app:**

| `action` | Opens |
|---|---|
| `practice` | A practice session for `params.topic` or `params.chapter` |
| `timed_practice` | A timed session (`per_question_s: 30`) for that topic or chapter |
| `practice_category` | Category mode for `params.subject` and `params.category` |
| `review` | Review mode |
| `start_chapter` | Chapter practice with `difficulty: easy` |
| `practice_medium` | Chapter practice with `difficulty: medium` |
| `battle` | The Battle tab with `params.subject` (and `params.chapter`) preselected |

### `POST /v1/me/tips/{key}/dismiss`
`204`. Hides that tip for 7 days. A tip whose action the user starts is hidden for 24 h
automatically.

## Bookmarks and reviews

| Endpoint | Result |
|---|---|
| `PUT /v1/me/bookmarks/{ref}` | `204`. Idempotent. `409 BOOKMARK_LIMIT` at 5,000 |
| `DELETE /v1/me/bookmarks/{ref}` | `204`. Idempotent |
| `GET /v1/me/bookmarks?subject=&cursor=&limit=` | `{"items": [{"ref", "stem", "subject", "chapter", "topic", "bookmarked_at"}], "next_cursor"}` |
| `GET /v1/me/reviews/summary` | `{"due": 5, "total": 23}` |

**Reviews** (Leitner boxes):
- Any wrong answer, in practice or in a battle, puts the question in box 1.
- Boxes come due after 1, 3, 7, 14 and 30 days.
- A correct review moves the question up a box, and a wrong one sends it back to box 1.
- A correct answer from box 5 retires the question.

**Daily caps are always explained.** When the 300-a-day practice XP cap cuts an award,
`xp.capped` is true and `resets_at` is the next IST midnight. The app then shows "Daily practice
XP limit reached · resets at midnight" instead of a puzzling small number.

## Reporting a question

`POST /v1/questions/{ref}/reports {"reason": "wrong_answer" | "typo" | "unclear" | "other",
"note": "…"}` → `202`.
- It's available from practice, review and search.
- Limited to 20 a day. A repeat report of the same question by the same user is accepted again
  without creating a duplicate.
- When a moderator resolves it, the reporter gets a `question_report` inbox item.
- **A battle question found to be wrong:** ratings from past games stand, and the question is
  retired, so it leaves reviews and bookmarks.

## Search and single questions

| Endpoint | Result |
|---|---|
| `GET /v1/search?q=kine&subject=physics&limit=20` | `q` needs 2+ characters. `{"items": [{"ref", "stem", "subject", "chapter", "topic"}]}`. Limited to 30 searches a minute |
| `GET /v1/questions/{ref}` | One question with answer, explanation and `bookmarked`, as in a practice session |

## Fun & Learn passages

| Endpoint | Result |
|---|---|
| `GET /v1/passages?subject=physics` | `{"items": [{"id", "title", "subject", "chapter", "difficulty", "question_count", "done"}]}` |
| `POST /v1/practice/sessions` with `{"mode": "passage", "passage_id": "…"}` | A session whose body also has `"passage": {"id", "title", "body"}` |

Guess the Word arrives with the coin economy (its hints cost coins) and gets its own endpoints then.
