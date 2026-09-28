# Realtime protocol v1

The contract between the app's `RealtimeClient` and the `rt` servers. Live battles (Quick Battle,
Practice Bot, Play with Friend, Group Battle) and tournament games all use it. REST (`/v1/...` on
`api`) handles everything that isn't live.

**Principles**
- **The server is authoritative.** The client sends intents; the server decides question order,
  timing, correctness, points and results.
- **Nothing leaks early.** The correct answer, question ids and difficulty are never sent while a
  question is open.
- **One clock.** Every time on the socket (`ts`, `shown_at`, `deadline_at`, `ends_at`,
  `grace_until`, `expires_at`, `closes_at`, `resets_at`, `until`) is server time in Unix
  milliseconds, as an integer. The client maps it to its own clock with the offset from clock sync
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
     "resume": [{"ch": "m:01929c2e-…", "last_seq": 41}], "takeover": false
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

**When the app connects.** It keeps **one connection whenever it is in the foreground and signed
in**, on every tab. That way invites, inbox updates and tournament calls arrive live wherever the
user is. It lets the connection go shortly after the app goes to the background, and a live match
keeps its own grace rules.

**One connection per user.** A newer connection normally replaces the older one, which closes with
`4409` ("Playing on another device").
- **A live match on another device is not taken over by accident.** If `takeover` isn't true,
  the server answers `error {"code": "LIVE_ELSEWHERE", "details": {"match_id"}}` and closes only
  the new connection with `4409`.
- The app then asks "Move the game here?" and reconnects with `takeover: true`.

**App state.** After every `welcome`, and whenever it changes, the client sends
`client.state {"state": "foreground" | "background"}`. The server uses it to stop a queued
search after 10 s in the background (no penalty), and as an anti-cheat signal for a question
left open while the app is in the background.

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

- **What `u` carried while disconnected** is recovered without replay: `welcome.active` says which
  queue, match, room or tournament the user is in, and REST has the rest (inbox, invites, and
  `GET /v1/matches/{id}` for results).
- **Shared and per-player events.** Events on `m:` and `r:` are the same for every member, and are
  numbered with `seq` and kept in the channel's log. A few messages are for one player only. They
  go to that player alone, on the same channel but **without** `seq`, and are never logged:
  - replies (`ack`, `error`, `ans.ack`);
  - `match.settled`.
- **Viewer-specific details** of a shared event are added as it's forwarded, without changing its
  `seq`: `result` in `match.end`, and the option order in group battles.
- **Player cards.** On the socket a player is `{"uid", "handle", "display_name", "avatar": {"tone",
  "symbol"}, "level", "is_bot"}`. `mm.found.opponent` adds `rating` and `record`.

Unknown message types and unknown fields are ignored on both sides, so fields can be added within
v1. Breaking changes get a new endpoint, `/v2/ws`, served alongside v1 for at least 60 days.

## 3. Keeping the connection healthy

- **Heartbeat.** The server sends `ping {"n": 7}` every `hb_s` seconds, and the client answers
  `pong {"n": 7}` at once. `hb_s` is 30 s when the user is idle, 10 s while queued or in a room,
  and 5 s in a match. The server announces a new interval with `hb {"s": 5}`. The server measures the
  round trip. Its median over the last 10 samples sets this player's latency allowance
  (section 7).
- **Stale connections.** Without any frame for 12 s in a match (25 s while queued or in a room, 70 s
  when idle), the server closes
  the connection and treats the player as disconnected. On the client side, if no frame arrives
  for `2 × hb_s + 2` seconds, the client assumes the connection is dead and reconnects.
- **Clock sync.** The client sends `clock.ping {"c0": <client monotonic ms>}` and the server answers
  `clock.pong {"c0": …, "s": <server ms>}`.
  - On each reconnect the client takes 5 samples and keeps the one with the smallest round trip:
    `offset = s − (c0 + rtt / 2)`. It drops samples with a round trip above 1 s.
  - It re-syncs every 60 s during a match, and every 5 minutes otherwise.
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
| `BUSY` | Already queued, playing, in a room, or in a tournament that starts within 5 minutes or is running. `details.active = {"kind": "queue" \| "match" \| "room" \| "tournament", "id", "title"}` says where, so the app can offer **Go there** |
| `ALREADY_MATCHED` | A cancel lost the race with a match being found. `details.match_id` |
| `INSUFFICIENT_COINS` | Casual entry or room fee can't be paid |
| `COOLDOWN` | Queueing blocked for a while (repeated aborts). `details.until` |
| `RATE_LIMITED` | Too many requests of this kind. `details.retry_after_s` |
| `UNAVAILABLE` | Maintenance or overload; retry later |
| `LIVE_ELSEWHERE` | A live match is running on another device; reconnect with `takeover: true` to move it here |

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
| `mm.join` | `{"mode": "rated" \| "casual" \| "bot", "subject": "physics", "chapter": "kinematics" \| null, "idem": "<uuid>"}` | `chapter: null` means "All chapters". A repeat with the same `idem` returns the existing ticket. Casual holds the 5-coin entry. `bot` starts a Practice Bot game at once, with no queue and no coins, and replies with `mm.found {bot: true}` |
| `mm.cancel` | `{}` | Releases the queue slot and any coin hold |
| `mm.respond` | `{"choice": "keep" \| "bot" \| "invite" \| "cancel"}` | Answer to `mm.timeout`. `bot`, `invite` and `cancel` end the ticket first, which releases any casual hold (`mm.cancelled {refunded}`) |

