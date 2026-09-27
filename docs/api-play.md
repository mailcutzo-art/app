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
{"min_build": 12, "maintenance": false, "maintenance_message": null, "features": {"tournaments": true}, "server_time": "2026-09-27T16:00:00Z"}
```

- `min_build`: the app shows Update required when its build is lower. Any `426` response means the
  same thing.
- `maintenance`: the app shows the Maintenance screen with `maintenance_message`.

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
  "last": {"subject": "physics", "chapter": null, "mode": "rated"}
}
```

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
 "not_ranked": {"games_to_rank": 7}}
```

**Boards**

| Board | Ranks by | Eligible |
|---|---|---|
| `weekly_xp` | XP this IST week (Mon 00:00 to Sun 23:59 IST). Ties go to whoever reached the total first | Anyone with XP this week |
| `weekly_xp:last` | Last week's final standings | The same |
| `rating:overall` | Overall rating | At least 10 rated games and RD ≤ 110 |
| `rating:{subject}` | Subject rating | The same, per subject |
| `friends:weekly_xp`, `friends:rating` | You and your friends | You and your friends |

- **Excluded:** banned players, and players pending deletion.
- **Change figures:** `change_1d` is the position change since the previous day's snapshot.
- **Moving into the top 100, 10 or 3** of any board creates an inbox item.

## Tournaments

| Endpoint | Returns or does |
|---|---|
| `GET /v1/tournaments?status=open\|upcoming\|live\|finished&goal=&cursor=` | Cards: `{"id", "title", "subject", "tone", "status", "reg_opens_at", "checkin_opens_at", "starts_at", "rounds", "entry_fee", "prize_pool", "effective_pool", "players", "capacity", "me": {"registered", "checked_in", "withdrawn"} \| null}` |
| `GET /v1/me/tournaments?cursor=` | Your upcoming, live and past tournaments. Past ones add `final_rank`, `players` and `prize` |
| `GET /v1/tournaments/{id}` | Detail: rules, the round schedule, the prize table for the current player count, `status`, `current_round`, and `me` (registered, checked in, record, points, rank, next pairing) |
| `POST /v1/tournaments/{id}/register` | Holds the entry fee. Needs an Idempotency-Key. Errors: `TOURNAMENT_FULL`, `REGISTRATION_CLOSED`, `INSUFFICIENT_COINS`, and `NOT_ALLOWED` (paid registration blocked for 7 days after 3 no-shows) |
| `DELETE /v1/tournaments/{id}/register` | Withdraw. Before the start, the fee is fully refunded. After the start, you stay in the standings for tie-breaks, can't win a prize, and get no refund |
| `POST /v1/tournaments/{id}/check-in` | Allowed from 15 min to 2 min before the start. Errors: `CHECK_IN_CLOSED` and `NOT_REGISTERED`. Opening the realtime connection during the window also checks you in |
| `GET /v1/tournaments/{id}/standings?cursor=` | Rows: `{"position", "user", "points", "w", "d", "l", "bh_c1", "bh", "sb", "withdrawn"}`, plus `me` |
| `GET /v1/tournaments/{id}/me` | Your games by round: opponent, result, points, `match_id` (or a bye), and the current pairing |

**Rules for players who are registered or checked in:**
- From 5 min before the start, starting a quick battle or joining a room returns `BUSY`, with
  the tournament in `details.active`.
- A tournament cancelled for too few players refunds everyone and sends an inbox item.

## Profiles and stats

| Endpoint | Returns |
|---|---|
| `GET /v1/users/{handle}` | The public profile: card, level, `ratings: [{"scope", "rating", "position"}]`, form (last 5 results), `h2h` with you, `relationship` (`none`, `friend`, `requested` or `blocked`), `can_challenge`. `404` when blocked in either direction |
| `GET /v1/me/stats` | Ratings per scope with position; W/D/L per mode; accuracy; questions answered; best and current streak; `rating_history: [{"at", "value"}]` for `?range=30d\|90d\|all` |

## Wallet and XP

| Endpoint | Returns |
|---|---|
| `GET /v1/me/wallet` | `{"balance", "held", "recent": [/* 5 transactions */]}` |
| `GET /v1/me/wallet/transactions?cursor=` | `{"id", "delta", "balance_after", "reason", "title", "ref": {"kind": "match" \| "tournament" \| "mission" \| "streak" \| "achievement" \| "hint" \| "welcome" \| "level", "id"}, "created_at"}` |

Example titles: "Casual battle entry", "Casual battle won", "Refund: match cancelled", "Tournament
prize: #3 in Physics Sunday Cup", "Daily missions bonus".

## Missions

`GET /v1/me/missions` returns the same shape as Home's `missions`. Rewards are credited
automatically.

## Inbox and push

| Endpoint | Does |
|---|---|
| `GET /v1/me/notifications?cursor=` | `{"id", "kind", "title", "body", "icon", "action", "created_at", "read"}`, newest first, kept for 90 days |
| `GET /v1/me/notifications/unread-count` | `{"count": 3}`. Live updates come as `notify` events on `u` |
| `POST /v1/me/notifications/read` | Body `{"ids": [...]}` or `{"all": true}` → `204` |
| `PUT /v1/me/push-token` | Body `{"token", "platform"}` → `204`. `DELETE` removes it (it is also removed on sign-out) |
| `GET /v1/me/settings/notifications` | `{"kinds": {"invites": true, "tournaments": true, "friends": true, "missions": true, "streaks": true}}` |
| `PUT /v1/me/settings/notifications` | Same body as the `GET` |

**Kinds:** `invite`, `friend_request`, `friend_accepted`, `tournament_reminder`,
`tournament_check_in`, `tournament_round`, `tournament_result`, `tournament_cancelled`, `refund`,
`prize`, `match_forfeit`, `mission_done`, `level_up`, `achievement`, `rank_milestone`,
`streak_risk` and `account`.

## Social

| Endpoint | Does |
|---|---|
| `GET /v1/me/friends?cursor=` | Cards with `presence`: `online`, `in_battle`, `in_tournament` or `offline` |
| `GET /v1/users/search?q=` | Needs at least 3 characters; matches handles by prefix. Cards with `relationship`. Rate-limited |
| `POST /v1/friend-requests` | Body `{"user_id"}`. Errors: `NOT_ALLOWED` (their privacy settings: minors only accept people they've played), and `LIMIT_REACHED` (20 a day, 100 pending) |
| `GET /v1/me/friend-requests` | `{"incoming": [...], "outgoing": [...]}` |
| `POST /v1/friend-requests/{id}/accept` and `/decline` | Accept or decline. `DELETE` cancels your own request |
| `DELETE /v1/me/friends/{user_id}` | Remove a friend |
| `GET /v1/me/rivals` | Opponents played 3+ times in 60 days, each with an `h2h` record |
| `GET /v1/me/activity?cursor=` | Friends' notable events from the last 7 days |
| `POST /v1/blocks` and `DELETE /v1/blocks/{user_id}` | Block or unblock. `GET /v1/me/blocks` lists blocks |
| `POST /v1/reports` | Body `{"user_id", "match_id"?, "reason": "cheating" \| "offensive_name" \| "harassment" \| "other", "note"?}` → `202` |

## Account

| Endpoint | Does |
|---|---|
| `POST /v1/me/delete` | Body `{"confirm": "DELETE"}` plus a fresh sign-in proof (Google ID token or dev login). Returns `202`, and ends every session |
| `POST /v1/me/restore` | Allowed within 7 days of a delete. Signing in to an account pending deletion returns `user.status = "pending_deletion"`, and the app offers Restore |

## Client analytics events

`POST /v1/events` with `{"events": [{"name", "props", "at"}]}` → `202`.
- A request holds at most 20 events. Names come from an allowlist (screen-level events such as
  `leaderboard_viewed`, `review_opened`, `notification_opened`).
- `props` holds small scalars only, never personal data.
- Everything else in `docs/user-flows.md` §15 is recorded by the server.
