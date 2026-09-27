# Realtime protocol v1

The contract between the app's `RealtimeClient` and the `rt` servers. Live battles (Quick Battle,
Practice Bot, Play with Friend, Group Battle) and tournament games all use it. REST (`/v1/...` on
`api`) handles everything that isn't live.

**Principles**
- **The server is authoritative.** The client sends intents; the server decides question order,
  timing, correctness, points and results.
- **Nothing leaks early.** The correct answer, question ids and difficulty are never sent while a
  question is open.
- **One clock.** Every server timestamp (`ts`, `shown_at`, `deadline_at`, `ends_at`) is server
  time in Unix milliseconds. The client maps it to its own clock with the offset from clock sync
  and only uses it for display.
- **Everything is resumable.** A dropped connection loses nothing: the client reconnects, and the
  server replays what was missed or sends a snapshot.

## 1. Connecting

1. `POST /v1/rt/tickets` (authenticated REST) → `{"ticket": "…", "expires_in": 30}`.
   A ticket is 32 random bytes (base64url). It is valid for 30 s and for one connection.
2. Open `wss://<host>/v1/ws`. **The ticket never goes in the URL.**
3. Within 5 s send `hello`:

   ```json
   {"v": 1, "t": "hello", "id": "c1", "d": {
     "ticket": "q3Jd…", "proto": 1, "build": 57, "platform": "android",
     "resume": [{"ch": "m:01929c2e-…", "last_seq": 41}]
   }}
   ```

4. The server consumes the ticket. It then checks that the session isn't revoked, the account
   isn't banned, and the protocol version and build are supported. Then it replies:

   ```json
   {"v": 1, "t": "welcome", "ch": "u", "ts": 1790000000123, "d": {
     "conn_id": "k9…", "user_id": "01929b…", "server_ms": 1790000000123, "hb_s": 10,
     "active": [{"kind": "match", "ch": "m:01929c2e-…", "state": "q_open"}]
   }}
   ```

   `active` lists anything the user is in right now: a queue ticket, a match, a room, or a
   running tournament. After a crash or a cold start, the app uses it to jump straight back into
   the game.

A user has **one live connection**. A newer connection closes the older one with `4409`
("Playing on another device").

## 2. Envelope

Every frame is one JSON object in a UTF-8 text frame.

| Field | Direction | Meaning |
|---|---|---|
| `v` | both | Protocol version, `1` |
| `t` | both | Message type, e.g. `ans.submit`, `q.show` |
| `id` | client → server | Client message id (≤ 36 chars, unique per connection). Echoed as `ref` in the matching `ack`/`error` |
| `ch` | server → client | Channel the event belongs to (below) |
| `seq` | server → client | Per-channel sequence number, on resumable channels only |
| `ts` | server → client | Server time (ms) when the event was produced |
| `d` | both | Payload object (may be `{}`) |

**Channels**

| Channel | Carries | Resumable |
|---|---|---|
| `u` | Things for this user only: welcome, matchmaking updates, match assignments, settlement results, invites | No |
| `m:<match_id>` | One match's events | Yes |
| `r:<room_id>` | One room's lobby events (friend duel or group battle) | Yes |
| `t:<tournament_id>` | Standings and round updates, only after `sub` | No (the snapshot is re-sent on `sub`) |

Unknown message types and unknown fields are ignored on both sides, so fields can be added within
v1. Breaking changes get a new endpoint, `/v2/ws`, served alongside v1 for at least 60 days.

## 3. Keeping the connection healthy

- **Heartbeat.** The server sends `ping {"n": 7}` every `hb_s` seconds (10 s, or 5 s while the
  user is in a match), and the client answers `pong {"n": 7}` at once. The server measures the
  round trip. Its median over the last 10 samples sets this player's latency allowance
  (section 7).
- **Stale connections.** Without any frame for 12 s in a match (30 s otherwise), the server closes
  the connection and treats the player as disconnected. On the client side, if no frame arrives
  for `2 × hb_s + 2` seconds, the client assumes the connection is dead and reconnects.
- **Clock sync.** The client sends `clock.ping {"c0": <client monotonic ms>}` and the server answers
  `clock.pong {"c0": …, "s": <server ms>}`.
  - On each reconnect the client takes 5 samples and keeps the one with the smallest round trip:
    `offset = s − (c0 + rtt / 2)`. It drops samples with a round trip above 1 s.
  - It re-syncs every 60 s.
- **Reconnect backoff.** Full jitter: a random 0–(500 ms × 2^attempt), capped at 10 s (2 s while
  in a match). Backoff pauses while the phone has no network. After close code `1012`, the client
  reconnects after a random 0–2 s.

## 4. Errors, acks and limits

