# Completion plan: closing every gap against `docs/plan.md`

Audit date: 2026-09-28. Phases 0–3 (design system, auth, onboarding, learn, practice, coach) were
built. Phases 4–7 existed only as pure algorithms (Glicko-2, Swiss pairing, standings, prizes,
scoring, matchmaking rules, bot model) with no tables, endpoints or live engine. On mobile the
battle flow ran only against the debug demo server, and Arena, Social, the Inbox, missions,
coins, rating and several Learn tools were "Coming soon".

This file lists every gap and the order it is closed in. Specs stay where they are
(`plan.md`, `api-play.md`, `api-learn.md`, `protocol.md`, `realtime-engine.md`, `user-flows.md`).

## Gaps

| Area | Backend gap | Mobile gap |
|---|---|---|
| Outbox, economy | `outbox`, `wallets`, `coin_ledger`, `coin_holds`, welcome bonus, hold reaper; `/me/wallet*` | Coins on Home, Wallet screen |
| Inbox, push, settings | `notifications`, `push_tokens`, notification prefs, quiet hours, FCM sender; `/me/notifications*`, `/me/push-token`, `/me/settings/notifications` | Inbox behind the bell, notification settings |
| Analytics, feedback | `analytics_events`, `POST /v1/events`, `POST /v1/feedback` | Feedback form, analytics toggle |
| Ratings, progression | `ratings`, `rating_history`, missions, streaks and freezes, achievements, XP per mode with caps; `/me/missions*`, `/me/streak*`, `/me/achievements`, `/me/stats` | Missions, streak and achievements screens |
| Leaderboards | Redis boards, nightly rebuild and snapshots, `/leaderboards*` | Leaderboards hub and board screens |
| Social, account | friends, requests, blocks, user reports, h2h, activity, presence, privacy settings, user search, public profiles, handle change, delete/restore | Social tab, public profile, privacy settings, delete account |
| Realtime engine | tickets, gateway, Lua state machine, matchmaking, Practice Bot, settlement, reconciler; `/battle/setup`, `/matches*`, `/me/matches`, `/me/opponents`, `/me/rivals` | Battle already speaks the protocol; history and review in Profile |
| Rooms | friend duels and group battles, codes, invites; `/rooms*`, `/invites*`, `/me/invites` | Friend and group lobbies, invite banners, code entry |
| Tournaments | tables, worker lifecycle, pairing and settlement, prizes, templates; `/tournaments*`, `/me/tournaments` | Arena tab, tournament detail, check-in and round prompts |
| Home | `GET /v1/home` with per-section status | Real Home sections |
| Learn tools | — | Self Challenge, Fun & Learn, question search, bookmarks list |
| Admin, content | SQLAdmin panel with audit log and report queue; CSV/JSON importer with dry run and near-duplicate check | — |

## Order

Each wave ends with ruff, mypy and pytest green on the backend and `flutter analyze` plus
`flutter test` green on mobile.

1. **Platform:** outbox, economy, inbox and push, settings, analytics, feedback. Mobile in
   parallel: the Learn tools that already have server support, then Inbox, Wallet and Settings.
2. **Ratings, progression and leaderboards**, plus **social and account**. Mobile: Social tab,
   leaderboards, missions and profile.
3. **Realtime engine and Quick Battle / Practice Bot**, end to end with protocol bots.
4. **Rooms** (friend duel, group battle, invites) and **tournaments**. Mobile: lobbies and Arena.
5. **Home, admin panel and importer** (Guess the Word was dropped at the product owner's request), then a final sweep for leftover
   placeholders.

## Out of scope in this repository

These need things this repository can't supply: Play Integrity (a Play Console app), a production
FCM project (push stays off without `google-services.json` and the service account), load tests
against real hosting, verifiable parental consent (an SMS or email provider), and the legal review.
