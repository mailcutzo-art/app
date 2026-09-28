# Quiz backend

Python (FastAPI) backend for the quiz battle app. One codebase runs as three processes:

| Process  | Entry point                   | Role                                                   |
|----------|-------------------------------|--------------------------------------------------------|
| `api`    | `app.main_api:create_app`     | REST API under `/v1`, plus `/healthz` and `/readyz`    |
| `rt`     | `app.main_rt:create_app`      | WebSocket gateway at `/v1/ws` and the live quiz engine  |
| `worker` | `python -m app.main_worker`   | Periodic jobs: tournament ticks, outbox, reconcilers   |

PostgreSQL 16 holds settled data; Redis 7 holds live state, queues and rate limits. The server is
authoritative, and all match timing comes from Redis `TIME`. See `../docs/plan.md`.

## Quick start

Needs Python 3.11+, [uv](https://docs.astral.sh/uv/), PostgreSQL 16 server binaries and Redis 7.

```bash
cd backend
uv sync                                  # .venv with runtime and dev dependencies
scripts/dev_services.sh start            # Postgres on :54329, Redis on :63790 (data in .dev/)
uv run alembic upgrade head              # migrate quiz_dev
uv run python -m app.modules.content.seed   # load the question bank from ../content
uv run uvicorn app.main_api:create_app --factory --reload --port 8000
curl -s localhost:8000/readyz            # {"status":"ok","checks":{"database":"ok","redis":"ok"}}
```

Interactive API docs are at `/docs` outside prod.

## Local services

`scripts/dev_services.sh` runs Postgres and Redis as plain processes (no Docker), keeping all data
in `backend/.dev/` (gitignored). Every command is idempotent.

| Command  | Effect                                                                          |
|----------|---------------------------------------------------------------------------------|
| `start`  | Initialise the cluster if needed, start both, create role `quiz` (password `quiz`) and databases `quiz_dev` and `quiz_test` with `citext` and `pg_trgm`, print the env vars |
| `stop`   | Stop both                                                                       |
| `status` | Show state; exits 1 if either is down                                           |
| `reset`  | Stop, delete `.dev/`, start fresh                                               |
| `env`    | Print the environment variables to use                                          |

Postgres refuses to run as root, so under root the cluster runs as the `postgres` OS user (or a
`pgdev` system user created on first use). Ports and paths can be overridden with `PG_PORT`,
`REDIS_PORT`, `PG_BIN` and `PG_LOCALE`.

## Configuration

Settings come from `APP_*` environment variables, then an optional `backend/.env`; every one is
documented in [`.env.example`](.env.example). Defaults match the local services, so dev needs no
configuration. `APP_ENV=prod` refuses to start unless the database and Redis URLs, the Ed25519
JWT key pair and `APP_REFRESH_GRACE_KEY` are set explicitly and `APP_DEV_LOGIN_ENABLED` is false.
Dev and test generate ephemeral keys per process. Push notifications need
`APP_FCM_SERVICE_ACCOUNT_FILE` (a Firebase service-account key); without it push is off. Google
sign-in needs `APP_GOOGLE_CLIENT_IDS`
(the OAuth web client id); local testing can use dev login instead
(`APP_DEV_LOGIN_ENABLED=true`).

## Running the processes

```bash
uv run uvicorn app.main_api:create_app --factory --port 8000 --no-proxy-headers
uv run uvicorn app.main_rt:create_app --factory --port 8001 --no-proxy-headers --ws-max-size 65536 \
  --timeout-graceful-shutdown 8
uv run python -m app.main_worker
```

Client IPs honour `X-Forwarded-For` only from `APP_TRUSTED_PROXIES`; `--no-proxy-headers` keeps
uvicorn from rewriting them first. The worker stops on SIGTERM/SIGINT after in-flight jobs
finish (10 s grace).

**Realtime.** Any number of identical `rt` replicas can run behind one load balancer; they share
Redis. On SIGTERM a replica closes its sockets with 1012 (players get extra grace and reconnect
elsewhere) and hands its match leases back, so another replica adopts the matches at once. The
worker settles anything an `rt` node left behind (`settle_pending`, every 5 s) and voids matches
Redis lost (`reconcile_matches`). A client needs a ticket from the api
(`POST /v1/rt/tickets`) and then `hello` on `ws://localhost:8001/v1/ws`; `docs/protocol.md` has
the messages. Every live timing is an `APP_RT_*`, `APP_MATCH_*` or `APP_MM_*` setting
(`.env.example`), so a local game can be made short.

## Migrations

```bash
uv run alembic upgrade head                                  # uses APP_DATABASE_URL
uv run alembic revision --autogenerate -m "add matches" --rev-id 0003
uv run alembic upgrade head --sql                            # print SQL instead of running it
```

Revision ids are sequential (`--rev-id`). New models must be imported in `app/models.py` so
autogenerate sees them; `tests/test_db.py` fails if the models and migrations drift apart. The
baseline (0001) creates `citext`, `pg_trgm`, `app_config` and `audit_log`, where an
`append_only_guard()` trigger rejects UPDATE, DELETE and TRUNCATE. 0002 adds `users`,
`auth_identities`, `device_sessions` and `refresh_tokens`. 0003 adds the question bank, practice
sessions, answer records, per-user progress and XP (see `../docs/data-model.md`) and the users'
ban details. `question_attempts` is partitioned by month: the SQL function
`ensure_attempt_partitions(months_ahead)` creates the current and following months (moving any
rows that already landed in the DEFAULT partition), and the worker calls it daily. Partitions are
not models, so autogenerate and the drift test skip them (`app.models.include_name`). 0004 adds the
platform tables: `outbox`, `wallets`, `coin_ledger` (append-only through the same trigger),
`coin_holds`, `notifications`, `push_tokens`, `user_settings`, `analytics_events` and `feedback`.

## Tests and checks

```bash
scripts/dev_services.sh start
uv run ruff check .
uv run ruff format --check .
uv run mypy app
uv run pytest -q
```

Tests use the real services: database `quiz_test` and Redis DB 15 by default, or
`APP_DATABASE_URL` / `APP_REDIS_URL` (the database name must end in `_test`, since tests migrate
it and flush Redis). Alembic upgrades once per run and the repository's `content/` is seeded
(idempotently, so reruns change nothing); each test then runs in an outer transaction
that is rolled back, with app sessions joined through SAVEPOINTs so code that commits still
works. Redis is flushed before each test that uses it. The few race tests that need truly
concurrent transactions (`tests/test_auth_concurrency.py`) commit and truncate `users` afterwards.
Google ID tokens in tests are signed with a local RSA key served as a fake JWKS; the app's clock
is a `FakeClock` that tests move forward (grace periods, expiry).

## Accounts and sign-in

| Endpoint | |
|---|---|
| `POST /v1/auth/google` | `{id_token, device}` → `{access_token, access_expires_in, refresh_token, user, is_new_user}` |
| `POST /v1/auth/dev-login` | `{email, display_name?, device}`, same response; only when dev login is enabled (else 404) |
| `POST /v1/auth/refresh` | `{refresh_token}` → `{access_token, access_expires_in, refresh_token}` |
| `POST /v1/auth/logout` | ends this device's session (204) |
| `GET /v1/me`, `PATCH /v1/me` | own profile; `PATCH` takes any of `display_name`, `avatar`, `goal` |
| `POST /v1/me/onboarding` | `{display_name, handle, avatar, goal, birth_year}`, once |
| `GET /v1/handles/check?handle=` | `{"available": true}` or `{"available": false, "reason": "invalid"\|"reserved"\|"taken"}` |
| `GET /v1/me/sessions`, `DELETE /v1/me/sessions/{id}`, `POST /v1/me/sessions/revoke-others` | signed-in devices |

- **Google ID tokens** are verified locally: RS256 signature against Google's JWKS (cached per
  `Cache-Control`, 5 min–24 h, refetched once for an unknown key id), `aud` in
  `APP_GOOGLE_CLIENT_IDS`, Google as `iss`, unexpired, `iat` within the last 10 minutes and
  `email_verified`. Each token is accepted once (`TOKEN_REPLAYED`). Accounts are matched by
  (provider, subject), never by email.