- `ack {"ref": "c7"}` confirms a request that has no other natural reply.
- `error {"ref": "c7", "code": "BUSY", "message": "You're already in a match.", "retryable": false, "details": {…}}`

| Code | When |
|---|---|
| `BAD_REQUEST` | Malformed payload or invalid values |
| `NOT_FOUND` | Unknown match, room, code or tournament |
| `NOT_ALLOWED` | Not a participant, not the host, blocked, room locked, age restriction |
| `BUSY` | Already queued, playing, in a room or in a running tournament. `details.active` says where |
| `ALREADY_MATCHED` | A cancel lost the race with a match being found. `details.match_id` |
| `INSUFFICIENT_COINS` | Casual entry or room fee can't be paid |
| `COOLDOWN` | Queueing blocked for a while (repeated aborts). `details.until` |
| `RATE_LIMITED` | Too many requests of this kind. `details.retry_after_s` |
| `UNAVAILABLE` | Maintenance or overload; retry later |

**Limits**
- Inbound frames: at most 4 KiB, and 10 per second with bursts of 30.
- Three violations close the connection with `4429`. Oversized or unparsable frames close it with
  `4400`.
- Each connection has an outbound queue of 256 frames. When it fills, the server first drops
  `q.progress` and `emote` frames. If it still overflows, it closes with `1013`, and the client
  resumes on reconnect.

**Close codes**

| Code | Meaning | Client action |
|---|---|---|
| `1000` | Normal close | Reconnect only if a screen still needs the connection |
| `1012` | Server restarting | Reconnect after 0–2 s. Never counts against the player |
| `1013` | Too slow to keep up | Reconnect and resume |
| `4400` | Bad message | Report a bug. Reconnect with backoff |
| `4401` | Bad or expired ticket | Get a new ticket, then reconnect |
| `4403` | Session revoked or account banned | Stop. Go to sign-in (or show the ban notice) |
| `4408` | No `hello` within 5 s | Reconnect |
| `4409` | Replaced by a newer connection | Stop, and show "Playing on another device" |
| `4426` | App too old | Stop, and show the update screen |
| `4429` | Rate limited | Reconnect after 10 s |

## 5. Matchmaking (Quick Battle)

Client → server:

| Type | Payload | Notes |
|---|---|---|
| `mm.join` | `{"mode": "rated" \| "casual", "subject": "physics", "chapter": "kinematics" \| null, "idem": "<uuid>"}` | `chapter: null` means "All chapters". A repeat with the same `idem` returns the existing ticket. Casual holds the 5-coin entry |
| `mm.cancel` | `{}` | Releases the queue slot and any coin hold |
| `mm.respond` | `{"choice": "keep" \| "bot" \| "invite" \| "cancel"}` | Answer to `mm.timeout` |

Server → client (channel `u`):

| Type | Payload |
|---|---|
| `mm.queued` | `{"ticket_id", "mode", "subject", "chapter", "joined_at"}` |
| `mm.status` | `{"waited_s": 17, "widened": true, "window": 250 \| null}`. Sent when something changes: the search widens to the whole subject at 15 s, or the rating range grows |
| `mm.timeout` | `{"waited_s": 45, "options": ["keep", "bot", "invite", "cancel"]}`. `bot` is offered only for casual and unrated play, never for rated |
| `mm.cancelled` | `{"reason": "user" \| "timeout" \| "disconnected" \| "cooldown"}`. Any hold is released |
| `mm.found` | `{"match_id", "ch": "m:<id>", "mode", "opponent": {…player card…}, "sources": [{"chapter": "kinematics", "count": 4}, {"chapter": "laws-of-motion", "count": 3}], "bot": false}` |

- **Wait rules.** After 15 s the search also accepts players from other chapters of the same
  subject, and `sources` then splits the questions (4 + 3). "Keep searching" after `mm.timeout`
  waits 60 s more, then cancels automatically.
- **Disconnects.** A ticket survives a disconnect for 10 s, then it is cancelled.

## 6. Matches

After `mm.found` (or `room.started`, or `t.pairing`), the client listens on `m:<match_id>`. The
first frame it gets there is a `match.snapshot`.

**Phases:** `ready_wait` → `countdown` → (`q_open` → `q_reveal`) × N → `finished`. A match can
also end in `aborted` (someone never got ready, before question 1) or `voided` (both players
dropped, or an integrity problem). Neither of those changes ratings or coins.

Client → server:

| Type | Payload | Notes |
|---|---|---|
| `match.ready` | `{"match_id"}` | Sent when the VS screen is on screen and assets are ready |
| `ans.submit` | `{"match_id", "q": 3, "opt": "k2P9x", "el_ms": 6240}` | `opt` is the option id from `q.show`. `el_ms` is the client's measured time since the question appeared (advisory, section 7). Resent with the same `id` if no `ans.ack` arrives within 2 s |
| `emote` | `{"match_id", "e": "gg" \| "nice" \| "wow" \| "oops"}` | At most 1 every 3 s and 10 per match |
| `match.forfeit` | `{"match_id"}` | Leaves and loses |
| `sync` | `{"ch": "m:<id>", "last_seq": 41}` | Sent after a `seq` gap. The server replays or sends a snapshot |

