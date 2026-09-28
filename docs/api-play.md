# REST API: home, battles, arena, leaderboards, social, inbox and wallet (v1)

This file covers everything outside Learn/practice (see `docs/api-learn.md`). Live gameplay runs over
the WebSocket described in `docs/protocol.md`; these endpoints set up games, show results and history,
and power leaderboards and the rest of the app. The journeys that use them are in
`docs/user-flows.md`.

Conventions are the same as `docs/api-learn.md`:
- Every request needs `Authorization: Bearer`.
- Errors use the standard envelope.
- Lists use cursors: `?cursor=&limit=` → `{"items", "next_cursor"}`.
- Times are ISO 8601 UTC. Durations are in milliseconds.
- Any POST that moves coins or creates something takes an `Idempotency-Key`.

**Shared shapes**

```json
// user card: anywhere another player is shown
{"id": "…", "handle": "rahul_07", "display_name": "Rahul", "avatar": {"tone": "sky", "symbol": "atom"}, "level": 7}

// rating: "—" before any rated game, "1523?" while provisional, "1523" once settled
{"display": "1523?", "value": 1523, "provisional": true}

// leaderboard row
{"position": 42, "user": {…user card…}, "value": 1523, "value_display": "1523", "change_1d": 5}

// action: where tapping something should take the app
{"route": "/battle", "params": {"subject": "physics"}}
```

## Startup

`GET /v1/config` (no auth, already live) returns:

```json
{"min_build": 12, "maintenance": false, "maintenance_message": null, "maintenance_at": null, "maintenance_until": null, "features": {"tournaments": true}, "server_time": "2026-09-27T16:00:00Z"}
```

- `min_build`: the app shows Update required when its build is lower.
- **The build header.** Every request carries `X-App-Build`. Below `min_build`, requests get `426
  UPDATE_REQUIRED`. These paths are exempt: `/v1/config`, `/v1/auth/*`, the health checks and
  `/v1/matches/*`, so a game in progress can finish.
- **Gates wait for live play.** The app shows the update or maintenance gate only after the
  current match or tournament round ends.
- `maintenance`: the app shows the Maintenance screen with `maintenance_message`. All other paths
  return `503 MAINTENANCE`.
- **Planned maintenance.** `maintenance_at` and `maintenance_until`:
  - Home shows a banner from 2 h before the start.
  - New searches and rooms are refused from 10 min before; running matches finish.
  - Tournaments that overlap the window are cancelled and refunded before check-in, with an inbox
    note.
- Maintenance settings live in the database (`app_config`), so they change without a redeploy.

## Home

`GET /v1/home` returns every Home section. Each section carries its own status, so one failure
never blanks the screen.

```json
{
  "hero": {"status": "ok", "data": {
    "rating": {"display": "1523?", "value": 1523, "provisional": true},
    "rank": {"board": "rating:overall", "position": null, "games_to_rank": 7},
    "coins": 245,
    "level": {"level": 4, "into_level": 120, "for_next": 250}
  }},
  "live": {"status": "ok", "data": {"kind": "tournament", "id": "…", "title": "Physics Sunday Cup", "state": "check_in", "until": "…", "action": {"route": "/arena/…"}}},
  "continue": {"status": "ok", "data": null},
  "tip": {"status": "ok", "data": {"key": "…", "message": "…", "action": "practice", "params": {}}},
  "missions": {"status": "ok", "data": {
    "day": "2026-09-27",
    "items": [{"id": "…", "title": "Answer 20 practice questions", "progress": 12, "target": 20, "xp": 20, "done": false, "action": {"route": "/learn"}}],
    "bonus": {"xp": 100, "coins": 25, "done": false},
    "streak": {"days": 4, "today_done": false, "freezes": 1}
  }},
  "leaders": {"status": "ok", "data": {"board": "weekly_xp", "top": [/* 3 rows */], "me": {/* row, or null */}}},
  "tournament": {"status": "ok", "data": {/* tournament card, or null */}},
  "welcome": {"coins": 100}
}
```

- **Section status.** A failed section is `{"status": "error", "error": {"code", "message"}}`.
- **`welcome`** appears once, on the first Home after onboarding. It is `null` afterwards.
- **`live`** is anything that needs the user's attention now: a search, a match, a room, or a
  tournament that is checking in or running.

## Battle setup

`GET /v1/battle/setup?goal=neet` returns everything the Battle tab needs in one call:

```json
{
  "subjects": [
    {"slug": "physics", "name": "Physics", "tone": "sky",
     "rating": {"display": "—", "value": null, "provisional": true},
     "chapters": [{"slug": "kinematics", "name": "Motion in a Straight Line", "battle_ready": true, "question_count": 8, "label": "needs_work"}]}
  ],
  "coins": 245,
  "casual_fee": 5,
  "cooldown_until": null,
  "active": null,
  "last": {"subject": "physics", "chapter": null, "mode": "rated"},
  "online": {"physics": {"searching": 3, "p50_wait_s": 20}},
  "first_search": true,
  "leaders": {"physics": {"leader": {/* row */}, "me": {"position": 12}}}
}
```

- `online` lets the tab say "3 players searching · usually 20 s".
- `first_search` makes the Practice Bot offer appear at 20 s instead of 45 s.
- `leaders` shows "Physics this week: Riya leads · you're #12" for the selected subject.
- A Practice Bot game can be started straight from the tab (`mm.join {mode: "bot"}`).