- **Access tokens** are EdDSA JWTs (`kid` header; claims `sub`, `sid`, `roles`, `ver`, `iat`,
  `exp`, `jti`) valid for 15 minutes. Every request also checks, in one Redis round trip, the
  session's revocation marker (`revoked_sid:{sid}`, set by logout and revocations) and the
  user's status, token version and roles (`authz:{user}`, cached 60 s).
- **Refresh tokens** are 256-bit random strings stored as SHA-256 hashes, valid 30 days from last
  use and at most 90 days from sign-in. Each refresh rotates the token. Presenting a used token
  again within 60 s returns the same new pair (kept AES-GCM encrypted in Redis) so a crash
  mid-refresh is harmless; later, it counts as theft and ends the session
  (`REFRESH_TOKEN_REUSED`).
- **Device sessions**: one per app installation (signing in again replaces it) and at most five
  per user (the least recently used ones end). `last_seen_at` is written at most every 5 min.
- **Codes** worth knowing: 401 `UNAUTHORIZED`, `ACCESS_TOKEN_EXPIRED`, `INVALID_ACCESS_TOKEN`,
  `SESSION_REVOKED` (`details.reason`: `logout`, `signed_out`, `replaced`, `session_limit` or
  `refresh_reuse`), `ACCOUNT_CLOSED`, `INVALID_REFRESH_TOKEN`, `REFRESH_TOKEN_REUSED`,
  `INVALID_ID_TOKEN`, `ID_TOKEN_EXPIRED`, `EMAIL_NOT_VERIFIED`, `TOKEN_REPLAYED`; 403
  `ACCOUNT_BANNED` (`details`: `reason`, `until`, `appeal`), `ROLE_REQUIRED`; 409
  `ALREADY_ONBOARDED`, `HANDLE_TAKEN`; 426 `UPDATE_REQUIRED`; 503 `MAINTENANCE`.
