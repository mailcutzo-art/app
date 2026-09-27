# Running the backend with Docker

`docker-compose.yml` runs everything the app needs on one machine:

| Service | What it does | Reachable from |
|---|---|---|
| `caddy` | Front door: HTTPS (or plain HTTP on your network), sends `/v1/ws` to `rt` and the rest to `api` | Your network / the internet |
| `api` | REST API (FastAPI) | Caddy only |
| `rt` | Realtime WebSocket server for live battles | Caddy only |
| `worker` | Background jobs (tournaments, settlement retries, notifications) | Nothing |
| `migrate` | Applies database migrations, then exits; the others wait for it | Nothing |
| `postgres` | PostgreSQL 16, the source of truth | Backend services only |
| `redis` | Redis 7: live match state, queues, rate limits | Backend services only |

Postgres and Redis publish no ports and have no internet access. All passwords and keys live in
`infra/.env`, which `init-env.sh` generates and git ignores.

## Test with your phone on your own network

1. Install [Docker Desktop](https://www.docker.com/products/docker-desktop/) (Windows, macOS) or
   Docker Engine (Linux).
2. Start the backend (the first build takes a few minutes):

   ```bash
   cd infra
   ./init-env.sh lan          # Windows: run this line in Git Bash or WSL
   docker compose up -d --build
   ```

3. Check it: <http://localhost:8080/readyz> should show `"status":"ok"`.
4. Find your computer's local IP address (Windows `ipconfig`, macOS `ipconfig getifaddr en0`,
   Linux `hostname -I`), for example `192.168.1.20`.
5. Install the debug APK: GitHub → **Actions** → latest **mobile** run → artifact
   `quiz-app-debug-apk`.
6. In the app, tap **Debug settings** on the sign-in screen, set **API base URL** to
   `http://192.168.1.20:8080`, then **Save**.
7. Tap **Developer login** and use any email. Each email is a separate test account, so you can
   test with several accounts on several phones.

If the phone can't connect, allow port 8080 through your computer's firewall, and make sure both
devices are on the same Wi‑Fi.

`lan` mode turns on developer login, which lets anyone who can reach port 8080 sign in as any
email. Only use it on a network you trust.

## Run on a server

1. Get a Linux server (a Mumbai region keeps battles snappy for Indian players) with Docker, and
   point a DNS record such as `api.example.com` at it. Open ports 80 and 443.
2. On the server:

   ```bash
   cd infra
   ./init-env.sh prod api.example.com
   # edit .env: set APP_GOOGLE_CLIENT_IDS to your Google OAuth client id(s)
   docker compose up -d --build
   ```

   Caddy fetches a TLS certificate automatically on the first request.
3. Build the release app with `--dart-define=API_BASE_URL=https://api.example.com`.

## Everyday commands

```bash
docker compose ps                          # what's running and healthy
docker compose logs -f api rt worker       # follow the backend logs
docker compose up -d --build               # apply an update after git pull (runs migrations)
docker compose down                        # stop everything; data is kept
docker compose down -v                     # stop and DELETE all data
docker compose exec postgres psql -U quiz quiz                     # database shell
docker compose exec -T postgres pg_dump -U quiz quiz | gzip > backup.sql.gz   # backup
gunzip -c backup.sql.gz | docker compose exec -T postgres psql -U quiz quiz   # restore into an empty database
```

## Settings

`init-env.sh` writes every setting with a comment. The ones you may change later:

| Variable | Meaning |
|---|---|
| `APP_GOOGLE_CLIENT_IDS` | Google OAuth client id(s) for sign-in, comma-separated |
| `SITE_ADDRESS` | `:80` for plain HTTP, or your domain for HTTPS |
| `HTTP_PORT`, `HTTPS_PORT` | Host ports Caddy listens on |
| `APP_MIN_BUILD` | Builds below this number must update before playing |
| `APP_MAINTENANCE` | `true` shows a maintenance screen in the app |
| `ADMIN_ALLOW_IPS` | Space-separated IPs or CIDRs allowed to open `/admin`, in quotes (default: anywhere; admin sign-in is still required) |
| `EDGE_SUBNET` | Docker subnet for Caddy and the backend (change only if it clashes with your network) |

Don't change `POSTGRES_PASSWORD` after the first start: the database volume keeps the old
password. Replacing the JWT key is harmless: apps quietly fetch a new access token with their
refresh token.