`active` is `{"kind": "queue" | "match" | "room" | "tournament", "id", "title", "action"}` when the
user is already busy. The app then shows **Go there** instead of Find opponent.

## Realtime tickets

`POST /v1/rt/tickets` returns `{"ticket": "…", "expires_in": 30}`. It is rate-limited to 20 a
minute per user. See `docs/protocol.md` §1.

## Matches: results, history and review

| Endpoint | Returns |
|---|---|
| `GET /v1/me/matches?kind=&cursor=` | History, newest first: `{"id", "kind", "subject", "chapters": [names], "played_at", "result": "win" \| "loss" \| "draw" \| "aborted" \| "voided", "reason", "score": {"me", "best_other"}, "opponents": [cards], "rating_delta", "coins_delta", "place"}`. `place` is set for group battles |
| `GET /v1/matches/{id}` | The summary above, plus `"status": "live" \| "settling" \| "settled" \| "aborted" \| "voided"`, final totals and ranking, and `settlement` (the same fields as `match.settled`, or null while settling). 404 unless you took part |
| `GET /v1/matches/{id}/review` | Available once the match has ended. `{"questions": [{"q", "ref", "stem", "options": [{"id", "text"}], "correct", "explanation", "chapter", "topic", "players": {"<uid>": {"opt", "correct", "pts", "time_ms", "speed"}}, "bookmarked"}]}` |

## Rooms and invites (Play with Friend, Group Battle)

| Endpoint | Does |
|---|---|
| `POST /v1/rooms` | Body `{"kind": "friend" \| "group", "settings": {…}}` → `{"room_id", "code", "link", "expires_at"}`. Then `room.join` over the WebSocket. Needs an Idempotency-Key |
| `GET /v1/rooms/code/{code}` | Preview before joining: `{"room_id", "kind", "host": card, "subject", "chapters", "questions", "seconds", "members": 3, "capacity": 8, "joinable": true, "reason": null}`. `reason` is set when you can't join: `locked`, `full`, `started`, `blocked` or `friends_only`. Wrong codes are rate-limited (5 a minute, 30 an hour); an unknown or expired code gives `404 ROOM_NOT_FOUND` |
| `POST /v1/invites` | Body `{"to_user_id", "room_id"}` → `{"invite_id", "expires_at"}` (2 min). Errors: `BUSY` (the friend is busy, with the reason), `NOT_ALLOWED` (their privacy settings or a block), and 429 |
| `GET /v1/me/invites` | `{"incoming": [...], "outgoing": [...]}`, pending only: `{"invite_id", "from" or "to": card, "room_id", "kind", "subject", "expires_at"}` |
| `POST /v1/invites/{id}/accept` | Returns `{"room_id", "code"}`; the app then sends `room.join`. Returns `410 INVITE_EXPIRED` if it has expired, and `409 BUSY` if you're busy |
| `POST /v1/invites/{id}/decline` | `204`. The sender gets `invite.updated {status: "declined"}` |
| `DELETE /v1/invites/{id}` | `204`. The sender cancels |

Invite changes also arrive live on the `u` channel (`invite.received` and `invite.updated`,
`docs/protocol.md` §8) and in the Inbox.

- **Room settings** (`settings` in the body): `{"subject", "chapter" or "chapters", "questions",
  "seconds", "difficulty", "late_join", "leaderboard", "join"}`; anything left out takes the
  default. Friend duels: one chapter or All, 5/**7**/10 questions, 10/**15**/20/30 s. Group
  battles: up to 12 chapters or All, 5/**10**/15/20 questions, the same times, difficulty
  `mixed` (the rating mix) or one band, late join (default on, until halfway), leaderboard
  between questions (default on) and `join` `friends` (friends of the host, or anyone whose invite
  was accepted) or `anyone` (default). Chapters must be battle-ready. Bad values give `422` with
  `details.fields`. `expires_at` is when an idle lobby would close (15 minutes; any activity
  extends it). `409 BUSY` also covers a registered tournament the player is needed for before
  the room's longest game could end; `503 UNAVAILABLE` during (and 10 minutes before) planned
  maintenance. At most 10 rooms a minute per user.
- **Previews** also give `reason: "kicked"`. The code is read forgivingly (case, spaces and
  hyphens are ignored; O reads as 0, I and L as 1). Once over the guess limit, every lookup gets
  `429` until the limit has passed.
- **Invites**: `403 NOT_ALLOWED` with `details.reason` `not_friends`, `privacy` (their
  `challenges` setting, or a block) or `full`; `409 ALREADY_IN_ROOM`; at most 15 per 5 minutes.
  Only room members can invite. Inviting the same friend to the same room again while pending
  returns the pending invite. `POST /v1/invites/{id}/accept` on an invite already accepted returns
  the room again. A room that closes expires its pending invites (`invite.updated` to both).
  Blocking cancels pending invites between the two.
- **Room links**: `GET /j/{code}` (no `/v1`, no sign-in) is a small HTML page with the code, an
  **Open app** Android intent link and the Play Store listing
  (`APP_ANDROID_PACKAGE`) with `referrer=room_code%3D<CODE>` for the install referrer. It never
  says whether the code is live.

## Leaderboards: who is leading where

### `GET /v1/leaderboards?goal=neet`
The leaderboard hub, with one card per board. `goal` filters players by exam; omit it for
everyone.

