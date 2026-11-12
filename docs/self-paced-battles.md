# Self-paced battles (design, not built yet)

Today every battle is **live and in lockstep** (`docs/realtime-engine.md`): both players see each
question at the same moment, a round ends when everyone has answered or its time runs out, and
both finish together. Rounds are now timed by difficulty (easy 20 s, medium 30 s, hard 45 s), and
a player who answers first sees "Locked in · waiting for Riya" while the round stays open.

This document describes a second way to play, where **each player moves at their own pace**: the
first player to finish can leave, the app waits for the other one (up to a long deadline), and the
result is decided when both are done. It is a design to agree on before building; nothing below
exists in the code yet.

## Why

- Hard questions need time to work out. In lockstep, a 45 s round makes the faster player wait.
- Students revise in short gaps. A game you can finish and leave fits that better than one that
  needs both players on screen for four minutes.
- It also makes "challenge a friend" possible when the friend isn't online right now.

## The experience

1. **Find a game** as today (same queue, same rating rules). The VS screen says *Play at your own
   pace · 7 questions*.
2. **Questions** come one after another *for you*. Each one still has its time by difficulty; when
   it runs out you lose that question and the next appears (as in timed practice). The opponent's
   progress shows as a small bar ("Riya · question 4 of 7"), never their answers.
3. **You finish first:** "You're done! Riya is on question 5." You can wait or leave. Leaving is
   safe: the game goes on without you, and you are told the result later (an inbox item and a
   push notification).
4. **Both done**, or the **deadline** passes (a long one, e.g. 24 h for friends, 10 min for Quick
   Battle): the result screen and settlement work as today. Questions the late player never
   reached count as timeouts.

## Rules

| Topic | Rule |
|---|---|
| Who | Quick Battle (as a choice, "Live" or "Own pace"), Play with Friend and, later, async friend challenges. Not tournaments (rounds need a fixed end) |
| Timing | Each question: easy 20 s, medium 30 s, hard 45 s from when *that player* sees it. Server clock |
| Answer time | `el_ms` per answer, exactly as today, so analytics and speed labels keep working |
| Speed labels | Compare each player's time on the same question, after both answered it |
| Scoring | Same points table; the result is decided on totals, as today |
| Deadline | Per mode: Quick Battle 10 min after the first question opens, friends 24 h |
| Leaving | Not a forfeit once you've answered everything. Leaving midway: the remaining questions run out on their own (no extra penalty, but they score 0) |
| Disconnects | No forfeit timer: a question's clock simply keeps running while you're away |
| Rating | Same Glicko-2 update at settlement, so own-pace and live games share one rating |

## Engine changes

The lockstep engine keeps one `q`, `shown_at` and `deadline_at` per match. Own-pace games need
them **per player**:

- `m:{mid}` gains `pace = own` and `ends_at` (the overall deadline).
- `m:{mid}:p` (per player) gains `q`, `shown_at`, `deadline_at` and `done`.
- **`next.lua`** (new): opens the player's next question (sets their `q`, `shown_at` and
  `deadline_at`, and schedules the timer), or marks them `done` after the last one. Called when a
  player answers, or when their question's deadline passes.
- **`answer.lua`** checks the *player's* `q` and deadline instead of the match's, and reveals to
  that player only (`q.reveal` becomes a per-player message, like `ans.ack`).
- **`advance.lua`** for own-pace games: on a player's question deadline, record a timeout and call
  `next`; when every player is `done`, or `ends_at` passes, move to `finished`.
- **Events:** `q.show` and `q.reveal` go to one player (not the shared log, so nothing leaks).
  A new shared `pace.progress {uid, q, done}` lets each side show the other's progress.
- **Timers:** `rt:timers` holds the earliest of every player's deadline and `ends_at`, the same
  mechanism as today.
- **Settlement:** unchanged. It reads the per-question answers it already reads.

## App changes

- `MatchState` keeps the current question per viewer rather than per match. The reducers get
  `pace.progress` and per-player `q.show`/`q.reveal`.
- A **"You're done"** view between the last answer and the result: the opponent's progress, a
  Leave button and "We'll let you know".
- The result can arrive while the app is closed: an inbox item (`match_result`) and a push open
  the result screen, which then loads the match from `GET /v1/matches/{id}`.
- Battle tab: a "Live · Own pace" choice under Rated / Casual.

## Analytics

Every answer already carries its time (`el_ms` in battles, `time_ms` in practice), stored with the
question's own limit (`question_attempts.time_limit_ms`, `match_answers`). Own-pace games add
`pace` to `match_started` / `match_finished` and record `waited_s` for the player who finished
first, so we can see how long people wait and how often they leave.

## Open questions

1. Should Quick Battle offer both modes, or should own-pace be friends-only at first?
2. How long should a Quick Battle wait for the second player: 10 minutes, or longer?
3. Do we show the opponent's score while they are still playing, or only their progress?
