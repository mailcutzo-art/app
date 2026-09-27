# Quiz Arena (working name)

Live quiz battles, Swiss tournaments and practice for NEET and JEE aspirants.

| Part | Stack | Folder |
|---|---|---|
| Mobile app | Flutter 3.47 (Dart 3.13), Android first | [`mobile/`](mobile/) |
| Design system | Flutter package: tokens, theme, Hugeicons, motion, widgets | [`mobile/packages/design_system/`](mobile/packages/design_system/) |
| Backend | Python FastAPI (`api`, `rt` realtime, `worker`), PostgreSQL 16, Redis 7 | [`backend/`](backend/) |
| Plan | Architecture, feature specs, security, phases | [`docs/plan.md`](docs/plan.md) |

## Status

- **Phase 1 (design system):** tokens, light/dark theme, icon system with animated icons, ~40 widgets,
  a catalog app and golden screenshots of mock screens
  (`mobile/packages/design_system/example/test/goldens/`).
- **Phase 2 (foundations):** backend core in progress.
- **Content:** a small test question set for NEET and JEE ([`content/`](content/), format in
  [`docs/content-format.md`](docs/content-format.md)), validated in CI. The real bank comes later.

## Working on the mobile app

```bash
cd mobile/packages/design_system && flutter test            # unit tests
cd mobile/packages/design_system/example && flutter test    # golden screenshots
flutter test --update-goldens                               # re-record after an intended UI change
cd mobile/packages/design_system/example && flutter run -d chrome   # browse the catalog
```

CI (`.github/workflows/mobile.yml`) runs format, analyze and tests, then builds a debug APK and
uploads it as the `quiz-app-debug-apk` artifact.

## Credits

- Icons: [Hugeicons](https://hugeicons.com) free stroke-rounded set (MIT).
- Icon animations adapted from [AnimateIcons](https://animateicons.in) (MIT).
- Font: [Plus Jakarta Sans](https://github.com/tokotype/PlusJakartaSans) (SIL OFL 1.1).
