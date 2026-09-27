# Plan — Rebuild the quiz battle app from scratch (Flutter + Python FastAPI + PostgreSQL)

## Context
`mailcutzo-art/app` is empty (no commits). The user shared 5 screenshots of an existing competitive quiz app for Indian exam aspirants (tabs Home · Learn · Battle · Arena · Social · Profile) and wants it rebuilt properly:
- **Stack:** **Flutter (Dart)** mobile app, switched from Kotlin at the user's request. The backend is Python and the database PostgreSQL.
- **Scope:** the screenshot features all work for real. **Lessons** are dropped, and I write the starter question content.
- **Quality bar:** deep planning for each feature (options, edge cases, security), plus smooth, fast UI. The original showed "Couldn't load … Retry" errors and a duplicated Coach card, so robustness is an explicit goal.
- **UI:** a new look from the user's 3 references (pastel, minimal, bigger rounded buttons). Icons come from **Hugeicons stroke‑rounded** and animations from **AnimateIcons**. Transitions must be smooth and quick.
- **Order the user asked for:** build the design system and theming first, then the features.

### Decisions confirmed with the user
| Topic | Decision |
|---|---|
| Client | **Flutter 3.47 / Dart 3.13**, Android first. The code is iOS-ready, but iOS builds need a Mac or a macOS CI runner later. |
| Sign-in | **Google Sign-In only.** A dev-only login (disabled in production) exists for local testing and protocol bots. |
| Core quiz flow | **Quick Battle:** pick subject → **chapter** (or "All chapters") → Rated/Casual → **Find opponent** → 1v1 live quiz. The "Join Live Class Quiz" card is removed. |
| No opponent found | After **15 s**, the search widens to other chapters in the same subject, and questions are split between both chapters. After **45 s** (20 s on a player's first-ever search), the app offers **Keep searching**, **Invite a friend**, or a clearly labelled **Practice Bot** game (unrated, no coins). Everyone gets the bot offer, including rated searchers, and the Battle tab can start a bot game directly. The app shows how many players are searching and the typical wait. |
| Scheduled events | **Only tournaments are scheduled.** There are no scheduled live quizzes, **no PIN/QR rooms** and no teacher accounts. |
| Private play | **Play with Friend** (1v1) and **Group Battle** (2–8 players), joined by invite, link or 6-character code. |
| Content for now | **A small test set only** for NEET + JEE (Physics, Chemistry, Biology, Maths): 2 chapters per subject with 8 questions each, plus one Fun & Learn passage and five Guess-the-Word terms per subject. It exercises every feature; the real bank is imported later. There's no Current Affairs. |
| Existing bank | None. I build a CSV/JSON importer and an admin panel. |
| Flows | Every journey is mapped step by step in `docs/user-flows.md`. **No dead ends and no silent outcomes:** every refund, cancellation, forfeit and prize is explained on screen and kept in the Inbox. Battles, tournaments, practice, coins, XP and ranks can all be found again later (History, Wallet, Leaderboards) |
| Answer tracking and tips | Every question references **subject → chapter → topic** and has a **difficulty** and a **category** (concept, numerical, factual, application). Every answer stores the option picked, whether it was right, the **time taken** and, in multiplayer games, whether it was **fast, slow or even** compared with the opponents. Students see **short plain-language tips** ("Focus on Projectile motion", "Practise more Physics numericals"), not charts. |

### Assumptions (the user can veto these when approving the plan)
- **Android first:**
  - Flutter's default minSdk, and targetSdk 36 (Play's current requirement).
  - Edge-to-edge layout and predictive back (Flutter supports both).
  - Only plugins that support 16 KB memory pages.
- **Coins are earned only.** They can't be bought or cashed out, which keeps the app clear of India's 2025 ban on real-money online games. The ledger has a separate "purchased" bucket reserved for later, which can never be spent on entry fees. There's no monetization in v1.
- **No free-text chat and no photo uploads in v1**, because users may be minors. Instead there are preset in-battle emotes and preset avatars: pastel circles with a Hugeicons symbol.
- **The nav goes from 6 tabs to 5:** Home, Learn, Battle, Arena, Social. Profile opens from the avatar in each tab's header, which fits the references' minimal floating nav.
- **"Browse live contests"** opens Arena filtered to Live and Upcoming tournaments.
- **All daily resets use IST (00:00 Asia/Kolkata):** missions, streaks, weekly boards and daily caps. That also closes a timezone exploit.
- **Starter questions** are tagged "starter, needs expert review". An in-app "Report question" button feeds an admin review queue.
- **The repo is public.** Secrets are never committed. The user should make it private if they prefer.

---

## Environment facts (checked) and what the user needs to do
- **This container has:** Python 3.11 with uv, PostgreSQL 16 server binaries, Redis 7, Node 22, JDK 21 and Chromium/Playwright. It has no Docker daemon and no KVM, so no Android emulator.
- **Flutter works here.** The Flutter SDK (storage.googleapis.com), pub.dev and git are all reachable. That means `flutter analyze`, `flutter test`, **golden screenshot tests** and `flutter build web` all run in this container. I can also open the web build in Chromium to screenshot and click through screens.
- **`dl.google.com` is blocked** by the environment's network policy, so the Android SDK can't be downloaded and **APKs can't be built here**.
  - **User action (optional):** in the cloud environment menu in the session title bar, choose Edit → Network access, and add **`dl.google.com`** to the allowed domains.
  - **Until then:** GitHub Actions builds the APK on every push. The user can download it from the Actions page.
- **`hugeicons.com` and `animateicons.in` are blocked,** but both icon sets are reachable through package registries:
  - The official **`hugeicons` Flutter package** (pub.dev 1.2.0) and `@hugeicons/core-free-icons` (npm, MIT) cover 6,000+ stroke-rounded icons at 24×24 with a 1.5 stroke. Every icon needed is there, for example Home01, BookOpen01, Swords, Champion, UserGroup, Atom01, TestTube01, Dna01, Pi, Timer02, Fire, Coins01, Notification03, Bookmark02, Robot01 and Idea01.
  - `@animateicons/react` 0.6.0 (MIT) has motion keyframe recipes, which I port to Flutter animations.
- **Fonts:** Plus Jakarta Sans TTF files (OFL), bundled in the app rather than fetched at runtime.
- **The user supplies later:**
  - **Google Cloud OAuth client IDs:** a web client ID, plus an Android client for each signing key's SHA-1. I'll give the steps.
  - **Firebase `google-services.json`** for push. The build works without it and push is simply off.
  - **A host and domain** for testing on a real phone and for App Links. Until then, docker compose on the user's PC over Wi‑Fi works, because debug builds allow cleartext to a LAN IP.

---

## Architecture
```
Flutter app       ──HTTPS /v1──► api  (FastAPI REST, N replicas)          ─┐
        └────────WSS /v1/ws───► rt   (WS gateway + quiz engine, N replicas)├─► PostgreSQL 16 (truth: settled data, ledger)
                                worker (tournament ticks, outbox, settlement ├─► Redis 7 (live state, queues, pub/sub,
                                        retries, missions, leaderboards)    ─┘            leases, ZSETs, rate limits)
Admin panel (SQLAdmin; Google OAuth, admin role, optional IP allowlist) is served by api.
```
- **One codebase, three process types.** `api`, `rt` and `worker` each scale on their own. Coordination goes through Redis leases and Postgres `SKIP LOCKED`.
- **The server is authoritative.** Clients only send intents. The server owns question choice, timing, scoring and results.
- **One clock.** Every match timestamp is Redis `TIME`, read inside Lua scripts, so rt nodes can never disagree about time.
- **One busy slot per user.** `busy:{uid}` holds exactly one of these: a queue ticket, a match, a room or a tournament. Every way into a game checks it and sets it atomically.
- **One engine for every live mode.** Quick Battle, Practice Bot, Friend duel, Group Battle and tournament games all run through the same state machine. Only the config and the settlement hooks differ.
- **Side effects go through a transactional outbox.** That covers leaderboards, pushes, activity feed and achievements. Postgres commits, and the worker delivers.
- **IDs and wire format.** UUIDv7 IDs. Human-facing codes are separate from IDs. JSON text frames, protocol v1.

### Repository layout (monorepo on branch `claude/determined-franklin-p6nr0f`)
```
mobile/             Flutter app (lib/app, lib/core, lib/features/*), test/ (unit, widget, golden), integration_test/
mobile/packages/design_system/   Flutter package: tokens, theme, icons, motion, widgets + golden tests; example/ = catalog app (web-buildable)
backend/            pyproject (uv), alembic/, app/ (main_api.py, main_rt.py, main_worker.py, modules), tests/, scripts/
content/            test content YAML (goals, subjects, chapters, topics, questions, passages, words) + validator
infra/              docker-compose.yml (api, rt, worker, postgres, redis, caddy), Caddyfile, .env.example
docs/               protocol.md, matchmaking.md, tournaments.md, economy.md, security.md, design-system.md, content-format.md
.github/workflows/  backend.yml (ruff, mypy, pytest with PG+Redis services), mobile.yml (analyze, test + goldens, build APK artifact)
```

### Backend (Python ≥ 3.11, FastAPI)
- **Libraries:**
  - Web and data: FastAPI, Uvicorn with uvloop, SQLAlchemy 2.0 async with asyncpg, Alembic, Pydantic v2 (strict mode, `extra="forbid"`) with pydantic-settings, redis-py asyncio.
  - Auth and logging: google-auth, PyJWT (EdDSA), structlog.
  - Features: networkx (Swiss pairing), ziamath (LaTeX to SVG), SQLAdmin, httpx (FCM v1).
  - Testing and linting: ruff, mypy, pytest, pytest-asyncio, hypothesis, and `websockets` for the protocol bots.
- **`app/core`:** config, db, redis, clock, ids, errors (standard `{error:{code,message,details,request_id}}`), rate limiting (Redis token bucket Lua), idempotency, security, logging (with PII redaction), pagination.
- **Modules:**
  - Accounts and learning: `auth`, `users`, `content`, `practice`, `coach`.
  - Live play: `realtime` (gateway, protocol, registry, bus; `engine/` holding the FSM, scoring, timers, leases, snapshot and `lua/*.lua`; `matchmaking/`, `rooms/`, `bots/`, `anticheat`), `matches` (settlement, history, review), `tournaments` (lifecycle, pure `swiss_pairing`, pure `standings`, prizes, templates).
  - Scoring and rewards: `ratings` (pure `glicko2`, leaderboards), `economy` (wallet, ledger, holds, rewards config), `progression` (XP, levels, missions, streaks, achievements).
  - Community: `social`, `notifications`, `moderation`.
  - Platform: `home`, `admin`, `outbox`.
