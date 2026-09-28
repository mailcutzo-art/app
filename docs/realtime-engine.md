# Realtime engine: how live games run inside `rt`

This is the internal design behind `docs/protocol.md`. Every live mode uses the same engine: Quick
Battle, Practice Bot, Play with Friend, Group Battle and tournament games. Only the settings and
the settlement hooks differ.

## Pieces

```
            ┌──────────── rt node (N replicas, identical) ────────────┐
 phones ──► │ Gateway: sockets, hello/tickets, rate limits, fan-out   │
            │ Owner:   asyncio timers for the matches it leases       │──► Redis (live state, scripts,
            │ Leader:  matchmaking ticks for queues it leases         │    streams, pub/sub, leases)
            │ Scanner: adopts overdue matches whose owner vanished    │──► Postgres (match rows,
            └──────────────────────────────────────────────────────────┘    settlement, questions)
 worker: settlement retries, reconciler, stuck holds, tournament ticks
```

- **Redis is the live source of truth.** Postgres is the settled one.
- **Scripts do every state change.** Each change is one Lua script that reads Redis `TIME`, checks
  the match version, writes the new state, appends to the match log and publishes the event, all
  atomically. Nodes never read-modify-write match state from Python.
- **The design assumes one Redis primary** (with a replica for failover). That is enough for tens
  of thousands of concurrent matches. Match keys carry a `{mid}` hash tag, so a later move to Redis
  Cluster only needs the global keys (`rt:timers`, queues) sharded.

## Redis keys

| Key | Type | Contents |
|---|---|---|
| `m:{mid}` | hash | `kind`, `phase`, `ver`, `q` (current index), `total`, `limit_ms`, `reveal_ms`, `shown_at`, `deadline_at`, `ends_at`, `seq`, `humans` (uids), `bot` (uid or empty), `created_ms`, `grace_ms` |
| `m:{mid}:p` | hash | Per player (JSON, field = uid): `ready`, `connected`, `grace_until`, `lat_ms`, `score`, `correct`, `correct_ms`, `left`, `joined_q` |
| `m:{mid}:q:{i}` | hash | Question *i*: `stem`, `options` (JSON `[{id,text}]` in display order), `correct` (option id), `ref`, `limit_ms`, `open_players` (who was connected at open), and one field per answer: `a:{uid}` → JSON `{opt, raw, e, ok, pts, recv}` |
| `m:{mid}:log` | stream | Every emitted event, capped at about 300 entries (`XADD MAXLEN ~ 300`), for replays |
| `m:{mid}:lease` | string | Owning node id, `PX 4000`, renewed every second |
| `m:{mid}:final` | string | Immutable JSON result, written once at `finished`, `aborted` or `voided` |
| `rt:timers` | zset | `mid → due_ms`: when the match next needs a transition |
| `settle:q` | zset | `mid → finished_ms`, waiting to be settled in Postgres |
| `busy:{uid}` | string | Exactly one of `q:<ticket>`, `m:<mid>`, `r:<room>` or `t:<tid>` (with a safety TTL) |
| `rt:conn:{uid}` | string | `node:conn_id` of the user's live socket |
| `mm:q:{mode}:{subject}` | zset | Queue: `ticket → rating` |
| `mm:t:{ticket}` | hash | `uid`, `rating`, `rd`, `chapter` (or `*`), `joined_ms`, `device`, `hold_id`, `last_status` |
| `mm:lead:{mode}:{subject}` | string | Queue leader lease |
| `mm:cool:{uid}` | string | Queue cooldown after repeated aborts (TTL) |

Pub/sub channels:
- `ev:m:{mid}`, `ev:r:{rid}` and `ev:t:{tid}` carry events to every node with a local member.
- `ev:u:{uid}` carries events for one user.
- `ctl:u:{uid}` carries control messages: revoke, supersede, ban.

## Scripts

All scripts take `expected_ver` where it matters and return `{status, ver, due_ms}`. A version
mismatch means another node already moved the match on, so the caller simply reschedules from
the returned `due_ms`.