Server → client (channel `u`):

| Type | Payload |
|---|---|
| `mm.queued` | `{"ticket_id", "mode", "subject", "chapter", "joined_at"}` |
| `mm.status` | `{"waited_s": 17, "widened": true, "window": 250 \| null}`. Sent when something changes: the search widens to the whole subject at 15 s, or the rating range grows |
| `mm.status` (extended) | Also carries `online` (players searching in this subject right now) and `p50_wait_s` (the typical wait at this hour), so the app can say "3 players searching · usually 20 s" |
| `mm.timeout` | `{"waited_s": 45, "options": ["keep", "bot", "invite", "cancel"]}`. Offered to everyone. The bot game itself is always unrated and coin-free, even when the search was rated. On a player's first-ever search the bot is also offered at 20 s |
| `mm.cancelled` | `{"reason": "user" \| "timeout" \| "background" \| "disconnected" \| "cooldown", "refunded": 5}`. Any hold is released, and `refunded` says how many coins came back (0 for rated). `timeout` means no one was found in 105 s. `background` means the app was in the background for more than 10 s; it never counts as an abort. `disconnected` means the connection was lost for more than 10 s. Also kept in the inbox |
| `mm.requeued` | `{"reason": "opponent_not_ready" \| "match_failed", "waited_s": 31}`. The found match fell through and the ticket is back at the front of the queue with its original waiting time. The app says "Your opponent didn't join. Searching again…" |
| `mm.found` | `{"match_id", "ch": "m:<id>", "mode", "opponent": {…player card…, "rating": {…}, "record": {"wins": 3, "losses": 1, "draws": 0}}, "sources": [{"chapter": "kinematics", "name": "Motion in a Straight Line", "count": 4}, {"chapter": "laws-of-motion", "name": "Laws of Motion", "count": 3}], "bot": false}`. `record` is your head-to-head record against this opponent. The app shows the found screen wherever the user is |

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
| `match.rematch` | `{"match_id", "accept": true}` | Casual Quick Battle only, within 15 s of `match.end`, and at most 3 in a row. When both accept, a new `mm.found` arrives (a new 5-coin entry is held first) |
| `sync` | `{"ch": "m:<id>", "last_seq": 41}` | Sent after a `seq` gap, or with `last_seq: 0` to rejoin after a cold start. The reply is the replay or a snapshot; there is no `ack` |

Server → client (channel `m:<match_id>`, with `seq`, the same for every player):

| Type | Payload |
|---|---|
| `match.snapshot` | Full state, built for the receiving player: `{"match_id", "kind", "phase", "ends_at", "q", "total", "limit_ms", "players": [card + `connected`, `grace_until`, `score`, `correct`, `answered`], "question": <current q.show payload or null>, "reveal": <last q.reveal or null>, "mine": [{"q", "opt", "status"}], "end": <the match.end payload or null>, "settled": false}`. Its envelope `seq` is the channel's current `seq` |
| `match.phase` | `{"phase": "countdown", "q": 0, "ends_at": 1790000003000}` |
| `q.show` | `{"q": 1, "total": 7, "stem": "…", "options": [{"id": "k2P9x", "text": "…"} ×4], "shown_at": T, "deadline_at": T + limit, "limit_ms": 15000, "chapter": "Kinematics"}` |
| `q.progress` | `{"q": 1, "answered": ["<uid>"]}`: who has answered, never what |
| `q.reveal` | `{"q": 1, "correct": "k2P9x", "players": {"<uid>": {"opt": "k2P9x" \| null, "correct": true, "pts": 132, "time_ms": 6010, "speed": "fast" \| "slow" \| "even" \| null}}, "totals": {"<uid>": {"points": 382, "correct": 3}}, "ref": "<question ref>"}` |
| `opp.conn` | `{"uid", "state": "connected" \| "reconnecting" \| "left", "grace_until": 1790000031000}` |
| `emote` | `{"uid", "e": "gg"}` |
| `match.end` | `{"result": "win" \| "loss" \| "draw", "reason": "normal" \| "forfeit" \| "opponent_forfeit" \| "left" \| "disconnected" \| "no_show" \| "ended_by_host" \| "aborted" \| "voided", "totals": {…}, "ranking": [["<uid>"], …]}`. `result` is from the receiver's point of view. `left` means someone chose to leave, `disconnected` means someone was away past their grace, `no_show` means a tournament player never got ready, and `ended_by_host` means a group host ended the game early on the current scores |
| `rematch.status` | `{"match_id", "state": "offered" \| "accepted" \| "declined" \| "expired" \| "failed", "by": "<uid>", "reason": "insufficient_coins" \| "opponent_left" \| null}` |