```json
{
  "boards": [
    {"board": "weekly_xp", "title": "This week", "ends_at": "2026-09-28T18:30:00Z", "leader": {/* row */}, "me": {"position": 318, "value": 140, "change_1d": 25}},
    {"board": "rating:overall", "title": "Overall rating", "leader": {/* row */}, "me": {"position": null, "games_to_rank": 7}},
    {"board": "rating:physics", "title": "Physics", "leader": {/* row */}, "me": {"position": 42, "value": 1523, "change_1d": 5}},
    {"board": "friends:weekly_xp", "title": "Friends this week", "leader": {/* row */}, "me": {"position": 2, "value": 140}}
  ],
  "last_week": [/* the top 3 rows of last week's weekly_xp */]
}
```

### `GET /v1/leaderboards/{board}?goal=&cursor=&limit=`

```json
{"board": "rating:physics", "title": "Physics", "period": null,
 "items": [/* rows, 50 per page, top 100 in all */], "next_cursor": "…",
 "me": {/* your row, or null */}, "around_me": [/* up to 10 rows above and 10 below you */],
 "not_ranked": {"games_to_rank": 7},
 "players": 412, "ends_at": "2026-09-28T18:30:00Z"}
```

- `players` is how many players the board holds under the `goal` filter. The app uses it for "Be
  one of the first on this board" (under 10) and for percentiles (50 or more). Without it, the app
  counts the rows once the last page is in.
- `ends_at` is set on weekly boards (as on the hub cards) for "Ends in 2 d 4 h".
- `not_ranked` is `null` when `me` is set. On `weekly:{subject}` boards `games_to_rank` is 1
  until the first game in the subject.
- `change_1d` is positive when the player moved **up** (places gained) and negative when they
  moved down; `null` when there is no snapshot from yesterday.

**Boards**

| Board | Ranks by | Resets | Eligible |
|---|---|---|---|
| `weekly_xp` | XP this IST week, excluding Practice Bot XP | Monday 00:00 IST | Anyone with XP this week |
| `weekly:{subject}` | **Battle points** this week from games against people (rated, casual, tournament) in that subject | Weekly | After 1 game in the subject |
| `weekly_xp:last`, `weekly:{subject}:last` | Last week's final standings | Kept for a week | The same |
| `rating:overall` | Overall rating | Never | At least 10 rated games and RD ≤ 110 |
| `rating:{subject}` | Subject rating | Never | The same, per subject |
| `friends:weekly_xp`, `friends:rating` | You and your friends | Weekly / never | You and your friends |
| `hall_of_fame:{subject}` | The last 10 tournament winners | Rolling | Tournament winners |

`weekly:{subject}` answers "who is leading Physics this week?". Bots can't farm it, and every
Monday gives everyone a fresh start.

**Rules**
- **Exam filter.** Boards default to the viewer's own exam (NEET or JEE), with an "All India"
  toggle. NEET views never show Maths, and JEE views never show Biology.
- **Ties** go to whoever reached the value first.
- **Integrity:**
  - Practice Bot XP (itself capped at 60 a day) never counts.
  - Casual XP counts from at most 3 games per pair of players per 24 h.
  - Banned players, players pending deletion and players under an anti-cheat review never appear.
- **Stale ratings.** Ratings of idle players grow more uncertain every night. A player whose RD
  rises above 110 leaves the rating boards until they play again.
- **Minors** can opt out of public boards (privacy settings). Non-friends see only their name,
  avatar and level.
- **Few players:**
  - a board filtered below 10 players says "Be one of the first on this board" and offers All
    India;
  - empty subject boards are hidden;
  - percentiles appear only on boards with 50 or more players.
- **Change figures:** `change_1d` is the position change since the previous day's snapshot.
- **Moving into the top 100, 10 or 3** of any board creates an inbox item. Each weekly #1 per
  subject and exam earns a "Physics Champion · Week 39" badge.
- **Hub header.** The hub starts with the viewer's own positions ("#42 Physics · #310 this week ·
  Overall: 3 more rated games"). Weekly cards show "Ends in 2 d 4 h".

## Tournaments

| Endpoint | Returns or does |
|---|---|
| `GET /v1/tournaments?status=open\|upcoming\|live\|finished&goal=&cursor=` | Cards: `{"id", "title", "goal": "neet" \| "jee" \| "any", "subject", "tone", "status", "reg_opens_at", "checkin_opens_at", "starts_at", "ends_at_estimate", "rounds", "entry_fee", "prize_pool", "effective_pool", "players", "min_players", "capacity", "me": {"registered", "checked_in", "withdrawn"} \| null}`. The app shows "5 of 8 needed" and "Prize now 625 of 2,500 · grows with players" |
| `GET /v1/me/tournaments?cursor=` | Your upcoming, live and past tournaments. Past ones add `final_rank`, `players` and `prize` |
| `GET /v1/tournaments/{id}` | Detail: rules, the round schedule, the prize table for the current player count, `status`, `current_round`, and `me` (registered, checked in, record, points, rank, next pairing) |
| `POST /v1/tournaments/{id}/register` | Holds the entry fee. Needs an Idempotency-Key. Errors: `TOURNAMENT_FULL`, `REGISTRATION_CLOSED`, `INSUFFICIENT_COINS`, `SCHEDULE_CONFLICT` (overlaps another tournament you entered), and `NOT_ALLOWED` with `reason`: `no_shows` (paid registration blocked for 7 days after 3 no-shows) or `exam` (the tournament is for the other exam) |
| `DELETE /v1/tournaments/{id}/register` | Withdraw. Before the start, the fee is fully refunded. After the start, you stay in the standings for tie-breaks, can't win a prize, and get no refund |
| `POST /v1/tournaments/{id}/check-in` | Allowed from 15 min to 2 min before the start. Always a deliberate tap, from the banner, the notification or the tournament screen. The same banner offers **Can't make it**, a withdraw with a full refund. Errors: `CHECK_IN_CLOSED` and `NOT_REGISTERED` |
| `GET /v1/tournaments/{id}/standings?cursor=` | Rows: `{"position", "user", "points", "w", "d", "l", "bh_c1", "bh", "sb", "withdrawn"}`, plus `me` |
| `GET /v1/tournaments/{id}/me` | Your games by round: opponent, result, points, `match_id` (or a bye), and the current pairing |

