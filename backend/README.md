# Quiz backend

Python (FastAPI) backend for the quiz battle app. One codebase runs as three processes:

| Process  | Entry point                   | Role                                                   |
|----------|-------------------------------|--------------------------------------------------------|
| `api`    | `app.main_api:create_app`     | REST API under `/v1`, plus `/healthz` and `/readyz`    |
| `rt`     | `app.main_rt:create_app`      | WebSocket gateway at `/v1/ws` (quiz engine later)      |
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
configuration. `APP_ENV=prod` refuses to start unless the database and Redis URLs and the Ed25519
JWT key pair are set explicitly and `APP_DEV_LOGIN_ENABLED` is false. Dev and test generate an
ephemeral signing key per process.

## Running the processes

```bash
uv run uvicorn app.main_api:create_app --factory --port 8000 --no-proxy-headers
uv run uvicorn app.main_rt:create_app --factory --port 8001 --no-proxy-headers --ws-max-size 65536
uv run python -m app.main_worker
```

Client IPs honour `X-Forwarded-For` only from `APP_TRUSTED_PROXIES`; `--no-proxy-headers` keeps
uvicorn from rewriting them first. The worker stops on SIGTERM/SIGINT after in-flight jobs
finish (10 s grace).

## Migrations

```bash
uv run alembic upgrade head                                  # uses APP_DATABASE_URL
uv run alembic revision --autogenerate -m "add users" --rev-id 0002
uv run alembic upgrade head --sql                            # print SQL instead of running it
```

Revision ids are sequential (`--rev-id`). New models must be imported in `app/models.py` so
autogenerate sees them; `tests/test_db.py` fails if the models and migrations drift apart. The
baseline creates `citext`, `pg_trgm`, `app_config` and `audit_log`; an `append_only_guard()`
trigger rejects UPDATE, DELETE and TRUNCATE on `audit_log`.

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
it and flush Redis). Alembic upgrades once per run; each test then runs in an outer transaction
that is rolled back, with app sessions joined through SAVEPOINTs so code that commits still
works. Redis is flushed before each test that uses it.

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
  enum fields as `Lax[...]` so their JSON string forms are accepted.
- **Rate limits.** `Depends(rate_limit("auth.nonce", capacity=10, refill_per_sec=10 / 60))` runs
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
                                             logging, middleware, security, ratelimit,
                                             idempotency, pagination, schemas, factory
  modules/system/                            /healthz, /readyz, /v1/config; app_config, audit_log
  modules/realtime/                          /v1/ws gateway skeleton and protocol constants
alembic/                                     async env.py and revisions
scripts/dev_services.sh                      local Postgres and Redis
tests/                                       pytest suite (real Postgres and Redis)
```

## Docker

```bash
docker build -t quiz-backend .
docker run --env-file .env.prod quiz-backend alembic upgrade head
docker run --env-file .env.prod -p 8000:8000 quiz-backend                     # api
docker run --env-file .env.prod quiz-backend python -m app.main_worker        # worker
```

The image is multi-stage (dependencies installed with uv, then copied into a slim runtime), runs
as an unprivileged user with `APP_ENV=prod` by default, and has a `/healthz` healthcheck. The
header of the `Dockerfile` lists the command for each process.