Server → client, only to one player (channel `m:<match_id>`, **no** `seq`, never logged):

| Type | Payload |
|---|---|
| `ans.ack` | `{"ref", "q": 1, "status": "accepted" \| "late" \| "too_early" \| "invalid" \| "wrong_phase", "dup": false}`. A repeat of an answer the server already has (a resend after a reconnect, or a second tap) gets the first answer's `status` again with `dup: true`. A status never changes once given |
| `match.settled` | `{"match_id", "rating": {"scope": "physics", "before": "1502?", "after": "1518?", "delta": 16} \| null, "rank": {"board": "rating:physics", "before": 47, "after": 42} \| {"board": "rating:physics", "games_to_rank": 6} \| null, "coins": {"delta": 10, "balance": 245, "capped": false}, "xp": {"delta": 30, "level": 4, "into_level": 120, "for_next": 250, "level_up": false, "capped": false}, "resets_at": 1790035200000, "missions": [{"id", "title", "progress", "target", "done"}], "streak": {"days": 5, "extended": true}, "achievements": [{"id", "title"}], "tip": {"message", "action", "params"} \| null}` |

- **Question timing.** `q.show` is sent about 400 ms before `shown_at`, so every client has it
  before it goes live. The client keeps the question hidden until its synced clock reaches
  `shown_at`, then starts the countdown ring from `deadline_at`.
- **Early advance.** When everyone has answered, the server moves to `q_reveal` early. Otherwise
  it waits until `deadline_at` plus a 250 ms grace.
- **Stale snapshots.** The client ignores a `match.snapshot` whose `seq` is lower than the last one
  it applied.
- **Option order in group battles.** Each player sees the options in their own order (the same
  ids). The order is fixed per player and question, so a resend or a snapshot shows the same order.
- **Group standings.** In group battles with the between-questions leaderboard on, `q.reveal` also
  carries `"standings": [{"uid", "points", "place", "change"}]`. `match.end.ranking` is the final
  order for the podium screen.
- **After the match.** `ref` in `q.reveal` identifies the question in this match. Once the match is
  finished, `GET /v1/matches/{id}/review` returns every question with its explanation and bookmark
  state.
- **Settlement.** `match.settled` arrives, to each player separately, after the server commits the
  result. The result screen shows "Results syncing…" until then. The client reads
  `GET /v1/matches/{id}`, which has the same numbers, when:
  - it hasn't arrived 20 s after `match.end`;
  - the connection dropped while it was waiting;
  - a snapshot says `"settled": true` and it has no settlement yet.
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
| `room.state` | The whole lobby: `{"room_id", "kind", "code", "host", "status": "lobby" \| "playing" \| "finished", "locked", "settings", "members": [card + `ready`, `connected`, `away`, `role`], "rematch": {"offered_by", "until"} \| null}`. Sent on join and after every change. `away` means the member's app is in the background |
| `room.started` | `{"match_id", "ch": "m:<id>"}` |
| `room.kicked` | `{"room_id"}` (to the kicked player) |
| `room.closed` | `{"room_id", "reason": "host_ended" \| "idle" \| "host_left" \| "empty"}` |