| Script | Does |
|---|---|
| `create.lua` | Writes the hashes for a new match (idempotent), sets `busy` for every human, and schedules the ready timeout |
| `ready.lua` | Marks a player ready. When every connected human is ready: `countdown`, `ends_at = now + 3 s` |
| `advance.lua` | The timer transition, chosen by phase (below) |
| `answer.lua` | Validates and scores one answer. Moves to `q_reveal` early when every open player has answered |
| `conn.lua` | A player connected or dropped. Sets `grace_until`, emits `opp.conn`, and pulls `due_ms` earlier if a grace deadline now comes first |
| `forfeit.lua` | Voluntary forfeit → `finished` with `reason = forfeit` |
| `emote.lua` | Emote rate limits (1 per 3 s, 10 per match), then emit |
| `end.lua` | A tournament round's deadline: finish on the current score, or no-shows before question 1 |

**`advance.lua` by phase**
- `ready_wait` past its deadline:
  - quick games → `aborted`, and the refund is recorded in `final`;
  - tournament games → no-show rules: a forfeit win for the player who showed up (`finished`,
    reason `no_show`, no rating change), or a double no-show (`aborted`, reason `no_show`).
    A tournament player past their grace, or leaving, before question 1 is not ready; once
    the others are ready that decides the game at once.
- `countdown` → `q_open(1)`. It sets `shown_at = now + 400`, `deadline_at = shown_at + limit`,
  records `open_players` (the humans connected now), emits `q.show`, and sets
  `due = deadline_at + 250`.
- `q_open(i)` past the deadline → `q_reveal(i)`. Players who haven't answered get `timeout`.
  It emits `q.reveal` with points, times and speed labels, and sets `due = now + reveal_ms`.
- `q_reveal(i)` → `q_open(i+1)`, or `finished` after the last question.
- `finished`: writes `m:{mid}:final`, runs `ZADD settle:q`, and emits `match.end`.
- **Forfeits and voids at any tick.** A human whose `grace_until` has passed forfeits: after
  question 1 the match goes to `finished` with `reason = forfeit`. Before question 1 it goes to
  `aborted`. If every human passed their grace within 5 s of each other, the match is `voided`.
  Group battles never forfeit; a missing player just scores 0.

**`answer.lua` in one atomic step**
1. Check the phase is `q_open`, `q` matches, and the player is in `open_players`.
2. De-duplicate on `a:{uid}`: a repeat returns the stored status with `dup = true`, so a resend
   after a reconnect gets the same verdict as the first send.
3. `raw = now − shown_at`, and `e = clamp(el_ms, raw − lat, raw)`.
4. Judge the timing: `too_early`, `late` or `accepted`.
5. Score it and store the answer.
6. Update the player totals and emit `q.progress`.
7. If every open player has answered, reveal now.

The gateway that received the answer sends `ans.ack` straight back to the player. Replies are
never logged, so they don't take a `seq`.

The speed labels in `q.reveal` follow `docs/data-model.md`. The scoring, speed and timing rules are
also implemented as pure Python functions (`app/modules/realtime/engine/scoring.py`), and the
tests check that the Lua and Python versions agree.

**Every emitted event does three things.** It increments `seq`, runs
`XADD m:{mid}:log MAXLEN ~ 300 * seq <n> ev <json>`, and runs `PUBLISH ev:m:{mid} <json>`. Events
are identical for every recipient.
- **Viewer-specific details** are added by the gateway as it forwards an event:
  - `result: win` in `match.end`;
  - the option order in group battles, a permutation seeded by match, player and question.
- **Per-player messages** (`ans.ack`, `match.settled`) never go through the log. Per-player data
  in the shared stream would either leak to the other players or leave them with `seq` gaps that
  never close.

## Owners, timers and failover

- **Ownership.** Whoever creates a match takes its lease (`SET m:{mid}:lease node NX PX 4000`) and
  keeps one asyncio timer for it at `due_ms`. A single Lua call per second renews the leases of
  every match the node owns, and only where it is still the owner.
- **Timer fires.** The owner calls `advance.lua(expected_ver)`, then reschedules from the returned
  `due_ms`. Every script that changes `due_ms` also does `ZADD rt:timers mid due`. So when an
  answer arriving on another node reveals a question early, the owner simply finds a newer version
  on its next fire.