- **API conventions:**
  - Cursor pagination.
  - ETag for content and standings.
  - An `Idempotency-Key` header on every POST that moves coins or creates an entity.
  - `/v1/config` returns `min_build`, a maintenance flag, and feature flags.

### Mobile app (Flutter 3.47, Dart 3.13; Android first, iOS-ready)
- **Layout:**
  - `mobile/lib/app/` holds the `App` widget, router, environment config and bootstrap.
  - `mobile/lib/core/` holds `network` (dio client, interceptors, error mapping), `realtime` (WS client, protocol, `ServerClock`), `storage` (secure storage, drift cache, prefs), `state` (async-state helpers and section widgets), `notifications` and `utils`.
  - `mobile/lib/features/<name>/{data,domain,presentation}` for each of `auth`, `onboarding`, `home`, `learn`, `practice`, `search`, `bookmarks`, `battle`, `rooms`, `arena`, `leaderboard`, `social`, `profile`, `settings` and `inbox`.
  - `mobile/packages/design_system` is a standalone package with its own golden tests and a catalog app (`example/`).
- **Libraries:**
  - **State and dependency injection:** Riverpod 3 (`flutter_riverpod`), using `Notifier` and `AsyncNotifier`.
  - **Routing:** `go_router` with `StatefulShellRoute.indexedStack` (5 tabs, state kept per tab), plus `app_links` for deep links (`/j/*`, `/t/*`, `/u/*`).
  - **Network and data:** `dio` with a `QueuedInterceptor` so only one token refresh runs at a time, `web_socket_channel`, and `freezed` with `json_serializable` for models.
  - **Storage:** `drift` (SQLite) for the offline cache and sync queue. `flutter_secure_storage` (Keystore/Keychain) holds the refresh token. The access token lives only in memory.
  - **Platform:** `google_sign_in` 7 (Credential Manager on Android, with a server client ID and nonce), `firebase_messaging` (optional), `cached_network_image` and `flutter_svg`.
  - **Motion:** `animations` for shared-axis, fade-through and container-transform transitions.
  - **Testing:** `flutter_test` with goldens, `mocktail`, and `integration_test`.
- **Robustness pattern:**
  - Each section has its own state: Loading (a skeleton), Content (data, refreshing, stale age), Empty (with a call to action), Error (retry, plus automatic retry on reconnect) and Offline (cached data).
  - Cards render and fail independently.
  - The drift cache serves stale data while it revalidates, so screens open instantly.
  - Lists use `ListView.builder` / slivers with stable keys.
  - There are never bare error screens.
- **Performance:**
  - The Impeller renderer.
  - `const` widgets, `RepaintBoundary` around animations, and Riverpod `select` to cut rebuilds.
  - Images are cached and downsampled with `cacheWidth`.
  - Release builds use `--obfuscate --split-debug-info`.
  - Startup does only minimal work, and the rest is initialised lazily.
  - `flutter build apk --analyze-size` in CI, to watch app size.

---

## Phase 0 — Repo and CI scaffolding
- **Repo basics:** monorepo skeleton, `.gitignore`, `.editorconfig`, README, `infra/docker-compose.yml` and `.env.example`.
- **CI:** backend and Android workflows.
- **Local services:** `backend/scripts/dev_services.sh` runs `pg_ctl` and `redis-server` in this container.

## Phase 1 — Design system and theming (the base; ends with a user review checkpoint)
**Visual language (from the references)**
- A warm off-white "paper" background, with a soft mint→lemon gradient behind hero areas (ref 1).
- White cards with 24–28dp corners and hairline borders, not heavy shadows.
- Near-black **ink** for the strongest controls: FAB, the selected segment and the active nav circle (refs 1 and 2).
- A **lime** pill for the primary call to action (ref 3 "Book Now").
- **Pastel tiles** with the icon in a white circle (ref 2).
- Big bold headlines with tight tracking (ref 2).
- Circular icon buttons with dot badges, and a floating pill bottom nav.
- A dot-matrix chart with a lemon tooltip (ref 1).

**Tokens** (in `packages/design_system/lib/src/tokens`, exposed through a `ThemeExtension`; these values are proposals, tuned at the checkpoint)
- **Light colors:**
  - Base: `paper #F5F6F0`, `surface #FFFFFF`, `surfaceMuted #F0F1EA`, `outline #E6E8DF`.
  - Text: `ink #141813`, `inkMuted #5E645B`, `inkSubtle #9AA095`.
  - Brand: `lime #CBE54E` (primary, with ink text) and `limeSoft #EEF7C4`.
  - Pastel pairs (container / on-color): sky `#DDEEFB/#2C6E9E`, mint `#DDF2E3/#2F7A4C`, lemon `#FBF4C4/#7D6A0E`, lavender `#EAE4F8/#65499F`, peach `#FCE5D6/#A9542A`, rose `#FAE1E6/#A8354F`.
  - Status: success `#2F9E5E`, error `#D84A4A` and warning `#C68A0A`, each with a pastel background.
  - Subjects: Physics is sky, Chemistry lavender, Biology mint, Maths peach, and All chapters lemon.
- **Dark theme:** paper `#0E110F`, surface `#161A17`, ink `#F1F4EC`, lime `#D3EC5C`. Pastel tiles become about a 16% tint of their on-color over the surface. A unit test checks WCAG AA contrast for every text/background pair.
- **Type:**
  - **Plus Jakarta Sans** as a variable font (Manrope as fallback).
  - Display 40 bold (−2% tracking), Headline 32 / 26, Title 20 / 17 semibold, Body 16 / 14, Label 15 semibold for buttons, Caption 12, and Overline 11 in caps (+6% tracking).
  - Timers and scores use tabular digits.
- **Shape:** 8, 12, 16, 20, 24, 28 and 32dp, plus pill.
- **Spacing:** a 4dp grid with a 20dp gutter.
- **Sizes (bigger, as requested):**
  - Buttons: L **60dp**, M **52dp** and S 40dp, all pill-shaped.
  - Icon buttons: **52dp** circles.
  - Answer options: at least **68dp** tall with 20dp corners.
  - Chips 40dp, nav 72dp.
  - Minimum touch target 48dp.
