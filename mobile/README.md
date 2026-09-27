# Mobile app (Flutter)

- `lib/` — the app (routing, features and data layers arrive in plan phase 2+).
- `packages/design_system/` — tokens, theme, icons, motion and widgets, with unit tests.
- `packages/design_system/example/` — catalog app with mock screens; its tests record golden
  screenshots in `test/goldens/{light,dark}/`.

Shared lint and formatter settings live in `analysis_options.yaml` (100-column lines).