- **Bans** set `users.status = 'banned'`, optionally `ban_reason` (cheating, abuse,
  offensive_name, other) and `banned_until`. A temporary ban stops counting once `banned_until`
  has passed (sign-in, refresh and requests work again; the status is left as it is).
  `APP_APPEAL_CONTACT` is shown to suspended players.
- **Names**: display names are 2–30 characters without links, @mentions, phone numbers, hidden
  characters, profanity or staff titles; handles are 3–20 of `[a-z0-9_]` (lowercased), neither
  reserved nor profane. Profanity lists (English, Hinglish, Devanagari) live in
  `app/modules/moderation/data/`.
- **Admins**: `uv run python scripts/create_admin.py <email or @handle>` grants the admin role to
  a user who has signed in once (audit-logged). Endpoints require roles with
  `Depends(require_role(Role.ADMIN))`; admin includes moderator.

## Question bank

```bash
uv run python -m app.modules.content.seed [content_dir]   # default: APP_CONTENT_DIR (../content)
```

The seed validates the files with `content/tools/validate.py` (the same rules CI runs; any
problem aborts before the database is touched), then upserts by stable ids. A second run changes
nothing and says so. A question whose stem, options or answer changed becomes a new row that
supersedes the retired old one, so past answers keep pointing at what was asked; explanation,
tags, difficulty, topic and similar edits update in place. Questions, passages and words that
left the files are retired (only rows the files own, `source = 'content'`), chapters and topics
deactivated. `battle: true` means the `shared` pool; a question an admin moved to `reserved`
stays there. Each change records a new content version in `app_config`, which the catalog's
ETag is built from. In Docker the one-shot `seed` service does this before `api` starts.

## Learn and practice

Specified in `../docs/api-learn.md`; all need a signed-in player.