Server → client (channel `m:<match_id>`, with `seq`):

| Type | Payload |
|---|---|
| `match.snapshot` | Full state: `{"match_id", "kind", "phase", "ends_at", "q", "total", "limit_ms", "players": [card + `connected`, `score`, `answered`], "question": <current q.show payload or null>, "reveal": <last q.reveal or null>, "mine": [{"q", "opt", "status"}]}` |
| `match.phase` | `{"phase": "countdown", "q": 0, "ends_at": 1790000003000}` |
| `q.show` | `{"q": 1, "total": 7, "stem": "…", "options": [{"id": "k2P9x", "text": "…"} ×4], "shown_at": T, "deadline_at": T + limit, "limit_ms": 15000, "chapter": "Kinematics"}` |
| `q.progress` | `{"q": 1, "answered": ["<uid>"]}`: who has answered, never what |
| `ans.ack` | `{"ref", "q": 1, "status": "accepted" \| "late" \| "dup" \| "too_early" \| "invalid" \| "wrong_phase"}` |
| `q.reveal` | `{"q": 1, "correct": "k2P9x", "players": {"<uid>": {"opt": "k2P9x" \| null, "correct": true, "pts": 132, "time_ms": 6010, "speed": "fast" \| "slow" \| "even" \| null}}, "totals": {"<uid>": {"points": 382, "correct": 3}}, "ref": "<question ref>"}` |
| `opp.conn` | `{"uid", "state": "connected" \| "reconnecting" \| "left", "grace_until": 1790000031000}` |
| `emote` | `{"uid", "e": "gg"}` |
| `match.end` | `{"result": "win" \| "loss" \| "draw", "reason": "normal" \| "forfeit" \| "opponent_forfeit" \| "aborted" \| "voided", "totals": {…}, "ranking": [["<uid>"], …]}`. `result` is from the receiver's point of view |
| `match.settled` | `{"rating": {"scope": "physics", "before": "1502?", "after": "1518?", "delta": 16} \| null, "coins": {"delta": 10, "balance": 245}, "xp": {"delta": 30, "level": 4, "into_level": 120, "for_next": 250}, "missions": [{"id", "progress", "target", "done"}]}` |

- **Question timing.** `q.show` is sent about 400 ms before `shown_at`, so every client has it
  before it goes live. The client keeps the question hidden until its synced clock reaches
  `shown_at`, then starts the countdown ring from `deadline_at`.
- **Early advance.** When everyone has answered, the server moves to `q_reveal` early. Otherwise
  it waits until `deadline_at` plus a 250 ms grace.
- **After the match.** `ref` in `q.reveal` identifies the question in this match. Once the match is
  finished, `GET /v1/matches/{id}/review` returns every question with its explanation and bookmark
  state.
- **Settlement.** `match.settled` arrives after the server commits the result. If the client
  misses it, `GET /v1/matches/{id}` has the same numbers. Until then the result screen shows
  "Results syncing…".
- **Disconnects.** The match clock never pauses. A disconnected player gets a grace period (30 s
  quick, 45 s tournament, 60 s friend). The other players see `opp.conn` with `grace_until`. In
  group battles a missing player simply scores 0 until they're back.

## 7. Fair timing

- **Server times.** The server records `raw = received_at − shown_at` for every answer.
- **Latency allowance.** `lat = min(250, median heartbeat round trip / 2)` in ms.
- **Effective time.** The client's `el_ms` only counts within `[raw − lat, raw]`:
  `e = clamp(el_ms, raw − lat, raw)`. A fast network can't be faked, and a slow one isn't
  punished.
- **Status.**
  - `raw < 0`: the answer is `too_early` (flagged for anti-cheat).
  - `e > limit_ms`, or `raw > limit_ms + lat`: `late`.
  - Anything else is `accepted`.
- **Points.** A correct answer scores `100 + round(50 × (1 − clamp((e − 1000) / (limit − 1000), 0, 1)))`,
  so 100–150. A wrong answer or no answer scores 0.
- **Tie-breaks.** Totals are compared by points, then the number of correct answers, then the
  total `e` on correct answers. If all three are equal, it's a draw.
- **Speed labels** (`speed` in `q.reveal`, also stored on each answer record). Each player's time
  is compared with the other human players who were connected when the question opened: the
  opponent in a 1v1, or the median of those who answered in a group.
  - More than 250 ms sooner is `fast`, more than 250 ms later is `slow`, and anything closer is
    `even`.
  - Answering when nobody else did is `fast`, and timing out when someone answered is `slow`.
  - Bot games have no speed label (`null`).