- **Motion:**
  - Durations of 150, 250 and 400 ms, with emphasized easing.
  - Buttons spring down to 0.96 scale with a light haptic when pressed.
  - `MediaQuery.disableAnimations` (the system's reduce-motion setting) turns off non-essential animation.

**Icons**
- **Icon source:** the official `hugeicons` Flutter package (stroke-rounded free set: path data with a 1.5 stroke and round caps and joins). A thin `AppIcon` wrapper applies theme color and size.
- **`AnimatedHugeIcon`** is a `CustomPainter` that draws each icon's SVG paths with its own transform (rotation, translation, scale, and path trimming via `PathMetric`). It's driven by `IconMotion` keyframe specs using `TweenSequence` on an `AnimationController`.
  - The specs are ported from AnimateIcons recipes. For example, the notification bell rotates through `[0,7,-18,14,-9,5,-2,0]` over 1.3 s from a pivot at the top, and the clapper follows its own `x` keyframes.
  - Trophy, swords, timer, flame, zap, crown, medal, users and house exist in AnimateIcons only as Lucide icons, so their recipes are applied to the Hugeicons paths.
- **Animation triggers:** a tap, nav selection, a state change (such as a bookmark being added) or an event (such as a notification arriving).
- **Credits:** an Open-source licenses screen.

**Components** (every state in light and dark, each with a golden screenshot test)
- **Buttons:**
  - Types: Primary (lime), Ink, Secondary, Tonal, Text, IconButton (surface, tonal or ink, with a badge) and FAB.
  - Every button supports loading at a fixed width, disabled, leading and trailing icons, and press animation.
- **Selection:**
  - SegmentedControl, with an animated sliding ink pill (Rated/Casual).
  - FilterChip and ChoiceChip, with a subject dot.
  - Switch, Radio, Checkbox, Stepper and an option row.
  - **ChapterPickerSheet:** "All chapters" plus each chapter with its question count and your accuracy. Chapters too thin for battles show as "Coming soon".
- **Containers:**
  - SurfaceCard and PastelTile.
  - **HeroStatCard:** ref 1's lemon card, with a big number and an action row.
  - ListRowCard.
  - **TournamentCard:** pastel gradient by subject, overline badges, info chips, a capacity bar and a call to action.
  - BottomSheet (32dp top corners), Dialog, and a floating pill Snackbar.
- **Navigation:**
  - FloatingPillNavBar: the active circle is filled with ink, with an animated icon and a label pill.
  - LargeTitleHeader and a TopBar with a circular back button.
- **Data display:**
  - Avatar (presence dot, ring, preset symbol) and AvatarStack.
  - ProgressBar and SegmentedProgress.
  - **CountdownRing,** driven by the frame clock from the server deadline, with a color shift as time runs low.
  - **NumberTicker.**
  - RatingDelta.
  - LeaderboardRow, with a sticky row for you.
  - Podium.
  - **DotMatrixChart.**
  - A lemon Tooltip chip.
- **Matchmaking:**
  - **SearchingPulse:** a radar animation with elapsed time and a status line such as "Widened to all of Physics".
  - A match-found card and a VS header.
- **Quiz:**
  - **QuestionCard** with a rich stem built from text, superscript, subscript, bold, italic and `math`. Math nodes are LaTeX, rendered to SVG on the server at import and shown inline through `WidgetSpan` with `flutter_svg`. Everything else renders natively as `TextSpan`s.
  - **AnswerOption:** idle, selected, locked or waiting, correct (mint fill with the check drawing in), wrong (rose fill with a shake), and a marker for the opponent's pick.
  - VersusHeader, EmoteBar, ResultSummary and ExplanationSheet.
- **Feedback:** EmptyState, ErrorState (always with retry), shimmer skeletons shaped like the real layout, OfflineBanner, PullToRefresh, and a ConfettiOverlay drawn with Canvas.
- **Inputs:** SearchField (pill), TextField (20dp corners with the label above) and **CodeInput** (6 boxes, with paste).

**Transitions**
- Fade-through between tabs.
- Shared-axis X within a flow.
- **Shared elements** (`Hero`, plus `OpenContainer` container transforms) for:
  - tournament card → detail
  - subject tile → subject screen
  - match-found avatars → VS screen
- Predictive back everywhere.
- Skeletons, never spinners.
- NumberTicker whenever a value changes.

**Checkpoint:**
- Render the catalog plus mock Home, Battle and Question screens to PNG with golden tests, and build the catalog for the web. Share the PNGs and an interactive web catalog with the user, and adjust the tokens before any feature UI.
- If the Android build is still blocked here, the PNGs come from CI.

## Phase 2 — Foundations: backend core, auth, app shell
**Backend core**
- App factories for api, rt and worker; settings; async DB; Alembic baseline; Redis.
- Structured logs with request IDs, the rate limiter, the idempotency middleware, and health/ready endpoints.

**Auth (Google only)**
- **Sign-in flow:**
  1. `google_sign_in` 7 (Credential Manager on Android) returns a Google ID token. The plugin can only be initialized once per process, so the app sets a random nonce at initialization rather than a fresh server nonce per attempt.
  2. `POST /v1/auth/google` verifies the signature, `aud` (the web client ID), `iss`, `exp` and `email_verified`.
  3. **Replay protection:** the token must be fresh (`iat` within 10 minutes) and is accepted **once** (a SHA-256 of the token is stored in Redis until it expires).
  4. The server upserts the user by `(provider, sub)`, never by email, and creates a device session. Each user can have at most 5 sessions.
- **Access token:** an EdDSA JWT valid for 15 minutes, carrying `sub, sid, roles, ver, jti`, with keys rotated by `kid`. Every request checks `revoked_sid:{sid}` in Redis, so bans and logouts take effect instantly.
- **Refresh token:**
  - An opaque 256-bit token, stored hashed.
  - It expires after 30 days of inactivity (90 days at most) and rotates on every use.
  - **Reuse detection** revokes the whole token family and sends a security push.
  - **Crash grace:** if the same session presents a just-used token again within 60 s, the server returns the same successor instead of treating it as reuse. That covers an app crash after the server rotated the token.
- **Endpoints:** `GET /v1/me/sessions` and `DELETE` for signing out one device, all others, or everything.
- **Dev login:** `POST /v1/auth/dev-login` exists only when `ENV=dev`. The app refuses to start in production if it's enabled.

**Users and onboarding**
- **Profile:**
  - Display name.
  - A unique handle: citext, 3–20 characters from `[a-z0-9_]`, checked for profanity and reserved words, with a live availability check.
  - A preset avatar.
  - Goal: NEET or JEE.
  - **Birth year** as an age gate. Minors get safer defaults: presence visible to friends only, and friend requests only from people they've played.
- **Roles** are user, moderator and admin. **Statuses** are active, restricted, banned, pending_deletion and deleted.
- **Onboarding order:** Google sign-in, then name and handle, then avatar, then goal, then birth year, then notification permission with an explanation, then Home.

**Admin panel**
- SQLAdmin, restricted to Google OAuth accounts with the admin role, with an optional IP allowlist.
- Every write is audit-logged with before and after JSON.
- `scripts/create_admin.py` creates the first admin.

**App shell**
- **Structure:**
  - A single `MaterialApp.router`, edge-to-edge, with a native splash screen (`flutter_native_splash`).
  - The nav graph runs the auth gate, then onboarding, then the 5 tabs.
- **Deep links:** `/j/<code>` (friend and group invites; the web fallback goes to the Play Store with the code in the install referrer), `/t/<id>`, `/u/<handle>`.
  - **A pending destination survives sign-in and onboarding.** A link or notification opened while signed out is kept by the router and opened once the user reaches Home.
- **Startup gates:** `GET /v1/config` runs alongside session restore (the last good config is cached).
  - **Update required** blocks the app when `build < min_build`, on any `426`, or on a `4426` realtime close.
  - **Maintenance** shows the server's message, with retry and an automatic re-check every 30 s.
- **Live banner layer:** an overlay above every screen for time-critical events: match found, tournament check-in and "Round N: join", invites, and rematch requests. It also shows "Searching · 0:32" and "Tournament live" pills.
  - **The connection:** the app keeps one realtime connection whenever it's in the foreground and signed in, on every tab (30 s idle heartbeat), so invites, inbox updates and tournament calls always arrive. Without a connection it polls invites and the unread count on resume and every 20 s.
  - **App state:** the app reports foreground and background (`client.state`). A search stops after 10 s in the background with no penalty.
  - **Prompt priority:** live game > tournament round > match found > rematch > invite > check-in.
  - **Gates wait:** update and maintenance gates never interrupt a live match or round.
  - **Build header:** every request carries `X-App-Build`, and the server answers old builds with `426`.
- **Suspended screen:** a ban shows the reason, the end date, the appeal contact and Sign out (from `ACCOUNT_BANNED` details). A restricted account keeps playing, with inline notices.
- **Onboarding safety exits:** "Signed in as … · Switch account" on step 1, an under-age message with Sign out, and links to the Terms and Privacy policy.
- **Plumbing:**
  - Automatic token refresh.
  - A drift-backed sync queue, flushed on app start, when connectivity returns, and on a periodic timer while the app is in the foreground.
  - A debug settings screen for the base URL and dev login.

## Phase 3 — Learn, practice and test content
**Content model**
- **Hierarchy:** goals (exams) → subjects (many-to-many; Physics and Chemistry are shared) → chapters → **topics** → questions. Every question belongs to one topic, so it always knows its chapter and subject too. Topics are the "module" level that tips talk about.
- **Question fields:**
  - Type: `mcq_single` or `passage_mcq`.
  - `subject_id`, `chapter_id` and `topic_id` (passage questions may have no topic).
  - **Category:** concept, numerical, factual or application.
  - **Exams:** the exams it suits. Empty means every exam that includes the subject.
  - A rich stem (JSON AST) plus `stem_text` for search.
  - An explanation.
  - Difficulty 1–5, plus a `p_correct` calibrated nightly.
  - Tags.
  - `battle_pool`: none, shared or reserved.
  - `status`: draft, review, published or retired.
  - A dense per-subject `seq`, used for seen bitmaps.
- **Rules:**
  - Published questions are immutable. An edit creates a new row that points back through `supersedes_id`.
  - Options carry a partial unique index, so each question has **exactly one correct answer**.
  - Image questions are practice-only in v1.
- **Related tables:** `passages` holds Fun & Learn texts with 3–6 questions each. `word_puzzles` holds a 3–12-letter answer, a clue and a difficulty.

**Test content** (`content/*.yaml`, loaded by `scripts/seed.py`; format in `docs/content-format.md`)
- For now only a small test set, at the user's request:
  - 2 chapters per subject, each with 2 topics and 8 questions, 64 questions in all.
  - One passage (3 questions) and 5 words per subject.
- Every chapter has at least 7 battle questions, enough for one Quick Battle. So matchmaking, widening to the second chapter, practice and tips can all be tested. A chapter needs 7 battle questions to be offered for battles; the real bank should have 15+ so players rarely see repeats.
- Questions suitable for battles are short and conceptual. Long numericals are `battle_pool=none`.
- `content/tools/validate.py` runs in CI and checks:
  - 4 distinct options and exactly 1 answer;
  - a valid topic, category and exams list;
  - unique ids and stems, and an explanation on every question;
  - markup, and stem lengths (battle stems at most 180 characters);
  - enough battle questions per chapter;
  - at least 2 categories per chapter, and answer positions spread out.
- The importer adds near-duplicate detection (similarity above 0.9) for the real bank.

**Importer**
- `scripts/import_questions.py`, plus an admin upload, both taking CSV or JSON in a documented format.
- A dry run produces a report per row.
- Idempotent, keyed on a hash of the stem and options.
- Audited.

**Learn screen** (ref 2 style)
- Big headline, search pill and goal switcher.
- Pastel subject tiles showing question and chapter counts.
- A chapter list showing accuracy and progress.
- Practice Tools tiles.
- **Continue practice** in place of lessons: the latest in-progress session ("Physics · Kinematics · 12/20 · Resume"), or the coach's next suggestion if there isn't one.

**Practice sessions**
- The server returns the question set **with answer keys**, for shared and none-pool questions only (never reserved ones). This allows instant feedback and offline play.
- Sessions are cached in drift.
- Answers upload in batches through the sync queue, deduplicated on `(user_id, client_answer_id)`. Each answer carries the option picked, the outcome, the time taken and how often the pick changed.
- Fetching is rate-limited to 30 sessions an hour, to stop scraping.

**Answer records** (the data behind tips)

Every answer in every mode writes one `question_attempts` row:

| Field | Meaning |
|---|---|
| `user_id`, `question_id` | Who answered what |
| `subject_id`, `chapter_id`, `topic_id`, `category`, `difficulty` | Copied from the question when answered, so grouping needs no joins and history stays stable if content is reorganised |
| `mode` | practice, challenge, review, bookmarks, fun_learn, quick_battle, bot, friend, group or tournament |
| `session_id`, `position` | The practice session or match, and the question number in it |
| `selected_option` | The option picked, as its index in the authored question (not the shuffled screen order). Empty if none |
| `outcome` | correct, wrong, skipped or timeout |
| `time_ms` | Time from the question appearing to the answer. Live games use the server's latency-adjusted time. Practice uses the phone's measurement, capped at 10 minutes. A timeout records the full limit |
| `time_limit_ms` | The limit, or empty for untimed practice |
| `speed` | **fast, slow or even** compared with the other players (below). Empty when there's nothing fair to compare with |
| `speed_basis` | `opponents` (live game) or `typical` (practice, compared with the question's typical time) |
| `peer_time_ms` | The time it was compared with: the opponent's time, the group's median, or the question's typical time |
| `answer_changes` | How often the pick changed before submitting (Self Challenge) |
| `first_try` | Whether this was the user's first attempt at this question |
| `points` | Battle points, when there are any |
| `answered_at`, `ist_day` | When, and the IST day for streaks and missions |
| `client_answer_id` | Offline de-duplication, unique per user |

**Fast, slow or even in multiplayer games** (computed by the server when the match settles)
- **Who counts as an opponent:** other human players who were connected when the question opened. Bots, disconnected players and late joiners are left out.
- **What's compared:** the user's time against the opponent's time in a 1v1, or against the median time of those who answered in a group battle.
- **Rules:**
  - The user answered more than 250 ms sooner: **fast**.
  - More than 250 ms later: **slow**.
  - Within 250 ms: **even**. That's inside the network-latency allowance, so it doesn't count either way.
  - The user answered and no opponent did: **fast**. The user timed out while an opponent answered: **slow**. Nobody answered: empty.
- Correctness is stored separately, so tips can tell "slow but right" (knows it, needs speed) from "fast but wrong" (rushing).
- The reveal after each question shows it too ("You were 1.2 s faster").

**Typical-time comparison in solo practice**
- `question_stats` keeps each question's attempts, correct answers and **typical time**: the median time of correct answers across all users, updated nightly.
- Once a question has at least 20 timed correct answers, practice answers are compared with it: under 0.75× the typical time is fast, over 1.25× is slow, and anything between is even.

**Running totals** (updated in the same transaction as the answers, for newly inserted rows only)
- `user_topic_stats`, `user_chapter_stats` and `user_category_stats` (per subject and category) keep attempts, correct answers, total time, time on correct answers, fast/slow/even counts and the last attempt time.
- `user_daily_stats` (per IST day and subject) feeds streaks, missions and "this week" comparisons.
- 30-day figures for tips are read straight from `question_attempts`, indexed by user and time. That's only a few thousand rows per user.

**Practice modes**
- **Chapter practice:**
  - 10, 20 or 30 questions.
  - Difficulty mixed, easy, medium or hard.
  - Instant feedback with an explanation after each question. No timer.
- **Self Challenge:**
  - Subjects and chapters (multi-select).
  - 10, **20**, 30 or 50 questions.
  - A total time of 5, **10**, 15, 30 or 60 minutes.
  - Difficulty.
  - **+4/−1 marking**, on by default for NEET and JEE.
  - An "Unseen only" option.
  - Answers are shown at the end.
  - The server enforces the time limit. The result shows accuracy, time per question and a review, and wrong answers go to the review queue.
- **Bookmarks:**
  - Offline-first and optimistic, with the last write winning. Capped at 5,000.
  - Filterable by subject, and bookmarked questions can be practised as a set.
- **Review weak questions (Leitner):**
  - Any wrong answer, from practice or a battle, puts the question in box 1.
  - Boxes come due after 1, 3, 7, 14 and 30 days. A correct answer moves the question up a box and a wrong one sends it back to box 1. A correct answer from box 5 graduates it.
  - The screen shows the count due today.
- **Fun & Learn:** read a passage, answer its questions, then read the explanations.
- **Guess the Word:**
  - A clue, letter slots and shuffled tiles.
  - Hints cost 5 coins each: reveal a letter, or remove the decoy letters.
  - Skipping is allowed, and there's a streak score.
- **Search:**
  - pg_trgm with GIN, plus `simple` full-text search over stems and chapter names.
  - At least 2 characters, debounced and cancellable.
  - Reserved questions are excluded, with a limit of 30 searches a minute.

## Phase 4 — Realtime engine and battles
**Handshake** (`docs/protocol.md`)
1. **Get a ticket.** `POST /v1/rt/tickets` returns a ticket of 32 random bytes, stored in Redis for 30 s as `{uid,sid,roles}`.
2. **Say hello.** The client connects to `WSS /v1/ws` and must send `hello{ticket, proto, build, resume:[{ch,last_seq}]}` within 5 s. The ticket never goes in the URL.
3. **Welcome.** The server consumes the ticket with `GETDEL`, checks for revocation, bans and the protocol version, and replies `welcome{server_ms, hb_s, active:[{ch,kind,state}]}`.
4. **Forced disconnects.** Logout or a ban publishes to `ctl:u:{uid}`, which closes the socket with 4403.

**Envelope and limits**
- The envelope is `{v,t,id,ch,seq,ts,d}`. `seq` increments per channel, inside the same Lua script that emits the event.
- Additive changes keep v1, and unknown types are ignored. A breaking change gets `/v2/ws`, served in parallel for at least 60 days.
- Inbound messages are limited to 4 KiB and 10 per second (burst 30). Three violations close the socket with 4429.
- The outbound queue per socket holds 256 messages. Emotes and progress messages are dropped first; if it still overflows, the socket closes with 1013 and the client resyncs.
- **Close codes:**
  - 4400 bad message
  - 4401 bad ticket
  - 4403 revoked
  - 4408 hello timeout
  - 4409 superseded by another device
  - 4426 update required
  - 4429 rate-limited
  - 1012 server restart; the client reconnects after 0–2 s of jitter
- The heartbeat is every 10 s, or every 5 s in a match. A connection counts as stale after 12 s in a match, or 30 s otherwise.

**Messages**
- Client → server:
  - `clock.ping`
  - `mm.join{mode,subject,chapter|all,idem}`, `mm.cancel`, `mm.respond{keep|bot|invite|cancel}`
  - `match.ready`, `match.forfeit`
  - `ans.submit{match_id,q,opt,el_ms}`
  - `emote`
  - `sync{ch,last_seq}`
  - `room.{join,leave,ready,settings,start,kick,lock,transfer,end,rematch}`
  - `sub`/`unsub` for tournament standings
- Server → client:
  - `clock.pong`
  - `mm.status{waited_s,window,widened}`, `mm.timeout{options}`, `mm.found{match_id,opponent,source_chapters}`
  - `match.snapshot`, `match.phase{phase,ends_at}`
  - `q.show{q,total,stem,options[{id,text}],shown_at,deadline_at}`
  - `q.progress{answered:[uid]}`, which shows who has answered, never what
  - `ans.ack{status: accepted|late|invalid|too_early, dup}` (a repeat gets the first status back with `dup`)
  - `q.reveal{correct_opt, per-player {opt,correct,pts,el_ms}, totals, question_ref}`
  - `opp.conn{state,grace_until}`
  - `match.end{result,reason,scores}`, then `match.settled{rating Δ, coins, xp, missions}`
  - `room.state`, `t.round`, `t.standings`, `error{code,ref,retryable}`

**State machine**
Every transition is a Lua compare-and-set on `ver`.

| State | Exit | Timeout → effect |
|---|---|---|
| READY_WAIT | all players `match.ready` | Quick: 10 s → ABORTED. Tournament: 90 s → no-show rules |
| COUNTDOWN | timer | 3 s |
| Q_OPEN(i) | everyone answered (early advance) **or** deadline + 250 ms | D = 15 s (rooms: host-set) |
| Q_REVEAL(i) | timer → Q_OPEN(i+1) or FINISHED | 3 s (group: 4 s with a mini leaderboard) |
| FINISHED → SETTLED | the settlement commit | retried until it commits |
| ABORTED / VOIDED | terminal | holds released, ratings unchanged |

- A forfeit, or exceeding the grace period after Q1, moves the match straight to FINISHED with `reason=forfeit`.
- **Formats:** Quick Battle is 7 questions of 15 s each (about 2.5 minutes). A tournament game is 10 of 15 s.

**Question delivery without leaking answers**
- **When the match is created:**
  - The server picks N questions and shuffles each one's options.
  - It gives every option a fresh random 5-character id.
  - The map from those ids to which option is correct lives only in Redis and in `match_questions.option_map`.
  - Question ids and difficulty are hidden while a question is live.
- **Showing a question:** `q.show` goes out at T−400 ms with `shown_at=T`, and clients reveal it once the synced clock reaches T.
- **Answering:** `answer.lua` runs on whichever node received the answer. In one atomic step it checks the state and question index, deduplicates by uid, validates the timing, scores the answer, stores it, and publishes `q.progress`. If everyone has now answered, it also moves the match to Q_REVEAL.
- **Deadline:** the owner node's timer runs `advance.lua(expected_ver)`.
- **Event log:** all events are written to a Redis stream (`XADD m:{mid}:log`) and broadcast (`PUBLISH`) inside the scripts.

**Clock sync and latency-fair scoring**
- **Clock sync:**
  - The client sends 5 pings and keeps the one with the lowest round-trip time: `offset = s − (c0 + rtt/2)`, measured on a monotonic `Stopwatch`.
  - It re-syncs every 60 s and after each reconnect, and discards any sample with RTT above 1 s.
  - The client clock is only used for display.
- **Latency allowance:**
  - Each player gets `lat = min(250 ms, p50(server-measured heartbeat RTT)/2)`.
  - `raw = recv_time − shown_at`, and the effective time is `e = clamp(el_client, raw − lat, raw)`.
  - If `raw < 0`, the answer is `too_early` and gets flagged.
  - An answer is accepted if `e ≤ D` and `recv ≤ deadline + lat`.
- **Points:**
  - A correct answer scores `100 + round(50 × (1 − clamp((e − 1000)/(D − 1000), 0, 1)))`, so between 100 and 150. Correctness matters more than speed, which suits exam prep.
  - A wrong or blank answer scores 0.
  - Ties are broken by points, then the number of correct answers, then the total `e` across correct answers. If all three match, it's a draw.

**Disconnects, resume and duplicate devices**
- **The match clock never pauses.** The opponent sees "Reconnecting… 23 s".
- **Grace before a forfeit:**
  - 30 s in a quick battle.
  - 45 s in a tournament.
  - 60 s in a friend duel.
  - In a group battle, a missing player just scores 0 until they return.
- **Voids and restarts:**
  - If both players exceed their grace within 5 s of each other, the match is **VOIDED**.
  - A 1012 server drain adds 60 s of grace and never counts as a forfeit.
- **Resume:** the client reconnects with `hello.resume`. If the gap is still in the capped stream (about 300 entries), the server replays it with `XRANGE`. Otherwise it sends `match.snapshot`.
- **Duplicate devices:** the newest connection wins and the old one gets 4409 ("Playing on another device"). Answers are keyed by uid.

**Outcomes**
| Outcome | Rating | Casual entry (5 coins) | XP / missions |
|---|---|---|---|
| ABORTED before Q1 (not ready / no-show) | none | refunded to both | none. 3 aborts in an hour means a 5-minute queue cooldown |
| Forfeit after Q1 | full loss for the leaver, full win for the other | winner takes the 10-coin pot | winner gets win rewards |
| Normal win / draw / loss | Glicko-2 1 / 0.5 / 0 | winner +10; draw refunds 5 each | per the economy table |
| VOIDED (both dropped, infra failure, integrity) | none | refunded | none |

**Scaling and failover**
- **Shared hash tag:** every key for a match carries `{mid}`, so one Lua script can touch all of them, and they're ready for Redis Cluster.
- **Owner lease:** `SET NX PX 4000`, renewed every 1 s. The owner runs precise asyncio timers.
- **Failover:** every transition also does `ZADD rt:timers mid due`. Every node scans that set every 250 ms. If an entry is more than 1 s overdue and has no owner, the node takes the lease and rebuilds the match from its state. A stale owner's writes fail the `ver` check.
- **Subscriptions:** nodes subscribe to `ev:m:{mid}` only while they have a local member, plus a per-user `ev:u:{uid}`. If the client sees a `seq` gap, it syncs.
- **Graceful stop:** on SIGTERM, a node drains, releases its leases, closes sockets with 1012, and exits within 10 s.

**Exactly-once settlement**
- **Finishing:** at FINISHED, the script writes `m:{mid}:final` (immutable) and adds the match to `settle:q`. The owner settles right away, and the worker retries every 5 s.
- **The settlement is one transaction:**
  1. Take a `FOR UPDATE` lock on the match, and stop if it's already settled.
  2. Insert the answers and participants.
  3. Lock the rating rows in user order and apply Glicko-2 (`rating_history UQ(match,user,scope)`).
  4. Post the ledger entries, keyed `m:{mid}:{uid}:{kind}`.
  5. Update XP, missions, the tournament pairing and the rival record.
  6. Write the outbox rows and set `settled`.
- **After commit:** publish `match.settled`. Until then the client shows "Results syncing…".
- **Reconciler:** the worker VOIDS and refunds any Postgres match still live after `max_duration + 5 min` with no Redis state. An alert fires if settlement lags more than 60 s.

**Anti-cheat**
- **Screen protection:** Android `FLAG_SECURE` (through a small platform channel) and keep-screen-on (`wakelock_plus`) for **every live-game screen**. This blocks screenshots, screen share and Circle to Search.
- **Reserved pool:** a `reserved` battle pool is supported. Starter content is all `shared` because the bank is small, and admins can reserve questions later.
- **Signals:**
  - 3 or more correct answers with `e < 700 ms` in one match.
  - Accuracy more than 3σ above what question difficulty predicts, over the last 20 matches.
  - Response times with very low variance.
  - The app pausing while a question is open.
  - More than 3 accounts on one device hash.
  - Play Integrity, in Phase 8.
- **Collusion:** the same pair can play at most 3 rated games in 24 hours. A "dumping" pattern (losing with 0 answers) is flagged.
- **Actions:** flag, then moderator review, then shadow pool (flagged players only match each other), then ban.

**Quick Battle (the core flow)**
- **Where it starts:** the Battle tab card or the Home "Play 1v1" tile.
- **Flow:**
  - Subject chips (NEET: Physics, Chemistry, Biology; JEE: Physics, Chemistry, Maths).
  - **Chapter** in the ChapterPickerSheet (defaults to the last one used or All).
  - Rated (free, rating ±, "1523?" while provisional) or Casual (5 coins, no rating).
  - Then the **Find opponent** button (lime, size L). The last selection is remembered.
- **Queue:**
  - A ZSET `mm:q:{mode}:{subject}` scored by the subject rating, plus a ticket hash `{uid, rating, rd, chapter|ALL, joined_ms, hold_id, device_hash}`.
  - One leader per queue (under a lease) ticks every 500 ms, oldest ticket first.
- **Compatibility:**
  - **Same chapter, or either side picked All.** Questions come from the specific chapter if there is one, otherwise from the whole subject.
  - **From 15 s:** any chapter in the subject. The questions are then **4 from one chapter and 3 from the other**, with the extra one from the player who has waited longer. The status line says the search has widened.
- **Rating window:** `max(base(t), RD)` (a provisional player's rating uncertainty), so provisional players widen at once.

| Waited | Rated ± | Casual ± |
|---|---|---|
| 0–5 s | 75 | 150 |
| 5–10 s | 150 | 300 |
| 10–20 s | 250 | any |
| 20–30 s | 400 | any |
| 30–45 s | any | any |
| 45 s | `mm.timeout` | `mm.timeout` |

- **At 45 s, the player can choose:**
  - **Keep searching** for 60 s more, after which the search cancels itself and the hold is released.
  - **Invite a friend**, which opens a friend duel.
  - **Practice vs Bot:** offered to every searcher, and also startable straight from the Battle tab (`mm.join {mode: "bot"}`). It's always unrated and coin-free. It gives 50% XP, capped at 60 XP a day, which never counts toward weekly boards or rated missions. **Rated games and tournaments never use bots.**
- **Pairing guards:**
  - `pair.lua` atomically checks that both tickets exist and both players are busy with that ticket. It removes them from the queue and sets `busy→m:{mid}`.
  - Blocked pairs are never matched, nor two tickets from the same device hash. The same pair can play at most 3 rated games in 24 hours.
  - The match row is written first, then the Redis state. If that fails, `unpair.lua` puts both players back in the queue with their original wait times.
- **Queue hygiene:**
  - A ticket needs a live socket; after 10 s disconnected it's cancelled and the hold released.
  - One ticket per user, and at most 10 `mm.join` per minute.
  - If the partner doesn't ready up, the player who did goes back to the **head of the queue** with their original wait time.
  - Players checked in to a running tournament can't queue.
- **Casual escrow:** at `mm.join`, the player's wallet is locked, a −5 ledger entry is posted, and the hold is recorded as `coin_holds{held}`.
  - When the match settles, the hold is captured and the winner is credited +10.
  - A draw, abort, void or cancel releases the hold.
  - A reaper releases any hold still stuck after 30 minutes.
- **Question pick:**
  - The difficulty mix follows the pair's average rating: under 1300 it's 50/40/10 easy/medium/hard; 1300–1700 it's 25/50/25; over 1700 it's 10/40/50.
  - Questions either player has seen are excluded, using `user_seen` bitmaps. If the pool runs out, it falls back to the least recently seen. **Matchmaking never blocks.**
- **Practice Bot:**
  - It runs as a virtual participant in the engine, labelled "Practice Bot" with the Robot01 avatar.
  - Its accuracy is the user's expected score in that chapter, clamped between 0.45 and 0.75.
  - Its answer time is log-normal, with a median of 6 s and never under 1.5 s.
- **Rematch:** casual only (`match.rematch` / `rematch.status`). Both players must accept within 15 s, and at most 3 in a row. Rated players queue again.
- **If the partner never gets ready:** `mm.requeued` puts the ready player back at the front of the queue, with the message "Your opponent didn't join. Searching again…".
- **Screens:**
  1. **The search screen:** SearchingPulse, elapsed time, the widening status line, and Cancel. The user may leave it; a "Searching" pill stays on every screen, and a found match takes over the screen wherever they are.
  2. Match found, then the VS screen with shared avatars and the head-to-head record.
  3. A 3-2-1 countdown.
  4. The questions: after each reveal, "You were 1.2 s faster".
  5. **The result:**
     - Victory, Defeat or Draw, with the scores and a dot per question (right/wrong, fast/slow);
     - the rating change, **the new leaderboard rank** ("You're now #42 in Physics · ↑5");
     - coins, XP and level-up, mission progress, the streak, achievements, and one tip line;
     - buttons: Rematch (casual), Play again, Review answers, Done.
  6. **Afterwards,** every match is in Profile → History, with the same review.

**Play with Friend** (private 1v1; always unrated; no coins; half XP)
- **Code:** 6 characters in Crockford base32 (for example `K7M2QX`), valid for as long as the room exists. It's shared as `https://<domain>/j/<code>` or typed into CodeInput.
  - **The web page** for `/j/<code>` shows the code in big type, **Open app**, and a Play Store button that carries the code in the install referrer.
  - **A new install** reads the referrer once, so the invite survives install, sign-in and onboarding.
- **In-app invite:** friends only, delivered as a high-priority FCM push plus a banner, and it expires after 2 minutes. A busy friend shows a "Busy" chip.
- **Options:**
  - Subject, then chapter or All.
  - 5, **7** or 10 questions.
  - 10, **15**, 20 or 30 s per question.
- **Rules:**
  - **The lobby survives the host leaving the app to share the link.** It closes only on `room.end`, when everyone leaves, or after 15 minutes idle.
    - Members see "Waiting for Aarav to come back".
    - The host gets a notification when someone joins.
  - A rematch needs both players to accept within 30 s, up to 10 per session.
  - Blocked users can't join.
  - Code attempts are limited to 10 a minute.

**Group Battle** (2–8 players; unrated; no coins)
- **Host options:**
  - Subject, then chapters or All.
  - 5, **10**, 15 or 20 questions.
  - 10, **15**, 20 or 30 s per question.
  - Difficulty.
  - Late join: off, or **until halfway**.
  - Leaderboard between questions: **on** or off.
  - Who can join: friends only, or **anyone with the code**.
- **Host controls:**
  - Settings (lobby only).
  - Start (needs at least 2 players connected).
  - Kick (the player is banned from the room; at most 5 a minute).
  - Lock, transfer host, and end the game.
- **Host handover:** if the host leaves or is disconnected for more than 20 s, the earliest-joined connected player becomes host.
- **Mid-game rules:**
  - Late joiners score 0 for the questions they missed. After halfway they can only spectate.
  - Players who leave show as "left" and can rejoin.
  - If fewer than 2 players are connected for 30 s, the game ends.
  - Option order is shuffled per player.
- **Rewards:** XP only: 20 for a win and 10 for taking part, capped at 200 a day.
- **Room lifetime:**
  - An idle lobby closes after 15 minutes.
  - "Play again" stays open for 3 minutes.
  - Code guesses are limited to 5 a minute and 30 an hour.

## Phase 5 — Arena: scheduled Swiss tournaments
**Lifecycle**
A worker ticks every second, picking up due tournaments with `SELECT … WHERE next_action_at <= now() … FOR UPDATE SKIP LOCKED`. Each step is one transaction, and its side effects go through the outbox. Match IDs are generated in advance, so every step is idempotent.

| From | At | Action | To |
|---|---|---|---|
| SCHEDULED | `reg_opens_at` | open registration | REG_OPEN |
| REG_OPEN | T−15 min | open check-in: push and inbox "Check in now", and `t.check_in` on `u` | CHECK_IN |
| CHECK_IN | T−5 min | close registration (badge shows LOCKED); check-in stays open until T−2 min; registered players can't start quick battles or join rooms | LOCKED |
| LOCKED | T | if fewer than `min_players` checked in (default 8, never below 4): cancel and refund everyone (`t.cancelled`). Otherwise refund anyone not checked in, capture holds, seed by rating, pair round 1 | RUNNING(1) / CANCELLED |
| RUNNING(r) | last result of round r + 90 s | pair round r+1, or finalize | RUNNING(r+1) / FINALIZING |
| RUNNING(r) | round deadline (start + 10 min) | force-finish on current score; unstarted pairings count as double no-shows | same |
| FINALIZING | immediately | tie-breaks, ranks, prizes, notifications | FINISHED |

- **Arena filters:** Open = REG_OPEN or CHECK_IN. Upcoming = SCHEDULED or LOCKED. Live = RUNNING. Finished = FINISHED or CANCELLED.

**Admin settings**
- Title, description, subject or All, and 3–6 rounds.
  - The number of rounds played is min(configured, players − 1, ⌈log₂ players⌉ + 2), so small fields don't force rematches.
- **Exam:** `neet`, `jee` or `any`. `any` is only allowed for the shared subjects (Physics, Chemistry), so NEET and JEE players never get questions outside their syllabus.
- Entry fee (Free / 10 / 15 / 25 / 50) and a prize pool.
- Capacity (up to 256) and minimum players.
- Registration open time and start time.
- **Recurring templates:** an RRULE in IST. The worker creates instances 7 days ahead, and `UQ(template_id, starts_at)` keeps that idempotent.

**Player rules**
- **Joining:** the entry fee is held at registration (atomic, under a row lock), and a full tournament shows "Full".
- **Withdrawing:** before T, it's a full refund. After the start there's no refund; the player stays in the standings so tie-breaks don't break, but can't win a prize.
- **Checking in:** always a deliberate tap between T−15 and T−2 min (from the banner, the card, the detail screen or the notification). **Can't make it** next to it withdraws with a full refund.
- **Reminders without push:** at registration the app schedules local notifications for T−1 h, T−15 min and T, and offers "Add to calendar".
- **Clashes:**
  - Registering for overlapping tournaments returns `SCHEDULE_CONFLICT`.
  - A quick battle or room whose longest possible length would reach T−2 min returns `BUSY`.
- **Small fields:**
  - The card shows "5 of 8 needed" and "Prize now 625 of 2,500 · grows with players".
  - At T−30 min, registrants of an at-risk tournament are told "3 more players needed".
- **Not checking in:** refunded, with an inbox note. Three no-shows in 30 days block paid registration for 7 days.
- **Rounds:**
  - Players must be ready within 90 s of a round starting.
  - If only one player shows, that player gets a forfeit win: 1 point, no rating change.
  - If neither shows, both get 0.
  - Missing two rounds in a row withdraws the player automatically.
  - Games are **10 questions × 15 s, rated** (overall and subject).
  - A draw is worth 0.5 points.

**Pairing** (`swiss_pairing.py`, a pure function)
- Round 1 pairs the top half against the bottom half by seed (1 v n/2+1, 2 v n/2+2, …), the same shape later rounds aim for inside each score group.
- **Later rounds:**
  - Use networkx `max_weight_matching(maxcardinality=True)` on a sparse graph where edges connect players whose points differ by at most 1.5, widening if needed.
  - It runs in a thread with a 20 s budget and falls back to a greedy pairing.
  - The weight is `10^7 − 10^4·(2Δpts)² − (|seed_i − seed_j| − g/2)²`, which keeps score groups together and pairs the top half against the bottom half.
- **Hard rules:** no rematches, at most one bye per player, and withdrawn players are skipped.
- **Byes:** an odd player count adds a BYE vertex, and the lowest scorer without a bye is preferred for it. A bye is worth 1 point.
- **Relaxation, in this order:**
  1. Allow a rematch with a −10^6 penalty, but never against the previous round's opponent.
  2. Give an extra bye to the lowest player with the fewest byes.

**Standings**
- Ordered by points, then **Buchholz Cut-1**, Buchholz, Sonneborn-Berger, total quiz points, average time on correct answers, and finally earlier registration.
- For Buchholz, a round that wasn't played counts as the player's own final score, so a no-show opponent doesn't distort it.
- They're recomputed inside each settlement (at most 256 rows), and `t.standings` is published at most every 2 s.

**Prizes**
- `effective_pool = pool × min(1, players/32)` stops alt-account farming of big pools. Amounts are floored and the remainder goes to 1st place.
- Distribution by player count:
  - 4–7: 70/30
  - 8–15: 50/30/20
  - 16–31: 40/25/15/10/10
  - 32–127: 30/20/12/8/6, then 4.8% each for 6th–10th
  - 128–256: 25/15/10/7/5, 3% each for 6th–10th, 1.15% each for 11th–30th
- Banned, withdrawn or deleted players are skipped and the places shift up. Everyone earns 10 XP for each round played.

**Cancellation**
- Before the start: every hold is released.
- While running: entry fees are refunded through the ledger, no prizes are paid, and ratings from games already played stand.

**UI**
- Pastel subject-colored TournamentCards with LIVE and REGISTRATION badges, with **My tournaments** pinned at the top of the Arena tab.
- A detail screen (shared element) with Overview (rules, schedule, prize table for the current player count), Standings and My games tabs.
- **The live lobby between rounds:** "Round 2 of 5", your record, points and current rank, a pairing countdown, and the top standings. A bye shows "You have a bye this round (+1 point)".
- **Round start:** a full-screen "Round N: you vs Aman · Join (90 s)" on any screen (`t.pairing`).
- **Final results:** your final rank ("#3 of 64"), the prize credited automatically, and XP. `t.finished` sends them, and they're kept in the Inbox and Profile → Tournaments.
- Reminders at 1 h and 15 min before the start.

## Phase 6 — Ratings, economy, progression, coach, leaderboards, Home
**Glicko-2**
- Starting values r = 1500, RD = 350, σ = 0.06, and τ = 0.5. RD stays within [45, 350].
- Updated after every game, with fractional 5-day periods for RD growth. Both players' updates use pre-game values.
- The volatility step uses the Illinois method (at most 100 iterations; if it fails, the old σ is kept).
- **Scopes:**
  - Every rated game updates `overall`.
  - Subject games and tournament games also update that subject's rating.
- **Display:** "—" before any games, then "1523?" while RD is over 110. A player appears on leaderboards once RD ≤ 110 and they've played at least 10 games.

**Leaderboards**
- **Global and subject:** Redis ZSETs `lb:r:{scope}`, updated through the outbox with an idempotent `ZADD`, or `ZREM` when a player is provisional or banned.
- **Weekly XP:** a ZSET per ISO week, with a dedupe key per event.
- **Friends:** built with `ZMSCORE`.
- **Rebuild:** nightly from Postgres, then an atomic `RENAME` into place.
- **API:** the top 100 plus the ±10 around you (`docs/api-play.md`).
- **"Who is leading where":**
  - **The hub:** a Leaderboards hub (from the Home trophy, "Leaders this week" and Profile) shows every board with its #1 player, your position and your change since yesterday.
  - **The boards:**
    - This week (XP, no bot XP, resets Monday 00:00 IST).
    - **This week per subject** (battle points from games against people), which answers "who is leading Physics this week?".
    - Overall rating, and a rating per subject.
    - Friends.
    - A tournament Hall of Fame.
  - **Exam filter:** boards default to the viewer's exam (NEET or JEE), with an All India toggle.
  - **Fairness:**
    - Bot XP never counts, and casual XP counts from at most 3 games per pair a day.
    - Flagged or suspended players are hidden.
    - Ties go to whoever got there first.
    - Idle players' rating uncertainty grows nightly, so stale ratings drop off the rating boards.
  - **Last week's champions:** the top 3 stay visible for the week.
  - **Not ranked yet:** "Play 7 more rated battles to appear". The weekly board includes anyone with XP this week, so new players show up immediately.
  - **Big moves:** entering the top 100, 10 or 3 of a board creates an inbox item. The match result screen always shows the rank change.

**Coin ledger**
- `wallets.balance` has `CHECK >= 0`.
- `coin_ledger` rows carry delta, balance_after, reason, ref, a **UNIQUE** `idempotency_key` and a bucket.
- Writing a posting:
  - Lock the wallet `FOR UPDATE`, then `INSERT … ON CONFLICT DO NOTHING RETURNING`.
  - When several wallets are involved, they're locked in user_id order.
- The ledger is append-only. The app's DB role can only INSERT and SELECT on it, and a trigger blocks UPDATE and DELETE.

| Coin sources | Amount | Coin sinks | Amount |
|---|---|---|---|
| Welcome bonus | 100 | Casual battle entry | 5 |
| All 3 daily missions | 25 | Tournament entry | Free/10/15/25/50 |
| Rated win / draw / loss | 10 / 4 / 1 (cap 150 a day) | Streak freeze (hold at most 2) | 50 |
| Casual win | 10 (the pot) | Guess the Word hint | 5 |
| Level-up | 20 | Cosmetics (v1.1) | 100–1000 |
| Streak day 7 / 30 | 30 / 100 | | |
| Achievements, tournament prizes | 10–200; set pool | | |

**XP and levels**
- **Practice:** +1 per answer, +1 more if correct, capped at 300 a day.
- **Rated games:** 30 / 20 / 10 for a win, draw or loss.
- **Casual games:** 20 / 15 / 8.
- **Friend, group and bot games** earn half.
- **Level curve:** cumulative XP `25·(L−1)·(L+2)`, so level 2 needs 100, level 10 needs 2,700, and the cap is level 100.

**Daily missions** (matching the screenshots)
- **Generation:** created on the first request of the IST day with `ON CONFLICT DO NOTHING`, chosen deterministically from `hash(uid, day)`.
- **The day's three:**
  - Practice 10, 20 or 30 questions (+20 XP).
  - Play 1 rated battle or tournament game (+25 XP). It's never "win", because few players may be online.
  - Review 5 weak questions (+30 XP). If fewer than 5 review items exist, this becomes "10 questions in the weakest chapter", or "10 questions in any chapter" for a new player with no data.
  - One free mission swap a day.
- **Progress:** driven by events and deduplicated by event_id.
- **Rewards:** **credited automatically** (there's no claim button to fail). Completing all 3 gives **+100 XP and 25 coins**.
- **"Start recommended mission"** deep-links to the first one not yet done.

**Streaks and achievements**
- A streak day needs at least 10 answers or 1 finished battle in the IST day. The streak is evaluated lazily, and a freeze is used automatically.
- About 15 achievements, stored in a table and checked by the outbox consumer.

**Coach tips** (plain language, no charts)

Students aren't analytics-focused, so instead of graphs the app gives **short instructions, each with one button**. A rule-based engine reads the answer records from the last 30 days (all time for topics with little recent data). Accuracy is smoothed as `(c+2)/(n+4)` so a couple of answers can't swing it.

| Signal (minimum data) | Tip | Button |
|---|---|---|
| Topic accuracy ≤ 50%, or 15+ points below the user's average (≥ 5 answers) | "Focus on **Projectile motion**. You got 4 of 11 right." | Practise 10 |
| Slow in ≥ 60% of compared answers in a topic or chapter (≥ 5 compared, ≥ 3 slow) | "You're often slower than your opponents in **Kinematics**. Try a timed set." | Timed practice |
| Slower than typical on a category in a subject (≥ 8 compared) | "Practise more **Physics numericals**. You take about 40% longer than other students." | 10 numericals |
| Fast but wrong on ≥ 40% of a topic's answers (≥ 6 answers) | "You answer **Chemical bonding** quickly but often miss. Read all four options first." | Practise 10 |
| Review items due | "5 questions are waiting for review." | Review |
| A chapter in the user's exam never tried | "You haven't tried **Gravitation** yet. Start with 10 easy questions." | Start |
| Easy questions ≥ 85% right in a chapter (≥ 10) | "You've got the basics of **Genetics**. Try medium questions." | Practise medium |
| Topic accuracy ≥ 80% (≥ 10 answers) | "You're strong in **Laws of Motion**. Test it in a rated battle." | Battle |

- **Order:** accuracy problems first, then speed, then reviews, then new chapters, then level-ups and strengths. At most one tip per topic, and never more than 5.
- **Where tips appear:**
  - The Home Coach card shows the top tip.
  - "Your tips", opened from the card, lists up to 5.
  - Each practice and battle result screen shows one relevant line.
  - The Learn chapter list shows a small **Strong** or **Needs work** word per chapter. That's the only "analytics" on screen, and it's a word, not a chart.
- **Unlock:** after 20 answers. Before that the card says "Answer N more questions to get tips".
- **Stability:** tips are cached for 10 minutes and keyed by rule and target, so the list doesn't jump around. This also fixes the duplicated Coach card from the old app. A tip the user acts on is hidden for 24 h, and a dismissed tip for 7 days (`user_tips`).
- **Wording:** each tip is a template with the numbers filled in: one short sentence saying what to do and why.

**Home** (ref 1 style)
- **Data:** one `GET /v1/home` call returns each section with its own status, cached in drift.
- **Header:** avatar (opens Profile), "Hi, name", an animated bell with the unread count, and a trophy (leaderboards).
- **HeroStatCard** (lemon): rating as the big number, rank and coins, with Play, Practice and Arena actions.
- **Tournaments:** the next or live tournament, meaning the soonest open one with the biggest pool.
- **Battle tiles:** Play 1v1, Play with Friend and Group Battle.
- **Continue practice.**
- **Today's Missions.**
- **Coach tip** (the top tip).
- **Leaderboard preview,** with a DotMatrixChart of weekly activity.

## Phase 7 — Social, notifications, profile and settings
**Social**
- **Friends:**
  - Presence: online, in battle, in tournament or offline. Friends only, polled every 30 s while the tab is visible.
  - A Challenge button that creates a friend-duel invite.
  - Remove and block.
  - Up to 500 friends.
- **Requests:** at most 20 sent a day and 100 pending. Minors only receive requests from people they've played.
- **Rivals:** opponents you've played at least 3 times in 60 days, with the head-to-head record.
- **Activity:** friends' achievements, podium finishes, level-ups and streaks from the last 7 days.
- **Search:** by handle, at least 3 characters, prefix match.
- **Block and report,** everywhere:
  - Blocking hides both users from each other, cancels pending invites, and prevents pairing.
  - Reports cover cheating, an offensive name, harassing invites, or something else.
- **Emotes only in battle** (GG, Nice!, Wow, Oops): at most 1 every 3 s and 10 per match, with a per-player mute.

**Notifications**
- An **inbox** behind the bell.
- **FCM pushes:**
  - friend requests
  - duel invites
  - tournament check-in and round start
  - mission reminders
  - streak reminders
- Android channels per category, with preferences stored on the server.
- Push stays off without Firebase.

**Profile**
- **Header:** avatar, name, handle, level with XP bar, and goal.
- **Stats:** ratings per scope, W/D/L, accuracy, questions answered and best streak.
- **Rating chart:** a DotMatrixChart over 30 days, 90 days or all time.
- **Match history** (paged), with a review screen and bookmarking.
- **Tournament history and achievements.**

**Settings**
- **Profile:** name and avatar. The handle can change once every 30 days. Goal.
- **Privacy:** who can send friend requests, who can challenge me, and online status.
- **Notifications** by channel.
- **Sound and haptics, and theme:** system, light or dark.
- **Devices** (sessions), licenses and about.
- **Delete account:**
  - Available in the app after re-authenticating, and on a web page.
  - Immediately: sessions are revoked, the profile is anonymised, the player is removed from boards and friends lists, live matches are forfeited, and tournament entries are withdrawn.
  - The account can be restored within 7 days.
  - It's hard-deleted after 30 days. Game and ledger rows are kept under a tombstone ID.

## Tracking (cross-cutting)
- **For students:** History (battles with reviews, tournaments, practice sessions), Wallet (a coins history with a reason and link for every entry), Leaderboards (with daily change), the rating chart, and the Inbox (every automatic outcome). See `docs/user-flows.md` §15.
- **For the team:** server-side funnel events (activation, battle, friend/group, tournament, practice/tips, economy, retention and health) in an `analytics_events` table written through the outbox. They carry no personal details and are kept for 180 days. The app adds only a few allowlisted screen events through `POST /v1/events`.
- **Minors:** India's DPDP Act §9(3) bars behavioural tracking of children. For users under 18, events are stored without a stable user id (a per-session id and aggregates only). Everyone gets an analytics toggle.
  - **Coach tips for minors** rely on their own learning data for an educational purpose. This needs a legal review before launch.

## Privacy for minors (cross-cutting)
Most NEET and JEE aspirants are 16 or 17.
- **Names:** minors get only their first name pre-filled at onboarding, with the note "Shown to other players".
- **What non-friends see:** only the name, avatar and level. No form, ratings or head-to-head.
- **Public boards:** minors can opt out (`public_boards`).
- **Privacy defaults:** requests only from people they've played, challenges and presence friends-only. All of these are in Privacy settings.
- **The minor flag** comes from the birth year and the current IST year every time it's read, so restrictions lift automatically at 18.

## Phase 8 — Hardening and release readiness
- **Security review:**
  - Run the `/security-review` skill.
  - Run `pip-audit` and turn on Dependabot.
  - An OWASP API top-10 pass.
  - An **IDOR test suite** covering every endpoint.
  - A ZAP baseline scan.
- **Load and chaos testing:**
  - 10k sockets.
  - 2,000 matches at once.
  - A 256-player tournament.
  - Kill an rt node mid-question: failover should finish in under 5 s.
  - Targets: answer ack p99 under 150 ms, and REST p95 under 150 ms.
  - Host in Mumbai (ap-south-1).
- **Android release:**
  - Obfuscation with `--split-debug-info`, and R8 on the Android shell.
  - `integration_test` performance runs (`traceAction`) on a CI emulator.
  - Targets: cold start under 1.5 s on a mid-range phone, no frames over 16 ms on Home, Learn and battle screens, and app size under 25 MB.
  - DevTools memory checks for leaked controllers and streams.
  - Play Integrity signals for rated games and tournaments, once a Play Console app exists.
- **Compliance:**
  - Under India's DPDP Act and Rules 2025, obligations for minors apply from about May 2027. Build the verifiable parental-consent flow before public launch; it needs an email or SMS provider.
  - A privacy notice and a grievance contact.
  - The Play Data safety form.
  - The user should get a legal review.

---

## Security model (summary; full detail in `docs/security.md`)
- **Authentication:**
  - A Google ID token with a nonce.
  - A short-lived EdDSA access token, with an instant revocation check.
  - Rotating refresh tokens, with reuse detection and 60 s crash grace.
  - At most 5 device sessions.
  - On the device, the refresh token is held in `flutter_secure_storage` (Keystore/Keychain) and excluded from backups. The access token lives only in memory.
- **Authorization:**
  - Roles: user, moderator and admin.
  - **Every query is scoped to what the caller owns or belongs to**, and an IDOR test suite checks this.
  - The admin panel uses Google OAuth with the admin role and an optional IP allowlist.
  - Admin writes are audit-logged.
- **Input and abuse:**
  - Strict Pydantic validation (`extra="forbid"`, length limits, 4 KiB frames).
  - An Idempotency-Key on every coin-moving or entity-creating POST.
  - Redis token-bucket limits per user and per IP, on REST, WebSocket, matchmaking, invites, requests and code guesses.
  - A profanity filter that normalizes text first (NFKC, leetspeak, zero-width characters, repeated letters), with English, Devanagari and Hinglish word lists. It also blocks phone numbers, URLs and @handles in names, and names like "admin" or "official".
  - Moderation ladder: warn, reset name, restrict social, shadow pool, temporary ban, permanent ban. A ban bumps `token_version`, kicks the player's sockets, removes them from boards and forfeits their live games.
- **Fairness:**
  - The server is authoritative, and answers are never sent early.
  - Option IDs are random per match, and all times come from Redis.
  - Latency compensation is clamped.
  - Anti-cheat signals feed into the shadow pool.
  - Bots never play rated games or tournaments.
- **Money-like integrity:**
  - An append-only ledger with DB-level protections.
  - Idempotency keys and holds.
  - Balances can never go negative.
  - Settlement is exactly-once, and a reaper and reconciler clean up anything stuck.
- **Infrastructure:**
  - HTTPS/WSS only, with TLS terminating at Caddy.
  - Postgres and Redis are never public, and Redis requires a password.
  - Secrets live only in env files or Docker secrets.
  - Logs are JSON with PII redacted, and auth bodies are never logged.
  - Full IPs are kept only in security events, for 90 days.

## Data model outline (Alembic; full DDL during implementation)
- **Identity:**
  - `users` (handle citext UQ, display_name, avatar_id, email, birth_year, is_minor, status, roles, goal, token_version).
  - `auth_identities` (UQ provider+subject).
  - `device_sessions`.
  - `refresh_tokens` (family_id, token_hash UQ, used_at, successor_id).
  - `push_tokens`.
  - `user_settings`.
- **Content:**
  - `exam_tracks`, `subjects`, `track_subjects`, `chapters`, `topics`.
  - `questions` (subject, chapter, topic, category, exams, difficulty; UQ subject+seq; partial indexes on published battle pools; GIN trigram and full-text indexes).
  - `question_stats` (attempts, correct, typical time; nightly).
  - `question_options` (partial UQ on is_correct).
  - `passages`, `word_puzzles`, `question_reports`.
- **Practice:**
  - `practice_sessions`.
  - `question_attempts` (**partitioned monthly**; option, outcome, time, limit, speed, peer time, mode, position, first try; de-duplicated on user+client_answer_id).
  - `user_topic_stats`, `user_chapter_stats`, `user_category_stats`, `user_daily_stats`, `user_tips`.
  - `bookmarks`, `review_items`, `user_seen` (bitmaps).
- **Realtime:**
  - `matches` (kind: quick_rated, quick_casual, bot, friend, group, tournament; source chapters; status; end_reason; settled_at).
  - `match_participants` (is_bot).
  - `match_questions` (option_map), `match_answers`.
  - `rooms` (code UQ while active).
- **Ratings and economy:**
  - `ratings` (PK user+scope), `rating_history` (UQ match+user+scope).
  - `wallets`, `coin_ledger`, `coin_holds`.
  - `xp_events`, `user_progress`.
  - `mission_defs`, `daily_missions`, `mission_event_dedupe`.
  - `achievements`, `user_achievements`.
- **Tournaments:**
  - `tournament_templates`.
  - `tournaments` (next_action_at, UQ template+starts_at).
  - `tournament_entries` (points, bh, bh_c1, sb, quiz_points, correct_time_ms, byes, absences, final_rank).
  - `tournament_rounds`.
  - `tournament_pairings` (UQ per round per player, match_id UQ).
  - `tournament_prizes`.
- **Social and ops:**
  - `friendships` (PK lo+hi with CHECK lo<hi), `friend_requests`, `blocks`, `h2h`.
  - `activity_events`, `reports`, `moderation_actions`, `notifications`.
  - `outbox`, `audit_log`, `app_config`.
- **Redis only:** queues, live match state, presence, leaderboards (rebuilt from Postgres).

## Android realtime client (`core:realtime`)
- **Connection:** a `RealtimeClient` (a Riverpod provider that stays alive for the whole session) exposing a `Stream`/`Notifier` of `ConnState`: Idle, Ticketing, Connecting, Open, Backoff or Terminal.
- **Leases:** the socket opens only while a screen holds a lease (battle, room or live arena). It stays open for 30 s after the last lease is released. Opening the Battle tab takes a lease, so Find opponent is instant.
- **Backoff and lifecycle:**
  - Full-jitter backoff starting at 500 ms and doubling, capped at 10 s (2 s during a match). It pauses while there's no network.
  - Going to the background drops presence but keeps the match lease, so the server's grace rules apply.
- **Answers and events:**
  - Unacknowledged answers are re-sent with the same `id`.
  - Pure reducer functions build an immutable `MatchUiState` (a `Notifier`), and a `seq` gap triggers a `sync`.
  - The selected answer shows optimistically. If the server says it was late, the app shows "Time's up".
  - `ServerClock` drives the countdown from a `Ticker`, painted by `CountdownRing` inside a `RepaintBoundary`.
- **Process death:** secure prefs keep `activeGame{kind,id}`. On a cold start, `welcome.active` deep-links back into the game, which rebuilds from `match.snapshot`. Question content is never saved to disk.

## Top edge cases and their handling rules
| # | Edge case | Rule |
|---|---|---|
| 1 | An answer lands at the same moment as the deadline or early advance | Both are the same Lua step with a `ver` CAS. An answer only counts in Q_OPEN(i) |
| 2 | Two nodes both think they own the timers | `ver` CAS makes the stale owner's writes do nothing. The lease expires after 4 s and `rt:timers` failover takes over |
| 3 | Settlement runs twice | `FOR UPDATE` plus a status check, unique keys on the ledger, rating history and prizes, and an immutable `final` |
| 4 | Redis loses live matches, or Postgres is down at the finish | The reconciler voids and refunds. Otherwise settlement stays queued and retries while the client shows "Results syncing". Matchmaking pauses |
| 5 | Both players drop, or a deploy disconnects everyone | Both over grace within 5 s → VOIDED. A 1012 drain gives +60 s and never forfeits anyone |
| 6 | The same account on two devices | The newest connection wins (4409). Answers are keyed by uid |
| 7 | A cancel races the match being found | `pair.lua` is atomic. A late cancel gets `ALREADY_MATCHED` with the match id. The hold reaper cleans up |
| 8 | Two spends at once overdraw a wallet | Row lock, `CHECK >= 0` and a unique idempotency key |
| 9 | A tournament round starts while the player is in another mode | Checked-in players can't queue or join rooms. The busy slot gives the tournament priority |
| 10 | The worker crashes mid-transition | One transaction per step, `SKIP LOCKED`, unique keys, pre-generated match IDs and the outbox, so re-running is safe |
| 11 | Swiss pairing is impossible without a rematch | Relax step by step: a penalized rematch (never against the last opponent), then an extra bye |
| 12 | The app crashes right after the refresh token rotates | The same successor is returned within 60 s, so the user isn't falsely logged out |
| 13 | A chapter runs out of unseen questions, or is too thin | Fall back to the least recently seen questions, then widen to the subject. Chapters with fewer than 7 battle questions (one Quick Battle) aren't offered for battles; 15+ is the target for the real bank. Matchmaking never blocks |
| 14 | The app is killed or backgrounded mid-match | `welcome.active` resumes it from the snapshot. The clock keeps running, and a forfeit only happens after the grace period |
| 15 | Prize payout hits a banned, withdrawn or deleted player, or IST midnight falls mid-match | Skip ineligible players and shift places. Missions and streaks use the IST day of the server's settlement time |

## Verification
- **Backend** (this container runs Postgres through `pg_ctl` plus redis-server; CI uses service containers):
  - **Checks:** `uv run ruff check`, `uv run mypy app` and `uv run pytest`, with a transaction rollback per test.
  - **Protocol bots** (asyncio `websockets`) play full games over real sockets, covering:
    - Matchmaking: same chapter, All as a wildcard, **widening at 15 s with a 4+3 split**, **bot offer at 45 s** and auto-cancel after 60 s more, a partner who never readies (the other goes back to the queue head), rated never getting a bot, and a cancel racing a found match.
    - A rated game, checking Glicko-2, the ledger, XP and missions.
    - Abort before Q1 and the refund.
    - Resume after a mid-game drop.
    - A forfeit.
    - A duplicate device.
    - An answer arriving exactly at the deadline.
    - Killing an rt node mid-question: failover in under 5 s.
    - A bot game: no coins and no rating change.
    - Friend invite expiry and blocking.
    - An 8-bot group game: host migration, late join, a kick, and the code-guess limit.
    - A **64-bot Swiss tournament** with byes, no-shows, a withdrawal and refund, prize payout, and killing the worker between steps.
  - **Property tests** (hypothesis) on pairing, and golden files for tie-breaks.
  - **Answer records and tips:** fast/slow/even labels (1v1, group median, the 250 ms tie band, timeouts, disconnected and bot opponents), typical-time comparison, running totals that ignore duplicate uploads, and each tip rule at and just below its thresholds.
  - **Glickman reference:** 1500/200/0.06 vs 1400/30 (win), 1550/100 (loss) and 1700/300 (loss) must give 1464.06 / 151.52 / 0.05999.
  - **Concurrency:** 200 debits at once never go negative, and idempotent replays have no effect.
  - **Time:** frozen-clock tests across IST midnight.
- **Android:**
  - Run `flutter analyze` and `flutter test` here, including the golden tests in the app and the design system. I look at the PNGs and share them. The web catalog gets screenshots and click-throughs with Playwright/Chromium.
  - GitHub Actions runs the same steps plus `flutter build apk`, and uploads the APK. Once `dl.google.com` is allowed, APKs can also be built here.
  - Widget tests for:
    - AnswerOption states
    - CountdownRing
    - ChapterPickerSheet
    - the matchmaking states (searching, widened, bot offer)
    - error and retry
    - CodeInput
  - drift migration tests, and connection-manager tests against an in-process fake WebSocket server.
  - A **Dart integration test** where the real `RealtimeClient` plays a full match against a Python bot on the local backend. It runs with `dart test`, no device needed.
- **Device testing (user):**
  - Install the debug APK, from a CI artifact or a file I send.
  - Point it at the backend (LAN or host) through the debug settings screen.
- **Every phase ends with** a commit and push to `claude/determined-franklin-p6nr0f`, green CI, and a short summary with screenshots.

## Build order and checkpoints
0. Repo and CI scaffolding.
1. **Design system, then the screenshot review with the user.**
2. Backend core, auth and app shell.
3. Learn, practice and content.
4. Realtime engine and battles.
5. Tournaments.
6. Economy, missions, coach and Home.
7. Social, notifications and profile.
8. Hardening.

Flutter tests, goldens and web builds run here. Only APK builds need CI until `dl.google.com` is allowed. The first files that need the most care are `realtime/engine/lua/answer.lua`, `matches/settlement.py`, `economy/ledger.py`, `tournaments/swiss_pairing.py` and the Flutter `realtime_client.dart`.