| Endpoint | |
|---|---|
| `GET /v1/catalog?goal=` | subjects, chapters, topics and question counts of an exam (default: the player's); `ETag`, `304` |
| `GET /v1/me/progress?goal=` | answers per subject and chapter, Strong / Needs work labels, reviews due, `continue`, top tip |
| `POST /v1/practice/sessions` | modes chapter, topic, category, review, bookmarks, challenge, passage; `Idempotency-Key`; 30 an hour |
| `GET /v1/practice/sessions/{id}` | the session plus its recorded answers (readable for 90 days) |
| `POST /v1/practice/sessions/{id}/answers` | batches of up to 50; each `accepted`, `duplicate` or `rejected` with a reason |
| `POST /v1/practice/sessions/{id}/finish` | idempotent; totals, NEET score, topics, XP, tip |
| `GET /v1/me/practice/sessions` | history of the last 90 days, newest first (cursor) |
| `PUT`/`DELETE /v1/me/bookmarks/{ref}`, `GET /v1/me/bookmarks` | at most 5,000 |
| `GET /v1/me/reviews/summary` | `{due, total}` |
| `GET /v1/search?q=` | 2+ characters, 30 a minute; full-text prefixes, then trigram substring |
| `GET /v1/questions/{ref}`, `POST /v1/questions/{ref}/reports` | one question; report it (202, 20 a day) |
| `GET /v1/passages`, `GET /v1/me/tips`, `POST /v1/me/tips/{key}/dismiss` | Fun & Learn; coach tips |

- **Question choice.** Only questions suited to the player's exam (`exams` null or naming it, in
  one of the exam's subjects) and never those `reserved` for battles; never-answered questions
  first, then those answered longest ago.
- **Answers.** The server decides correctness. Answer ids are claimed in `attempt_keys` and the
  first answer per position in `practice_answers`, so retries count once. Answers are judged by
  when they were given (`answered_at`, clamped to the session's start and the present): given
  after expiry is `session_expired`, after a challenge's limit plus 60 s `time_up`; phones may
  upload up to 7 days after a session expired. `time_ms` is capped at 10 minutes or the
  per-question limit. Each recorded answer writes a `question_attempts` row, updates
  `user_questions` (first try, Leitner box: wrong → box 1; a correct answer to a due question
  moves up; box 5 graduates) and the running totals (`user_topic_stats`, `user_chapter_stats`,
  `user_category_stats`, `user_daily_stats`) in the same transaction, then awards practice XP
  (`xp_events`, unique per batch; daily cap 300 by IST day).
- **Shared rules.** The XP formulas, the speed label against a question's typical time and the
  coach's tip rules are separate pure modules (`progression.levels`, `realtime.engine.scoring`,
  `coach.tips`), reached through `progression.xp.xp_rules`, `practice.speed.speed_vs_typical`
  and `coach.service.tips_engine`; live games use the same ones.

## Platform: outbox, coins, inbox, analytics

| Endpoint | |
|---|---|
| `GET /v1/me/wallet` | `{balance, held, recent}` (the last 5 transactions) |
| `GET /v1/me/wallet/transactions?cursor=` | the coins history, newest first: `{id, delta, balance_after, reason, title, ref: {kind, id}, created_at}` |
| `GET /v1/me/notifications?cursor=`, `GET /v1/me/notifications/unread-count` | the inbox (90 days) and the bell's badge |
| `POST /v1/me/notifications/read` | `{ids}` or `{all: true}` → 204 |
| `PUT`/`DELETE /v1/me/push-token` | this device's FCM token (also removed when its session ends) |
| `GET`/`PUT /v1/me/settings/notifications` | push per category and quiet hours (default 22:30–07:00 IST) |
| `GET`/`PUT /v1/me/settings/app` | `{analytics}`: the analytics toggle |
| `POST /v1/events` | up to 20 allowlisted screen events → 202 `{accepted}`; 30 a minute |
| `POST /v1/feedback` | `{kind: problem\|idea\|coins\|ban_appeal, message, request_id?}` → 202; 5 an hour |

- **Outbox** (`app.modules.outbox`). `enqueue(db, topic, payload, key=...)` writes a message in the
  caller's transaction (a repeated key is ignored); modules `register(topic, handler)` and are
  listed in `HANDLER_MODULES`. The worker claims due rows with `FOR UPDATE SKIP LOCKED`, runs
  each handler in a SAVEPOINT of the same transaction, and retries failures with backoff (5 s
  doubling to 1 h), dead-lettering after 8 attempts (`outbox.dead_letter` is logged). Delivery
  is at least once, so handlers are idempotent.
- **Coins** (`app.modules.economy.service`). `credit`, `debit`, `transfer`, `hold`,
  `capture_hold`, `release_hold` and `settle_pot` lock wallets `FOR UPDATE` in user order,
  replay an already-posted idempotency key without changing anything, and raise 409
  `INSUFFICIENT_COINS`. A hold posts its `-amount` entry at once; releasing it posts a refund.
  `wallets.balance` has `CHECK >= 0`; the `purchased` bucket is reserved and never spent. The
  welcome bonus (100, key `welcome:{uid}`) is credited when onboarding completes, and
  `pop_welcome` hands it to Home once. The reaper refunds holds open for 30 minutes unless the
  module owning the reference says it is live (`economy.jobs.register_liveness`).
- **Inbox and push** (`app.modules.notifications`). `notify(db, user_id, kind=..., title=...,
  body=..., key=...)` stores the item and enqueues `notify.live` (a `notify` event on Redis
  `ev:u:{uid}`, docs/protocol.md §9a) and `notify.push`. Push uses FCM HTTP v1 when
  `APP_FCM_SERVICE_ACCOUNT_FILE` is set (otherwise it is skipped and `/v1/config` reports
  `features.push: false`); it follows the category settings and quiet hours, except
  `time_critical` notices, drops tokens FCM reports as unregistered, and skips pushes over an
  hour late.
- **Analytics** (`app.modules.analytics`). `track(db, name, user_id, props, now=...)` records
  server-side funnel events directly in the caller's transaction (no outbox: nothing external
  to deliver). Players who turned analytics off are not recorded; minors are stored without a
  user id, with a session key that is an HMAC under a daily salt deleted after two days.