**Rules for players who are registered or checked in:**
- A quick battle or room that could still be running 2 minutes before the start (its longest
  possible length crosses that time) returns `BUSY`, with the tournament in `details.active`.
- **Reminders don't need push.** At registration the app schedules **local notifications** on the
  device for 1 h and 15 min before the start and for the start itself. It also offers "Add to
  calendar".
- **At risk.** 30 min before the start, if too few players are registered, registrants get an
  "At risk: 3 more players needed" inbox item. A tournament cancelled for too few players refunds
  everyone and sends an inbox item.
- **Rounds.** The number of rounds never exceeds the field: min(configured, players − 1,
  ⌈log₂ players⌉ + 2).
- **Exam.** A tournament's `goal` is `neet`, `jee` or `any`. `any` is only allowed for subjects
  both exams share (Physics, Chemistry).

**Payload shapes the app reads.** The table above names the fields; these are the full shapes the
mobile app parses (unknown fields are ignored, and fields marked optional may be absent):

```json
// card (GET /v1/tournaments items, and the top level of the detail); status is
// scheduled | reg_open | check_in | locked | running | finalizing | finished | cancelled
{"id": "…", "title": "Physics Sunday Cup", "goal": "neet", "subject": "physics" /* null = all */,
 "tone": "sky", "status": "reg_open", "reg_opens_at": "…", "checkin_opens_at": "…",
 "starts_at": "2026-10-04T12:30:00Z", "ends_at_estimate": "…", "rounds": 5, "entry_fee": 25,
 "prize_pool": 2500, "effective_pool": 390, "players": 5, "min_players": 8, "capacity": 64,
 "me": {"registered": true, "checked_in": false, "withdrawn": false} /* null if never registered */}

// GET /v1/tournaments/{id}: the card plus
{"description": "…",
 "rules": {"questions": 10, "seconds_per_question": 15, "rated": true, "ready_s": 90,
           "draw_points": 0.5, "bye_points": 1},
 "schedule": [{"round": 1, "starts_at": "…", "status": "upcoming | pairing | live | done"}],
 "prizes": [{"from": 1, "to": 1, "coins": 195}, {"from": 6, "to": 10, "coins": 18}],
 "current_round": 2 /* null before the start */,
 "me": {"registered", "checked_in", "withdrawn",
        "record": {"wins": 1, "draws": 0, "losses": 0}, "points": 1, "rank": 4,
        "next_pairing": {"round": 2, "opponent": {…user card…} | null, "bye": false,
                         "match_id": "…" | null, "ready_by": "…" | null} | null,
        "final": {"rank": 3, "players": 24, "points": 3.5, "prize": 120, "xp": 50} | null} | null}

// POST /v1/tournaments/{id}/register and POST /v1/tournaments/{id}/check-in answer the updated card.
// DELETE /v1/tournaments/{id}/register answers:
{"tournament": {…card…}, "refunded": 25 /* 0 after the start */}

// GET /v1/tournaments/{id}/standings?cursor=
{"items": [{"position": 1, "user": {…user card…}, "points": 3, "w": 3, "d": 0, "l": 0,
            "bh_c1": 5, "bh": 6, "sb": 4, "withdrawn": false}],
 "next_cursor": "…" | null, "me": {…row…} | null, "round": 3}

// GET /v1/tournaments/{id}/me
{"rounds": [{"round": 1, "opponent": {…user card…} | null, "bye": false,
             "result": "win | draw | loss" | null /* null while playing */, "points": 1,
             "match_id": "…" | null, "no_show": false}],
 "current": {…next_pairing shape…} | null, "record": {…}, "points": 1, "rank": 4}

// GET /v1/me/tournaments?cursor= items: the card, plus once it's over
{…card…, "final_rank": 3, "prize": 120, "xp": 50, "points": 3.5}
```

- **Errors.** `TOURNAMENT_FULL`, `REGISTRATION_CLOSED`, `INSUFFICIENT_COINS` (`details.needed`),
  `SCHEDULE_CONFLICT` (`details.id`, `details.title` of the other tournament), `CHECK_IN_CLOSED`
  and `NOT_REGISTERED` are `409`; `NOT_ALLOWED` is `403` with `details.reason`. The app reads the
  code, not the status, so either works.
- **`welcome.active`** lists a running tournament the player is in as
  `{"kind": "tournament", "id", "title"}`; the app shows the "Tournament live" pill from it.
- **`t.standings` rows** carry `rank`, `uid`, `name`, `points` and, when sent, `avatar`, `w`,
  `d`, `l` and `bh_c1`.