- **Scanner.** Every 250 ms each node reads `rt:timers` for matches more than 1 s overdue.
  - For each, it tries to take the lease. If it gets it, it becomes the owner and fires at once.
  - A dead node's matches resume within about 1–5 s. Writes from the stale owner fail the `ver`
    check.
- **Graceful shutdown (SIGTERM).**
  - Stop accepting sockets.
  - Release leases so others adopt the matches straight away.
  - Close sockets with `1012`.
  - Exit within 10 s.
  - `1012` adds 60 s to every affected player's grace, so a deploy never causes a forfeit.

## Practice Bot

- The bot is a virtual participant with uid `bot:{mid}`.
- **When it answers.** When the owner opens question *i*, it asks the pure bot model when the bot
  answers and whether it's right. The model uses the user's expected accuracy clamped to 45–75%,
  and a log-normal time with a 6 s median and a 1.5 s minimum.
- **Determinism.** The model is seeded by `hash(mid, i)`, so a new owner after failover computes
  the same answer.
- **Delivery.** The owner schedules `answer.lua` for `shown_at + t`. The bot never makes a match
  rated and never gets a speed label.

## Matchmaking

- **Joining.** `mm.join` runs in Python:
  - rate limits, the cooldown, and the busy slot;
  - for casual play, a Postgres coin hold in its own transaction;
  - then `mm_join.lua`, which sets `busy`, creates the ticket and adds it to the queue.

  If the script fails, the hold is released.
- **Queue leaders.** One node per queue holds `mm:lead:{mode}:{subject}`. Every 500 ms it:
  1. Loads the queue and its tickets.
  2. Drops tickets whose owner has been offline for more than 10 s, or that are older than 105 s.
     This releases their holds.
  3. Pairs, oldest ticket first, using the pure rules in
     `app/modules/realtime/matchmaking/rules.py` (compatibility, rating windows, chapter
     widening).
  4. Runs `mm_pair.lua` for each pair. It checks both tickets still exist and both `busy` values
     still point at them, removes them, and sets `busy` to the new match.
  5. Creates the match: Postgres rows first (the `matches` row, and `match_questions` with the
     option maps), then `create.lua`. If that fails, `mm_unpair.lua` puts both tickets back
     with their original `joined_ms`.
  6. Publishes `mm.found` to both players.
  7. Publishes `mm.status` when a ticket's widening or window changes, and `mm.timeout` at 45 s.
     The ticket keeps searching while the choice is on screen.
- **Choosing questions.**
  - It uses published questions with `battle_pool <> 'none'` from the source chapters, suited to
    both players' exams.
  - It follows the difficulty mix for the pair's average rating.
  - It excludes questions either player has seen (`user_questions`), falling back to the least
    recently seen. It never blocks.
  - Options are shuffled and given fresh random 5-character ids. The id → correct map lives only
    in Redis and `match_questions`.

## Settlement

- **When.** `finished`, `aborted` and `voided` all end in `settle:q`. The owner settles at once,
  and the worker retries anything older than 10 s every 5 s.
- **One Postgres transaction:**
  1. `SELECT … FOR UPDATE` on the match row; stop if it's already settled.
  2. Insert `match_participants`, `match_answers` and `question_attempts` (with speed labels and
     peer times), plus the running totals and `user_questions` updates.
  3. Update ratings (Glicko-2; rows locked in user order).
  4. Post the coin ledger entries with idempotency keys `m:{mid}:{uid}:{kind}`.
  5. Record XP and mission progress, and the tournament pairing result.
  6. Write the outbox rows, and mark the match settled.
- **After commit.**
  - Publish each player's `match.settled` to their own `ev:u:{uid}`, with no `seq`. The envelope's
    `ch` is still `m:<mid>`, so the app files it under the match.
  - Then `ZREM settle:q`, clear `busy`, and let the keys expire an hour later.
  - A player who misses it (offline, app killed) reads the same numbers from
    `GET /v1/matches/{id}`.
