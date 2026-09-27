#!/usr/bin/env bash
# Local PostgreSQL 16 and Redis 7 for development and tests, run as plain processes (no Docker).
#
#   scripts/dev_services.sh start    initialise if needed, start both, provision role/databases
#   scripts/dev_services.sh stop     stop both
#   scripts/dev_services.sh status   show state (exit 1 if either is down)
#   scripts/dev_services.sh reset    stop, delete all local data, start fresh
#   scripts/dev_services.sh env      print the environment variables to use
#
# Everything lives in backend/.dev/ (gitignored). Postgres listens on 127.0.0.1:$PG_PORT with its
# Unix socket inside .dev; Redis on 127.0.0.1:$REDIS_PORT without persistence. Every command is
# idempotent. Postgres refuses to run as root, so when invoked as root the cluster runs as the
# `postgres` OS user (or a `pgdev` system user, created on first use).
#
# Overridable: PG_PORT (54329), REDIS_PORT (63790), PG_BIN (pg_ctl directory), PG_LOCALE (C.UTF-8).
set -euo pipefail

BACKEND_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEV_DIR="${BACKEND_DIR}/.dev"
PG_DIR="${DEV_DIR}/pg"
PG_DATA="${PG_DIR}/data"
PG_SOCKET_DIR="${PG_DIR}/run"
PG_LOG="${PG_DIR}/postgres.log"
REDIS_DIR="${DEV_DIR}/redis"

PG_PORT="${PG_PORT:-54329}"
REDIS_PORT="${REDIS_PORT:-63790}"
PG_LOCALE="${PG_LOCALE:-C.UTF-8}"
DB_ROLE="quiz"
DB_PASSWORD="quiz" # local development only
DATABASES=(quiz_dev quiz_test)
EXTENSIONS=(citext pg_trgm)

die() {
  echo "error: $*" >&2
  exit 1
}

find_pg_bin() {
  if [[ -n "${PG_BIN:-}" ]]; then
    echo "${PG_BIN}"
  elif [[ -x /usr/lib/postgresql/16/bin/pg_ctl ]]; then
    echo /usr/lib/postgresql/16/bin
  elif command -v pg_ctl >/dev/null 2>&1; then
    dirname "$(command -v pg_ctl)"
  else
    die "PostgreSQL 16 binaries not found; set PG_BIN to the directory containing pg_ctl"
  fi
}
PG_BIN="$(find_pg_bin)"

PG_OS_USER=""
if [[ "$(id -u)" -eq 0 ]]; then
  if id postgres >/dev/null 2>&1; then
    PG_OS_USER="postgres"
  else
    PG_OS_USER="pgdev"
  fi
fi

# Run a command as the OS user that owns the cluster.
as_pg() {
  if [[ -n "${PG_OS_USER}" ]]; then
    runuser -u "${PG_OS_USER}" -- "$@"
  else
    "$@"
  fi
}

# psql as the cluster superuser, over the private Unix socket.
psql_admin() {
  as_pg env PGOPTIONS="--client-min-messages=warning" "${PG_BIN}/psql" -X -q \
    -v ON_ERROR_STOP=1 -h "${PG_SOCKET_DIR}" -p "${PG_PORT}" -U postgres "$@"
}

pg_running() {
  [[ -f "${PG_DATA}/PG_VERSION" ]] && as_pg "${PG_BIN}/pg_ctl" -D "${PG_DATA}" status >/dev/null 2>&1
}

init_postgres() {
  [[ -f "${PG_DATA}/PG_VERSION" ]] && return
  echo "postgres: initialising cluster in ${PG_DATA}"
  if [[ "${PG_OS_USER}" == "pgdev" ]] && ! id pgdev >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin pgdev
  fi
  mkdir -p "${PG_DATA}" "${PG_SOCKET_DIR}"
  if [[ -n "${PG_OS_USER}" ]]; then
    chown -R "${PG_OS_USER}:" "${PG_DIR}"
  fi
  chmod 700 "${PG_DATA}" "${PG_SOCKET_DIR}"
  as_pg "${PG_BIN}/initdb" -D "${PG_DATA}" -U postgres --encoding=UTF8 --locale="${PG_LOCALE}" \
    --auth-local=trust --auth-host=scram-sha-256 >/dev/null
  as_pg tee -a "${PG_DATA}/postgresql.conf" >/dev/null <<EOF

# --- scripts/dev_services.sh ---
listen_addresses = '127.0.0.1'
port = ${PG_PORT}
unix_socket_directories = '${PG_SOCKET_DIR}'
# Throwaway local cluster: trade crash safety for speed.
fsync = off
synchronous_commit = off
full_page_writes = off
EOF
}