- **Links.** `/arena/<id>` (optionally `?tab=standings|games`, and `?round=` opens My games) is a
  tournament; `/arena/<id>/results` its final results; `/arena?t=<id>` and `/t/<id>` lead to the
  tournament; `/arena?filter=live,upcoming` is "Browse live contests".

## Profiles and stats

| Endpoint | Returns |
|---|---|
| `GET /v1/users/{handle}` | The public profile: card, level, `ratings: [{"scope", "rating", "position"}]`, form (last 5 results), `h2h` with you, `relationship` (`none`, `friend`, `requested` or `blocked`), `can_challenge`, `friend_request` (`{"id", "direction": "incoming" \| "outgoing"}` while one is pending, else `null`) and `limited`. A minor seen by a non-friend is `limited`: only the card, with `ratings` and `form` empty and `h2h` null. `404 USER_NOT_FOUND` when blocked in either direction, or for a deleted account |
| `GET /v1/me/stats` | Ratings per scope with position; W/D/L per mode; accuracy; questions answered; best and current streak; `rating_history: [{"at", "value"}]` for `?range=30d\|90d\|all` |

`GET /v1/me/stats?range=30d` in full (the Profile reads this shape):

```json
{
  "level": {"level": 4, "into_level": 120, "for_next": 250},
  "ratings": [{"scope": "overall", "name": "Overall", "rating": {"display": "1523", "value": 1523, "provisional": false}, "position": 214},
              {"scope": "physics", "name": "Physics", "rating": {"display": "1548?", "value": 1548, "provisional": true}, "position": null}],
  "record": {"rated": {"wins": 12, "draws": 2, "losses": 9}, "casual": {"wins": 3, "draws": 0, "losses": 2}, "bot": {…}, "friend": {…}, "group": {…}, "tournament": {…}},
  "accuracy": 0.68,
  "questions_answered": 1240,
  "streak": {"current": 4, "best": 11},
  "rating_history": [{"at": "2026-09-01T00:00:00Z", "value": 1500}]
}
```

- `level` is the same object as Home's `hero.level`; the Profile header draws the XP bar from it.
- `position` is null while unranked (provisional). `name` is optional; the app derives it from
  `scope`.
- `accuracy` is a fraction from 0 to 1, or null before any answer.
- `rating_history` is the overall rating over `range`, oldest first. Only it depends on `range`.

`GET /v1/me/opponents?days=30` returns `{"items": [{"user": {…user card…}, "h2h": {"wins", "draws",
"losses"}, "relationship", "last_played_at"}]}`.

## Wallet and XP

| Endpoint | Returns |
|---|---|
| `GET /v1/me/wallet` | `{"balance", "held", "recent": [/* 5 transactions */]}` |
| `GET /v1/me/wallet/transactions?cursor=` | `{"id", "delta", "balance_after", "reason", "title", "ref": {"kind": "match" \| "tournament" \| "mission" \| "streak" \| "achievement" \| "hint" \| "welcome" \| "level", "id"}, "created_at"}` |

Example titles: "Casual battle entry", "Casual battle won", "Refund: match cancelled", "Tournament
prize: #3 in Physics Sunday Cup", "Daily missions bonus".

A Casual entry is taken when the search starts, before any match exists, so the entry (and its
refund if the search ends without a match) carries `ref: {"kind": "match", "id": "mm:<ticket>"}`;
the pot, rated rewards and refunds of a match carry the match id. Rated games pay 10 / 4 / 1
coins for a win, draw or loss, at most 150 a day (IST); `match.settled.coins.capped` says when
the cap cut a reward.

## Missions, streaks and achievements