- **Reconciler.** A Postgres match still live after its maximum duration plus 5 minutes, with no
  Redis state, is voided and refunded. An alert fires if settlement lags more than 60 s.

## Gateway

- **Accepting a socket.** It accepts the socket, waits up to 5 s for `hello`, and consumes the
  ticket with `GETDEL`. It rejects revoked sessions, bans and old builds with the close codes in
  the protocol doc.
- **One socket per user.** It sets `rt:conn:{uid}`. If an older socket exists, it publishes
  `ctl:u:{uid}` so that socket closes with `4409`.
- **Subscriptions.** Each node subscribes to `ev:u:{uid}` for its sockets, and to `ev:m:{mid}` or
  `ev:r:{rid}` while it has a local member. It unsubscribes when the last one leaves.
- **Resume.** For each `resume` entry it runs `XRANGE m:{mid}:log (last_seq +`. If the log no
  longer reaches back that far, it sends a snapshot built from the hashes.
- **Per connection:**
  - an in-memory token bucket for inbound frames;
  - an outbound queue of 256, dropping `q.progress` and `emote` first;
  - heartbeat pings every `hb_s`: 30 s when idle, 10 s while queued or in a room, 5 s in a match,
    announced with `hb`. It keeps the last 10 round trips for the latency allowance (`lat_ms` in
    `m:{mid}:p`).

## Implementation notes

Where the pieces live in `backend/app`:

| Piece | Code |
|---|---|
| Gateway, sockets, fan-out | `modules/realtime/gateway.py`, `connection.py`, `hub.py`, `node.py` |
| Scripts | `modules/realtime/engine/lua/*.lua` (every match script is `lib.lua` plus its body), wrapped by `engine/scripts.py` |
| Owners, timers, scanner, the bot's answers | `modules/realtime/engine/owner.py` |
| Matchmaking | `modules/realtime/matchmaking/service.py` (join, cancel, respond, leaders), `tickets.py` |
| Rematches | `modules/realtime/rematch.py` |
| Match rows, questions, settlement | `modules/matches/creation.py`, `questions.py`, `settlement.py`, `jobs.py` |
| Ratings | `modules/ratings/service.py` (Glicko-2 in `glicko2.py`) |

Details the sections above leave open:

- **Totals move at the reveal.** `answer.lua` scores and stores the answer, but the player's
  score and correct count grow in the reveal, so a snapshot taken while a question is open never
  tells an opponent whether an answer was right.
- **Who may answer.** Anyone who hasn't left may answer an open question, including a player who
  reconnected after it opened. `open_players` decides only the early reveal and who a speed
  label compares with.
- **End reasons.** A voluntary forfeit ends with `forfeit`, a player past their grace with
  `disconnected`. A forfeit (or an expired grace) before question 1 aborts the match.
- **Abort strikes.** A player who left before question 1, or who never got ready while away or
  with the app in the background, gets a strike; three in an hour start the 5-minute cooldown.
  One who simply missed the tap while using the app doesn't. Ready players of an aborted quick
  match who are still online go back to the queue with their original `joined_ms` (and keep their
  casual hold).
- **Busy slots are freed as the match ends** (in `finish`), not at settlement, so "Play again"
  never waits for Postgres.
- **What other features plug in** (`modules/matches/ports.py`, connected in one place by
  `modules/matches/wiring.py` at the start of every process): the `EscrowPort` (casual holds on
  the coin ledger, captures, refunds and the pot), settlement hooks (each returns pieces of
  `match.settled` and runs inside the settlement transaction: `progress_hooks` for XP,
  missions, streak and achievements run before the escrow locks any wallet, then `hooks` for
  rated coin rewards, inbox notices and analytics), the block and shadow-pool checks for
  matchmaking, social presence, analytics and inbox writers, and readers for the wallet
  balance, leaderboard leaders and relationships. A ban or an account deletion withdraws the
  player through the outbox (`matches.withdraw`): the search is cancelled and refunded, or the
  live match forfeited.
- **Timings are settings.** `APP_RT_*`, `APP_MATCH_*` and `APP_MM_*` (see `backend/.env.example`);
  the protocol tests play whole games in about two seconds with them.