- **Settings.** Friend duels are always unrated and free. Settings are subject, chapter or All,
  question count and seconds per question. Group battles add difficulty, late join, the
  leaderboard between questions, and who can join. The `settings` object (in `POST /v1/rooms`,
  `room.settings` and `room.state`) is:

  ```json
  {"subject": "physics", "chapters": ["kinematics"], "questions": 7, "seconds": 15,
   "difficulty": "mixed", "late_join": "halfway", "leaderboard": true, "join": "code"}
  ```

  - `chapters: []` means All chapters; a duel has at most one. The app also reads a single
    `chapter` string.
  - `questions`: 5, 7 or 10 for a duel (default 7); 5, 10, 15 or 20 for a group (default 10).
    `seconds`: 10, 15, 20 or 30 (default 15).
  - Group only: `difficulty` is `mixed` (default), `easy`, `medium` or `hard`; `late_join` is
    `off` or `halfway` (default); `leaderboard` defaults to `true`; `join` is `friends` or
    `code` (anyone with the code, the default).
  - `room.settings` may send only the fields that change.
- **More in `room.state`.** `match_id` is the game in progress while `status` is `playing` (and
  the last one while `finished`), so a member who rejoins or joins late follows it on
  `m:<match_id>`. `capacity` is 2 for a duel and 8 for a group. `rematch.accepted` lists the uids
  who said yes so far.
- **Joining.** `room.join` is answered with the room's `room.state` (no separate `ack`); a room
  the user is already in answers the same way.
- **Room rematch.** After a game `status` is `finished`. `room.rematch {accept: true}` offers or
  accepts playing again with the same settings; `rematch` is `{offered_by, until, accepted}`
  (30 s for a duel, 3 minutes for a group). When every connected member has accepted, the
  server starts the next game (`room.started`); `accept: false` turns it down (`rematch: null`).
- **Late join and spectating.** A group member who joins after the halfway point gets a
  `match.snapshot` whose `players` don't include them: the app shows the game as a spectator.
- **Codes.** Codes use Crockford base32 and work for as long as the room exists.
- **Lobby lifetime.** A host who switches apps to share the link keeps the room:
  - A lobby closes only on `room.end`, when everyone leaves, or after 15 minutes without activity.
  - Members see "Waiting for Aarav to come back" while the host is away.
  - The host gets a notification when someone joins.
  - During a game, the usual grace rules apply instead.
- **Code guesses.** Wrong codes are rate-limited per user (5 a minute, 30 an hour).

**Details settled in the implementation**
- **Replies.** Every `room.*` request is answered with `ack {"ref", "room_id"}` or an `error`.
  `room.join` errors: `NOT_FOUND` (no such code; wrong codes count toward the guess limit),
  `RATE_LIMITED`, `NOT_ALLOWED` with `details.reason` (`kicked`, `locked`, `full`, `blocked`,
  `friends_only`, `started`), and `BUSY` with `details.active`. The host is a member from
  `POST /v1/rooms` on; their `room.join` (by `room_id`) only subscribes.
- **`room.state`** also carries `capacity` (2 or 8) and `match_id` (the current or last game),
  and each member `joined_at`. `role` is `host`, `player` or `spectator`. `settings` is
  `{"subject", "chapters": [slug] | null (All), "questions", "seconds", "difficulty": "mixed" |
  "easy" | "medium" | "hard", "late_join", "leaderboard", "join": "friends" | "anyone"}` for both
  kinds (a friend duel has at most one chapter, and fixed values for the group-only fields).