## 8. Rooms: Play with Friend and Group Battle

Rooms are created over REST, `POST /v1/rooms {"kind": "friend" | "group", "settings": {…}}`, which
returns `{"room_id", "code": "K7M2QX", "link"}`. Everything after that is live.

Client → server:

| Type | Payload | Who |
|---|---|---|
| `room.join` | `{"code": "K7M2QX"}` or `{"room_id"}` | Anyone allowed (friends only, or anyone with the code) |
| `room.leave` | `{"room_id"}` | Any member |
| `room.ready` | `{"room_id", "ready": true}` | Any member |
| `room.settings` | `{"room_id", "settings": {…}}` | Host, lobby only |
| `room.start` | `{"room_id"}` | Host; needs at least 2 connected players |
| `room.kick` | `{"room_id", "uid"}` | Host; the player can't rejoin this room |
| `room.lock` | `{"room_id", "locked": true}` | Host |
| `room.transfer` | `{"room_id", "uid"}` | Host |
| `room.end` | `{"room_id"}` | Host |
| `room.rematch` | `{"room_id", "accept": true}` | Any member, within the rematch window |

Server → client (channel `r:<room_id>`, with `seq`):

| Type | Payload |
|---|---|
| `room.state` | The whole lobby: `{"room_id", "kind", "code", "host", "status": "lobby" \| "playing" \| "finished", "locked", "settings", "members": [card + `ready`, `connected`, `role`]}`. Sent on join and after every change |
| `room.started` | `{"match_id", "ch": "m:<id>"}` |
| `room.kicked` | `{"room_id"}` (to the kicked player) |
| `room.closed` | `{"room_id", "reason": "host_ended" \| "idle" \| "host_left" \| "empty"}` |

- **Settings.** Friend duels are always unrated and free. Settings are subject, chapter or All,
  question count and seconds per question. Group battles add difficulty, late join, the
  leaderboard between questions, and who can join.
- **Codes.** Codes use Crockford base32 and expire 10 minutes after the lobby empties or closes.
- **Code guesses.** Wrong codes are rate-limited per user (5 a minute, 30 an hour).

## 9. Tournaments

- `sub {"ch": "t:<id>"}` starts standings updates, and `unsub` stops them. The server answers
  `sub` with the current `t.standings`, then sends updates at most every 2 s.
- `t.standings {"round": 3, "rows": [{"rank", "uid", "name", "points", "bh_c1", …}], "me": {…}}`.
- `t.round {"round": 3, "status": "pairing" \| "live" \| "done", "starts_at", "ends_at"}`.
- **Pairings.** Your own pairing arrives on `u`:
  `t.pairing {"tournament_id", "round", "match_id", "ch": "m:<id>", "opponent": {…}, "ready_by": <ms>}`,
  or `{"bye": true}`. You have 90 s to send `match.ready`.

## 10. Resuming after a reconnect

- **Resuming.** `hello.resume` lists the resumable channels the client was on, with the last
  `seq` it processed. For each one, the server either:
  - **replays** every event with a higher `seq`, if they are still in the channel's log (about the
    last 300 events); or
  - sends a **snapshot** (`match.snapshot` or `room.state`, whose `seq` is the channel's current
    `seq`).
- **Gaps and duplicates.** The client ignores events with `seq ≤` the last one it applied. A gap
  (`seq > last + 1`) triggers `sync`.
- **Answers in flight.** Unacknowledged `ans.submit` frames are resent after reconnecting, with
  the same `id`. The server's answer is idempotent per player and question (`dup`).
- **Cold starts.** After a crash, `welcome.active` has everything needed to reopen the game. The
  app never stores question content on disk.

## 11. Example: a Quick Battle

```
C → POST /v1/rt/tickets                        ← {"ticket": "…"}
C → hello                                      ← welcome {active: []}
C → mm.join {mode: rated, subject: physics, chapter: kinematics, idem}
                                               ← mm.queued
                                               ← mm.status {waited_s: 15, widened: true}
                                               ← mm.found {match_id, opponent, sources}
                                               ← (m:) match.snapshot {phase: ready_wait}
C → match.ready                                ← match.phase {countdown, ends_at}
                                               ← q.show {q: 1, …, shown_at, deadline_at}
C → ans.submit {q: 1, opt, el_ms}              ← ans.ack {accepted}
                                               ← q.progress {answered: [me, them]}
                                               ← q.reveal {correct, players, totals}
   … questions 2–7 …
                                               ← match.end {result: win}
                                               ← match.settled {rating, coins, xp, missions}
```