provision_postgres() {
  psql_admin -d postgres <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${DB_ROLE}') THEN
    CREATE ROLE ${DB_ROLE} LOGIN PASSWORD '${DB_PASSWORD}';
  END IF;
END
\$\$;
SQL
  local db ext
  for db in "${DATABASES[@]}"; do
    if [[ -z "$(psql_admin -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname = '${db}'")" ]]; then
      psql_admin -d postgres -c "CREATE DATABASE ${db} OWNER ${DB_ROLE}"
    fi
    for ext in "${EXTENSIONS[@]}"; do
      psql_admin -d "${db}" -c "CREATE EXTENSION IF NOT EXISTS ${ext}"
    done
  done
}

start_postgres() {
  init_postgres
  if pg_running; then
    echo "postgres: already running on 127.0.0.1:${PG_PORT}"
  else
    as_pg "${PG_BIN}/pg_ctl" -D "${PG_DATA}" -l "${PG_LOG}" -w -t 30 start >/dev/null ||
      die "postgres failed to start; see ${PG_LOG}"
    echo "postgres: started on 127.0.0.1:${PG_PORT}"
  fi
  provision_postgres
}

stop_postgres() {
  if pg_running; then
    as_pg "${PG_BIN}/pg_ctl" -D "${PG_DATA}" -m fast -w stop >/dev/null
    echo "postgres: stopped"
  else
    echo "postgres: not running"
  fi
}

redis_cli() {
  redis-cli -h 127.0.0.1 -p "${REDIS_PORT}" "$@"
}

redis_running() {
  [[ "$(redis_cli ping 2>/dev/null)" == "PONG" ]]
}

start_redis() {
  if redis_running; then
    echo "redis: already running on 127.0.0.1:${REDIS_PORT}"
    return
  fi
  command -v redis-server >/dev/null 2>&1 || die "redis-server not found on PATH"
  mkdir -p "${REDIS_DIR}"
  redis-server --bind 127.0.0.1 --port "${REDIS_PORT}" --daemonize yes \
    --dir "${REDIS_DIR}" --pidfile "${REDIS_DIR}/redis.pid" --logfile "${REDIS_DIR}/redis.log" \
    --save "" --appendonly no
  local _
  for _ in $(seq 50); do
    redis_running && break
    sleep 0.1
  done
  redis_running || die "redis failed to start; see ${REDIS_DIR}/redis.log"
  echo "redis: started on 127.0.0.1:${REDIS_PORT}"
}

stop_redis() {
  if redis_running; then
    redis_cli shutdown nosave >/dev/null 2>&1 || true
    echo "redis: stopped"
  else
    echo "redis: not running"
  fi
}

print_env() {
  cat <<EOF

# api / rt / worker against the development database (these are also the built-in defaults):
export APP_ENV=dev
export APP_DATABASE_URL=postgresql+asyncpg://${DB_ROLE}:${DB_PASSWORD}@127.0.0.1:${PG_PORT}/quiz_dev
export APP_REDIS_URL=redis://127.0.0.1:${REDIS_PORT}/0

# Tests default to the test database and Redis DB 15; override only to point them elsewhere:
#   APP_DATABASE_URL=postgresql+asyncpg://${DB_ROLE}:${DB_PASSWORD}@127.0.0.1:${PG_PORT}/quiz_test
#   APP_REDIS_URL=redis://127.0.0.1:${REDIS_PORT}/15
EOF
}

status() {
  local healthy=0
  if pg_running; then
    echo "postgres: running on 127.0.0.1:${PG_PORT} (data: ${PG_DATA})"
  else
    echo "postgres: stopped"
    healthy=1
  fi
  if redis_running; then
    echo "redis: running on 127.0.0.1:${REDIS_PORT}"
  else
    echo "redis: stopped"
    healthy=1
  fi
  return "${healthy}"
}

case "${1:-}" in
  start)
    start_postgres
    start_redis
    print_env
    ;;
  stop)
    stop_redis
    stop_postgres
    ;;
  status) status ;;
  reset)
    stop_redis
    stop_postgres
    rm -rf "${DEV_DIR}"
    echo "removed ${DEV_DIR}"
    start_postgres
    start_redis
    print_env
    ;;
  env) print_env ;;
  *)
    echo "usage: $(basename "$0") start|stop|status|reset|env" >&2
    exit 2
    ;;
esac