| Endpoint | Returns or does |
|---|---|
| `GET /v1/me/missions` | The same shape as Home's `missions`, plus `"swaps_left": 1` (free swaps left today). Rewards are credited automatically |
| `POST /v1/me/missions/{id}/swap` | One free swap a day, for a different mission. Returns the whole updated `GET /v1/me/missions` body. Errors: `409 SWAP_USED` (today's swap is gone) and `409 MISSION_DONE` |
| `POST /v1/me/streak/freezes` | Buy a streak freeze (50 coins, hold at most 2). Needs an Idempotency-Key. Returns `{"freezes": 2, "coins": 195}` (freezes held and the balance after paying). Errors: `409 INSUFFICIENT_COINS` and `409 LIMIT_REACHED` (already holding 2) |
| `GET /v1/me/streak?days=30` | A calendar of active days, and the freezes used (below) |
| `GET /v1/me/achievements` | Earned achievements and progress on the others (below) |

```json
// GET /v1/me/streak?days=30: the calendar is oldest first and ends today (IST days)
{"days": 4, "best": 12, "freezes": 1, "today_done": false,
 "max_freezes": 2, "freeze_price": 50, "coins": 245,
 "calendar": [{"day": "2026-08-29", "state": "active"}, {"day": "2026-09-26", "state": "frozen"}, {"day": "2026-09-27", "state": "missed"}]}

// GET /v1/me/achievements
{"items": [{"id": "streak-7", "title": "On fire", "description": "Keep a 7-day streak.", "icon": "fire",
            "earned_at": "2026-09-24T10:00:00Z", "progress": 7, "target": 7, "coins": 30},
           {"id": "wins-10", "title": "Ten wins", "description": "Win 10 rated battles.", "icon": "medal",
            "earned_at": null, "progress": 3, "target": 10, "coins": 50}]}
```

- `state` is `active` (the day counted), `frozen` (a freeze saved it) or `missed`. Today is
  `missed` until it counts.
- `max_freezes`, `freeze_price` and `coins` are optional (the app assumes 2 and 50). With `coins`,
  the app says "Not enough coins" before asking to buy.
- `icon` names one of: `fire`, `medal`, `crown`, `star`, `battle`, `arena`, `quiz`, `target`,
  `flash`, `shield`, `brain`, `rocket`, `learn`, `sparkles`, `coins`, `social`, `calendar`. Unknown
  names show a generic award.

Missions are written so they can always be done:
- "Play 1 rated battle or tournament game", never "win".
- A brand-new player's review mission becomes "10 questions in any chapter".

**Missions.** `GET /v1/me/missions` (and Home's `missions.data`) returns:

```json
{"day": "2026-09-28",
 "items": [{"id": "…", "slot": "practice", "title": "Answer 20 practice questions", "progress": 12, "target": 20, "xp": 20, "done": false, "swapped": false, "action": {"route": "/learn", "params": {}}}],
 "bonus": {"xp": 100, "coins": 25, "done": false},
 "swap_available": true,
 "streak": {"days": 4, "today_done": false, "freezes": 1}}
```

- Items come in slot order: `practice`, `play`, `review`. Practice missions count answers given
  (not skips or timeouts); the review mission counts answers in review sessions; the chapter
  fallbacks count answers in that chapter (or any chapter).
- `action` routes: `/learn`, `/learn` with `{"mode": "review"}`, `/learn/{subject}` with
  `{"chapter"}`, `/battle` with `{"mode": "rated"}`, or `/battle`.
- **Swap** returns the same shape. Errors: `404 MISSION_NOT_FOUND` (not one of today's),
  `409 SWAP_USED`, `409 MISSION_DONE`, `409 NO_SWAP`. The play mission swaps to "Finish 1 battle
  of any kind"; progress starts again.

**Streak.** `GET /v1/me/streak?days=30` (1–90) and `POST /v1/me/streak/freezes` return:

```json
{"days": 4, "best": 9, "today_done": false, "freezes": 1, "max_freezes": 2, "freeze_price": 50,
 "calendar": [{"day": "2026-09-27", "state": "active"}, {"day": "2026-09-28", "state": null}],
 "freezes_used": ["2026-09-25"]}
```

- `calendar` runs oldest first up to today (IST); `state` is `active`, `frozen` or `null`.
- A day counts with 10 answers or 1 finished battle. Missed days use a held freeze
  automatically; without one the streak ends (`streak_freeze_used` / `streak_lost` in the inbox,
  sent by the nightly rollover or on the next visit). Players with a live streak who have done
  nothing by 19:00 IST get `streak_risk`.
- Day 7 pays 30 coins and day 30 pays 100. Buying a freeze: `409 FREEZE_LIMIT` when holding 2,
  `409 INSUFFICIENT_COINS`.

**Achievements.** `GET /v1/me/achievements` returns `{"earned", "total", "items": [{"id", "title",
"description", "icon", "coins", "progress", "target", "earned", "earned_at"}]}`, earned ones first
(newest first), then the rest in catalogue order. Each pays 10–200 coins once, with an
`achievement` inbox item.

## Inbox and push

| Endpoint | Does |
|---|---|
| `GET /v1/me/notifications?cursor=` | `{"id", "kind", "title", "body", "icon", "action", "created_at", "read"}`, newest first, kept for 90 days |
| `GET /v1/me/notifications/unread-count` | `{"count": 3}`. Live updates come as `notify` events on `u` |
| `POST /v1/me/notifications/read` | Body `{"ids": [...]}` or `{"all": true}` → `204` |
| `PUT /v1/me/push-token` | Body `{"token", "platform"}` → `204`. `DELETE` removes it (it is also removed on sign-out) |
| `GET /v1/me/settings/notifications` | `{"kinds": {"invites": true, "tournaments": true, "friends": true, "missions": true, "streaks": true}, "quiet_hours": {"start": "22:30", "end": "07:00"}}`. `quiet_hours` is `null` when off |
| `PUT /v1/me/settings/notifications` | Same body as the `GET`. `"quiet_hours": null` turns them off; leaving the field out keeps them |
| `GET /v1/me/settings/app` and `PUT` | `{"analytics": true}`: the analytics toggle (see "Client analytics events") |

**Kinds:**
- **Invites and friends:** `invite`, `friend_request`, `friend_accepted`.
- **Tournaments:** `tournament_reminder`, `tournament_check_in`, `tournament_round`,
  `tournament_at_risk`, `tournament_result`, `tournament_cancelled`, `tournament_withdrawn`.
- **Coins and matches:** `refund`, `prize`, `match_forfeit`, `match_aborted` (the cooldown
  strike), `match_settled` (settlement that arrived late).
- **Progress:** `mission_done`, `level_up`, `achievement`, `rank_milestone`, `weekly_result`
  (Monday recap), `streak_risk`, `streak_freeze_used`, `streak_lost`.
- **Other:** `question_report` (the outcome of a question you reported), `account`.

**Quiet hours.** From 22:30 to 07:00 IST, notifications go to the inbox only, without push, except
time-critical things the user started (their own tournament round or match). The hours are
adjustable in settings.

## Social

| Endpoint | Does |
|---|---|
| `GET /v1/me/friends?cursor=&limit=` | By name. Cards plus `presence` (`online`, `in_battle`, `in_tournament` or `offline`; `offline` unless the friend's `presence` setting is `friends`), `friends_since` and `can_challenge` |
| `GET /v1/users/search?q=` | At least 3 handle characters (a leading `@` is ignored); matches handles by prefix, exact match first, up to 20. Cards with `relationship`. Blocked (either way), deleted and suspended players never appear. Rate-limited |
| `POST /v1/friend-requests` | Body `{"user_id"}` → `201` `{"id", "user": card, "direction", "status", "created_at"}`. Asking again returns the pending request; asking someone who already asked you accepts theirs (`status: "accepted"`). Errors: `403 NOT_ALLOWED` with `details.reason` `nobody` or `played_with` (their privacy settings: minors only accept people they've played) or `restricted` (your account); `409 LIMIT_REACHED` with `details {"limit": "daily" \| "pending" \| "friends" \| "their_friends", "max"}` (20 a day by IST day, 100 pending, 500 friends); `409 ALREADY_FRIENDS`; `404 USER_NOT_FOUND` |
| `GET /v1/me/friend-requests` | `{"incoming": [...], "outgoing": [...]}`: pending requests, newest first, each `{"id", "user": card, "direction", "status", "created_at"}` |
| `POST /v1/friend-requests/{id}/accept` and `/decline` | Accept or decline a request sent to you (the request comes back). `DELETE /v1/friend-requests/{id}` cancels your own request (`204`). Someone else's request is `404 FRIEND_REQUEST_NOT_FOUND`; one already answered is `409 REQUEST_CLOSED` |
| `DELETE /v1/me/friends/{user_id}` | Remove a friend (`204`) |
| `GET /v1/me/rivals` | Opponents played 3+ times in 60 days, each with an `h2h` record: `{"items": [{"user": card, "h2h": {"wins", "losses", "draws"}, "relationship", "games", "last_played_at"}]}` |
| `GET /v1/me/activity?cursor=` | Friends' notable events, and your own shares, from the last 7 days: `{"id", "user": card, "kind": "achievement" \| "podium" \| "level_up" \| "streak" \| "friend" \| "shared_result" \| "shared_progress", "payload", "created_at"}`. A `friend` item's payload has the new friend's card as `friend` (never a minor you aren't friends with). Share payloads are below |
| `POST /v1/me/activity/shares` | Post to your friends' activity. Body `{"kind": "match_result", "match_id"}` or `{"kind": "progress"}` and nothing else (no text or pictures: any other field is `422`); needs an `Idempotency-Key`. `201` with the new activity item. The server builds the payload from its own records. A match must be your own and ended: otherwise (or while the realtime engine hasn't plugged in results) `404 NOT_FOUND`; each match can be posted once (`409 ALREADY_SHARED` with `details.activity_id`). Progress can be posted 3 times per IST day (`409 LIMIT_REACHED`, `details {"limit": "daily", "max": 3}`). Rate-limited |

**Share payloads.** `shared_result`: `{"match_id", "mode", "result": "win" \| "draw" \| "loss",
"subject", "chapter" (or null), "score", "opponent_score", "opponent": card or null,
"opponent_name", "questions": ["correct" \| "wrong" \| "skipped", ...], "rating_change", "coins",
"xp"}`. In a group battle the opponent is the best other player. `opponent` is null for a bot and
for a player the viewer may not see (blocked, or a minor who isn't the viewer's friend); then
`opponent_name` is the bot's name or "Another player". The settlement fields are null when the
match hadn't settled or they don't apply. `shared_progress`: `{"level", "xp", "xp_into_level",
"xp_for_level" (0 at the top level), "streak": {"current", "best"}, "answered", "correct",
"accuracy" (whole percent, null before the first answer), "ratings": [{"scope", "rating"}]}`
(`ratings` is empty until the ratings feature supplies the profile's ratings section).

For the realtime engine: results reach shares through
`app.modules.social.shares.register_share_source("match_result", source)`, where
`async source(db, user_id, match_id: str) -> dict | None` returns the fields above (with
`opponent_id` for a person or `opponent_name` for a bot, instead of `opponent`) for the user's own
ended match, and None otherwise.
| `POST /v1/blocks` and `DELETE /v1/blocks/{user_id}` | Body `{"user_id"}` → `204`. Blocking ends the friendship and pending requests, and hides the two from each other everywhere (search, profiles, lists, pairing, invites). Unblocking doesn't bring the friendship back. `GET /v1/me/blocks?cursor=` lists `{"user": card, "created_at"}` |
| `POST /v1/reports` | Body `{"user_id", "match_id"?, "reason": "cheating" \| "offensive_name" \| "harassment" \| "other", "note"?}` (note up to 500 characters) → `202`. The same report within a day is kept once. 10 an hour |
| `GET /v1/me/opponents?days=30` | Recent opponents (people, not bots), each with an `h2h` record, `relationship` and **Add friend**, so a good game can turn into a friendship. Same item shape as `/me/rivals`, most recent first |
| `GET /v1/me/settings/privacy` and `PUT` | `{"friend_requests": "everyone" \| "played_with" \| "nobody", "challenges": "friends" \| "everyone" \| "nobody", "presence": "friends" \| "nobody", "public_boards": true}`; the `GET` and the `PUT` answer add `is_minor`. Adults default to `everyone`, `everyone`, `friends`; minors to `played_with`, `friends` and `friends` (worked out from the birth year on every read, so they lift at 18). `PUT` sends all four; an under-18 choosing `"friend_requests": "everyone"` gets `422` with a field message. Explains any `NOT_ALLOWED` |

## Account

| Endpoint | Does |
|---|---|
| `PATCH /v1/me` | Any of `display_name`, `avatar`, `goal` and `handle` → the profile (as `GET /v1/me`). The handle follows the onboarding rules and can change once every 30 days (the one picked at onboarding doesn't count): `409 HANDLE_CHANGE_TOO_SOON` with `details.next_change_at`, `409 HANDLE_TAKEN`. `GET /v1/me` has `next_handle_change_at` (`null`: now) |
| `POST /v1/me/delete` | Body `{"confirm": "DELETE", "proof": {"provider": "google", "id_token": "…"}}`, or `{"provider": "dev"}` where dev login is enabled. The ID token must be fresh (issued in the last 10 minutes), unused, and for the Google account linked to this profile; otherwise `403 REAUTH_REQUIRED` with `details.reason` (`ID_TOKEN_EXPIRED`, `TOKEN_REPLAYED`, `INVALID_ID_TOKEN`, `WRONG_ACCOUNT` or `PROOF_NOT_ACCEPTED`). Returns `202` `{"status": "pending_deletion", "restore_until"}` and ends every session, this one included (`SESSION_REVOKED`, reason `account_deleted`) |
| `POST /v1/me/restore` | Allowed within 7 days of a delete, from the restricted session. Returns the profile (as `GET /v1/me`, `status: "active"`); `409 RESTORE_EXPIRED` afterwards |
| `POST /v1/feedback` | Body `{"kind": "problem" \| "idea" \| "coins" \| "ban_appeal", "message", "request_id"?}` with an `Idempotency-Key` → `202`. The app attaches the last error's request id (`error.request_id`, or the `X-Request-ID` header) |

**The delete proof.** The app signs in again right before deleting and sends what it got:

```json
{"confirm": "DELETE", "proof": {"provider": "google", "id_token": "<a Google ID token minted just now>"}}
{"confirm": "DELETE", "proof": {"provider": "dev"}}
```

- `google`: the token is verified like `POST /v1/auth/google` and must belong to this account.
- `dev`: accepted only where dev login is (development environments), for the signed-in account.
- A missing, stale or mismatched proof is `403 REAUTH_REQUIRED`; anything but `"DELETE"` in
  `confirm` is `422`.

**Deletion in detail**
- **For 7 days** the account is **hidden, not erased**: profile, friendships, ranks and history
  are soft-hidden, so a restore brings everything back exactly. Tournament entries stay withdrawn
  and refunded.
- **Signing in during those 7 days** gives a restricted session that can only call `GET /v1/me`
  (`status: "pending_deletion"`, with `restore_until`), `POST /v1/me/restore` and logout. The app
  shows Restore or Sign out. Anything else answers `401 ACCOUNT_CLOSED`. The sign-in response's
  `user` carries the same `status` and `restore_until`.
- **From day 7 to day 30** signing in answers `403 ACCOUNT_CLOSED`.
- **On day 30** the account is erased for good, including its Google link: the name, handle,
  email, birth year, sessions, settings, inbox, friends, requests, blocks, activity and feedback
  go. Coin ledger, match and practice rows stay under the anonymous tombstone id. The same Google
  account can then sign up again as a new player.

**Bans and restrictions**
- `ACCOUNT_BANNED` (403) carries `details {"reason": "cheating" | "abuse" | "offensive_name" |
  "other", "until": <ISO or null>, "appeal": "<contact>"}`. The app shows a Suspended screen with
  the reason, the end date, the appeal contact and Sign out.
- A `restricted` account (`GET /v1/me` `status: "restricted"`) keeps playing but can't send
  friend requests (`403 NOT_ALLOWED`, reason `restricted`) or challenges. Blocked actions show an
  inline notice, and the change is an `account` inbox item.
- The moderation ladder: warn, reset name (to "Player" and a `player_…` handle the player can
  change at once), restrict social, shadow pool (silent: matchmaking pairs them among themselves),
  temporary ban, permanent ban. Warnings, resets and restrictions are `account` inbox items. A ban
  ends every session (`GET` answers `ACCOUNT_BANNED`, and so does a refresh) and closes the live
  socket.
- `SESSION_REVOKED` (401) carries `details.reason` (`logout`, `signed_out`, `replaced`,
  `session_limit`, `refresh_reuse` or `account_deleted`), so the app can say "Signed out from
  another device" rather than a vague "session ended".

## Client analytics events

`POST /v1/events` with `{"events": [{"name", "props", "at"}]}` → `202` with `{"accepted": n}`.
- A request holds at most 20 events. Names come from an allowlist (screen-level events such as
  `leaderboard_viewed`, `review_opened`, `notification_opened`).
- `props` holds small scalars only, never personal data.
- **Minors.** India's DPDP Act bars behavioural tracking of children. For users under 18, events are
  stored **without** a stable user id (only a per-session id and counts). Settings has an analytics
  toggle for everyone: `GET`/`PUT /v1/me/settings/app` with `{"analytics": true}`. Off, nothing
  is recorded for that player, by the app or the server.
- Unknown names and times more than 7 days old or in the future are dropped, not rejected.
- Everything else in `docs/user-flows.md` §15 is recorded by the server.