- **Social and account** (`app.modules.social`, `app.modules.moderation`,
  `app.modules.users.deletion`). Other features plug in rather than being imported:
  `register_have_played(fn)` ("played with" for minors' friend requests; default never),
  `register_profile_section("ratings" | "form" | "h2h", fn)` (public profile sections; default
  empty), `register_block_hook(fn)` (e.g. cancel invites), `register_ban_hook(fn)` and
  `on_account_deleted` / `on_account_restored` / `on_account_erased(fn)`. They call
  `are_blocked(db, a, b)`, `blocked_ids(db, uid)`, `can_challenge(db, viewer, target)`,
  `set_presence(redis, uid, state, ttl_s)`, `record_activity(db, uid, kind, payload, key=)`,
  `in_shadow_pool(db, uid, now=)` and `apply_moderation(db, redis, uid, action, reason=, until=,
  by=, now=)`.

- **Live games wired in** (`app.modules.matches.wiring.install()`, run at start by the api, rt
  and worker processes). The engine's ports (`matches.ports.integrations`) get the real modules:
  the casual 5-coin entry is a ledger hold (`matches.escrow`: captured and paid out as the
  10-coin pot, or released with a `refund` notice on a draw, abort, void or ended search; the
  hold reaper leaves it alone while the search or match carrying it is live); settlement awards
  XP, missions, streak and achievements before any wallet lock, then rated coins (10 / 4 / 1,
  at most 150 a day), `match_forfeit` / `match_settled` notices and analytics
  (`matches.rewards`); matchmaking skips blocked pairs and keeps the shadow pool to itself; the
  gateway keeps social presence (`online`, `in_battle`); abort strikes put a `match_aborted`
  notice in the inbox. Social gets "played with" and the profile's `ratings`, `form` and `h2h`
  (`matches.profiles`). A ban or an account deletion enqueues `matches.withdraw`, which cancels
  the player's search (refunding the entry) or forfeits their live match.

## Worker jobs

| Job | Every | Does |
|---|---|---|
| `practice_housekeeping` | 10 min | finishes sessions that expired unfinished, deletes sessions older than 90 days, forgets answer ids after 14 days |
| `attempt_partitions` | daily | `ensure_attempt_partitions(3)` |
| `question_stats` | nightly (after 02:00 IST) | rebuilds `question_stats`: attempts, share correct, and the median time of correct answers over 90 days (`typical_ms`, from 20 answers) |
| `outbox_dispatch` | 1 s | delivers due outbox messages (replicas share the work) |
| `outbox_cleanup` | daily | deletes delivered messages after 7 days, dead ones after 30 |
| `hold_reaper` | 1 min | refunds coin holds stuck for 30 minutes whose reference isn't live |
| `notifications_retention`, `analytics_retention` | daily | inbox 90 days; analytics 180 days and old session salts |
| `moderation_expiry` | 1 min | ends social restrictions and temporary bans whose time is up |
| `account_erasure` | hourly | erases accounts 30 days after deletion: tombstones the user row, drops identities, sessions, settings, inbox, social rows and feedback |
| `activity_retention` | daily | the friends' activity feed keeps 30 days |

A Redis lease keeps each run to one worker replica, and daily jobs mark the day done only after
they succeed (`app/core/jobs.py`).

## Admin panel and question import

SQLAdmin at `/admin`, mounted by the api process when `APP_ADMIN_ENABLED=true` (settings in
`.env.example`). To open it locally:

```bash
APP_ADMIN_ENABLED=true APP_DEV_LOGIN_ENABLED=true uv run uvicorn app.main_api:create_app --factory --reload
# sign in to the app once (or POST /v1/auth/dev-login {"email": ...}), then:
uv run python scripts/create_admin.py you@example.com
# open http://127.0.0.1:8000/admin and use "Dev login" with that email
```

- **Sign-in**: Google's authorization-code flow with its own web client
  (`APP_ADMIN_GOOGLE_CLIENT_ID`/`_SECRET`, callback `/admin/auth/callback`); the Google account
  must be linked to a user with the admin role and an active account. Dev login by email exists
  only with `APP_DEV_LOGIN_ENABLED`. The session is a signed cookie (`APP_ADMIN_SESSION_SECRET`,
  path `/admin`, `SameSite=Lax`, `Secure` in prod) holding the admin's id and token version;
  every request re-checks the user, so a ban, a lost role or a `token_version` bump ends it.
- **Guard**: `APP_ADMIN_IP_ALLOWLIST` (optional, honours `APP_TRUSTED_PROXIES`); writes must come
  from the panel's own origin (`Origin`/`Referer`, `Sec-Fetch-Site`), which with the Lax cookie
  stops cross-site forms; pages can't be framed and aren't cached. Maintenance and forced
  updates don't apply to the panel.
- **Audit**: every create, update and delete writes an `audit_log` row (before and after JSON,
  admin id, IP) in the same transaction; sign-ins and imports are logged too. The audit log view
  is read-only.
- **Views**: users (status, roles and bans: a ban or role change bumps `token_version`, so the
  player's tokens stop working at once; admins can't demote or ban themselves), questions
  (search, filter by subject, chapter, status and source; editing a published question adds a
  superseding version and retires the old row, only retiring and `battle_pool` change in place;
  options are edited as A–D with one correct letter), passages, Guess the Word terms, subjects,
  exams, chapters and topics (read-only), the question report queue, `app_config` (runtime
  switches are validated like `/v1/config` reads them) and the audit log.
- **Report queue** (Content → Question reports, open ones by default): Review a report and close
  it as `fixed`, `rejected` or `retired` (which retires the question) with an internal note.
  Every open report on the question closes with it, and `app.modules.content.hooks.on_report_resolved`
  runs once per reporter inside the same transaction; the inbox registers its `question_report`
  notification there (see the module docstring; `report_outcome_notice(event)` builds the text).
- **Import**: `scripts/import_questions.py` and Content → Import questions take CSV or JSON in the
  format of `../docs/content-format.md` ("Importing questions"): a dry run reports every row
  (`ok`, `error`, `duplicate`, `near_duplicate`), imports are idempotent (normalized stem and
  option set) and audited, near duplicates are found with pg_trgm similarity above 0.9 within the
  subject, and new questions get the next per-subject `seq` and status `review` (or `published`).

## Forced updates and maintenance

`min_build`, `maintenance`, `maintenance_message`, `maintenance_until` and `maintenance_at` are
read from `app_config` rows of those names (falling back to the `APP_*` settings), so they change
without a redeploy; each api process re-reads them every 5 seconds. `GET /v1/config` reports
them. Requests whose `X-App-Build` header is below `min_build` get 426 `UPDATE_REQUIRED`, and while
maintenance is on 503 `MAINTENANCE` (with the message and `Retry-After`), except `/v1/config`,
`/v1/auth/*`, the probes, `POST /v1/rt/tickets` and `/v1/matches/*` (a game in progress can
always finish and show its result).

## API conventions (`app/core`)

- **Errors.** Every error, including 404/405 from routing, request validation (422) and
  unexpected exceptions (500, details only in logs), has the body
  `{"error": {"code", "message", "details", "request_id"}}`. Raise `AppError` subclasses from
  `app.core.errors` (`NotFound`, `Conflict`, `Forbidden`, `Unauthorized`, `ValidationFailed`,
  `RateLimited`, `ServiceUnavailable`, ...) with a stable `code`. Unreachable Postgres or Redis
  becomes 503 with `Retry-After`.
- **Request ids.** `X-Request-ID` is accepted when it is 8–128 characters of `[A-Za-z0-9._-]`,
  otherwise generated; it is echoed on the response, bound to every log line and included in
  error bodies.
- **Database.** Depend on `SessionDep`: one session per request, committed after the endpoint
  returns but before the response is sent (a failed commit is an error response), rolled back if
  it raises. IDs are UUIDv7 (`app.core.ids.new_id`, `UUIDv7Pk`).
- **Schemas.** Subclass `ApiModel` (strict, unknown fields rejected); wrap UUID, datetime and
  enum fields as `Lax[...]` so their JSON string forms are accepted. 422 responses carry
  `details.fields`, a flat `{field: message}` map shown next to form fields; raise
  `field_error("…")` in validators for messages written for people.
- **Authentication.** Depend on `CurrentAuth` (user, session and roles) or `CurrentUserId`; both
  answer 401/403 with the codes above. Time comes from `ClockDep` so tests can move it.
- **Rate limits.** `Depends(rate_limit("auth.sign_in", capacity=20, refill_per_sec=20 / 60))` runs
  an atomic Redis token bucket (Lua, Redis clock) keyed by client IP or, with `scope="user"`, by
  the authenticated user; over the limit it answers 429 with `Retry-After`.
- **Idempotency.** Endpoints that create entities or move coins take `idem: IdempotencyDep` and
  `return await idem.complete(body, status_code=201)`. The `Idempotency-Key` header (1–64 of
  `[A-Za-z0-9_-]`) is required. Retries replay the stored response with
  `Idempotent-Replayed: true` for 24 h; a concurrent retry gets 409 `IDEMPOTENCY_IN_PROGRESS`,
  and a different request under the same key 422 `IDEMPOTENCY_KEY_REUSED`.
- **Pagination.** `encode_cursor(position_model)` / `decode_cursor(cursor, Model)` produce and
  strictly validate opaque base64url cursors (422 `INVALID_CURSOR` otherwise).
- **Logging.** structlog, JSON in prod/test and a console renderer in dev. Values under keys such
  as `password`, `token`, `authorization`, `cookie`, `email` or `phone` are redacted, tracebacks
  never include local variables, and access logs never include query strings.

## Layout

```
app/
  main_api.py  main_rt.py  main_worker.py    process entry points
  models.py                                  imports every ORM model (Alembic metadata)
  core/                                      config, db, redis, resources, clock, ids, errors,
                                             logging, middleware, security, tokens, ratelimit,
                                             idempotency, pagination, schemas, factory
  modules/system/                            /healthz, /readyz, /v1/config; app_config, audit_log
  modules/auth/                              sign-in, Google tokens, refresh, device sessions
  modules/users/                             profile, onboarding, handle rules, authz cache
  modules/moderation/                        profanity and reserved names (+ data/ word lists)
  modules/realtime/                          /v1/ws gateway skeleton and protocol constants
  modules/content/                           question bank, seed, catalog, search, reports,
                                             importer, edits (versions), report review, hooks
  modules/admin/                             SQLAdmin panel: sign-in, guard, views, templates
  modules/practice/                          sessions, answers, running totals, reviews, jobs
  modules/progression/                       XP events and totals
  modules/coach/                             tip inputs, tips cache, dismissals
  modules/outbox/                            transactional outbox, handler registry, dispatcher
  modules/economy/                           wallets, coin ledger, holds, welcome bonus, reaper
  modules/notifications/                     inbox, notify(), live and FCM delivery, push tokens
  modules/analytics/                         client events, track(), retention
  modules/feedback/                          Help & feedback messages
alembic/                                     async env.py and revisions
scripts/dev_services.sh                      local Postgres and Redis
scripts/create_admin.py                      grant the admin role
scripts/import_questions.py                  import questions from CSV or JSON
tests/                                       pytest suite (real Postgres and Redis)
```

## Docker

```bash
docker build -t quiz-backend .
docker run --env-file .env.prod quiz-backend alembic upgrade head
docker run --env-file .env.prod -e APP_CONTENT_DIR=/content -v "$PWD/../content:/content:ro" \
  quiz-backend python -m app.modules.content.seed
docker run --env-file .env.prod -p 8000:8000 quiz-backend                     # api
docker run --env-file .env.prod quiz-backend python -m app.main_worker        # worker
```

The image is multi-stage (dependencies installed with uv, then copied into a slim runtime), runs
as an unprivileged user with `APP_ENV=prod` by default, and has a `/healthz` healthcheck. The
header of the `Dockerfile` lists the command for each process.