- **Starting.** `room.start` needs at least 2 connected players (spectators don't count); every
  connected member plays. A friend duel also starts by itself 3 s after both players are ready
  and connected. `room.started` is followed on `m:` by the usual `match.snapshot`, and players
  send `match.ready`; a group battle starts once every connected player is ready, or at the
  ready deadline with whoever is (at least 2).
- **Between games** the room's `status` is `finished`. A friend duel offers a rematch for 30 s
  (`rematch {"offered_by", "until"}`; `room.rematch {accept: true}` from both starts the next
  game at once, `accept: false` goes back to the lobby; at most 10 rematches per room), then
  returns to `lobby`. A group room keeps **Play again** open for 3 minutes (`rematch.until`;
  `room.rematch` marks the member ready, and the host starts); after that it closes (`idle`).
  Settings can be changed in `lobby` and `finished`.
- **The host.** A group host who leaves, or is disconnected for 20 s, hands over to the
  earliest-joined connected player. A friend duel has no handover: its lobby closes
  (`host_left`) when the host leaves, or has been disconnected for 60 s while their friend waits.
  A backgrounded host (`away`) with a live socket never loses the room.
- **During a game.** `room.leave` (or `match.forfeit`) in a friend duel forfeits; in a group
  battle the player shows as `left` (`opp.conn {state: "left"}`), scores 0 from then on, and can
  come back with `room.join`. A dropped group player gets `opp.conn {state: "reconnecting",
  grace_until: null}` and never forfeits; with fewer than 2 players connected for 30 s the game
  ends on the current scores (`disconnected`, or `left` if someone left). A late joiner (group,
  late join on, up to question `total / 2`) gets `player.joined {"player": card, "joined_q"}` sent
  to everyone and plays from `joined_q`; later joiners become spectators, who follow `m:` but
  can't answer. `room.end` during a group game ends it with `ended_by_host`; during a friend duel
  it counts as the host forfeiting. Either way the room then closes (`host_ended`).
- **Kicks** are at most 5 a minute per host; `room.kicked` goes to the kicked player alone (on
  `u`'s socket with `ch: "r:<id>"`, no `seq`).
- **The host hears about joins** through an `invite` inbox item ("Riya joined your room", pushed
  even in quiet hours, since it's their own room) besides `room.state`.
- **Busy slots.** A member's busy slot is the room (`BUSY` kind `room`, title "Play with Friend"
  or "Group Battle"); during a game it is the match, and it goes back to the room when the game
  ends. `welcome.active` lists the room (`{"kind": "room", "id", "ch": "r:<id>", "state"}`), and
  both the match and its room during a room game.
- **From matchmaking.** `mm.respond {choice: "invite"}` ends the search and creates a friend
  lobby in the same subject and chapter; the `ack` carries `{"room_id", "code", "link",
  "expires_at"}` and `room.state` follows.
- **Invites** are created over REST (`docs/api-play.md`) and delivered live on `u`:
  - `invite.received {"invite_id", "from": card, "kind", "room_id", "subject", "expires_at"}`
    shows a banner with Accept/Decline on any screen.
  - `invite.updated {"invite_id", "status": "accepted" \| "declined" \| "expired" \| "cancelled"}`
    goes to both sides.

## 9. Tournaments

- `sub {"ch": "t:<id>"}` starts standings updates, and `unsub` stops them. The server answers
  `sub` with the current `t.standings`, then sends updates at most every 2 s.
- `t.standings {"round": 3, "rows": [{"rank", "uid", "name", "points", "bh_c1", …}], "me": {…}}`.
- `t.round {"round": 3, "status": "pairing" \| "live" \| "done", "starts_at", "ends_at"}`.
- **Your own events on `u`:**

  | Type | When |
  |---|---|
  | `t.check_in {"tournament_id", "title", "starts_at", "closes_at"}` | The check-in window opened. The app shows **Check in** and **Can't make it** (withdraw with a full refund). Check-in is always a deliberate tap, on the banner, the notification or the tournament screen, never automatic |
  | `t.at_risk {"tournament_id", "players", "needed"}` | 30 minutes before the start, if too few players have registered: "3 more players needed. Invite friends" |
  | `t.checked_in {"tournament_id"}` | You are checked in |
  | `t.pairing {"tournament_id", "round", "match_id", "ch": "m:<id>", "opponent": {…}, "ready_by": <ms>}` | Your game for this round. You have 90 s to send `match.ready`; the app shows a full-screen "Join" wherever the user is |
  | `t.bye {"tournament_id", "round", "points": 1}` | You have a bye this round |
  | `t.finished {"tournament_id", "rank", "players", "points", "prize": 120, "xp": 50}` | Final result. Also kept in the inbox |
  | `t.cancelled {"tournament_id", "reason": "not_enough_players" \| "admin", "refunded": 15}` | The tournament was cancelled; fees are refunded |

## 9a. Inbox updates

`notify {"id", "kind", "title", "body", "action", "unread": 4}` on `u` delivers every new inbox item
live, so the bell badge updates at once. The full inbox is REST (`docs/api-play.md`).

## 10. Resuming after a reconnect

- **Resuming.** `hello.resume` lists the resumable channels the client was on, with the last
  `seq` it processed. For each one, the server either:
  - **replays** every event with a higher `seq`, if they are still in the channel's log (about the
    last 300 events); or
  - sends a **snapshot** (`match.snapshot` or `room.state`, whose `seq` is the channel's current
    `seq`).
- **Gaps and duplicates.** The client ignores events with `seq ≤` the last one it applied. A gap
  (`seq > last + 1`) triggers `sync`. A snapshot older than the last applied `seq` is ignored.
- **`sync` replies.** There is no `ack`: the reply is the replay or a snapshot. `last_seq: 0`
  always gets a snapshot. A channel the user can no longer see gets
  `error {"ref", "code": "NOT_FOUND"}`, and the client stops tracking it.
- **Answers in flight.** Unacknowledged `ans.submit` frames are resent after reconnecting, with
  the same `id`. The server's answer is idempotent per player and question: a repeat gets the
  first status again, with `dup: true`.
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
