# design_system

Pastel, minimal design system for the quiz app.

- **Tokens:** `AppColors` (light/dark, pastel families), `AppTypography` (Plus Jakarta Sans,
  tabular figures), `AppSpacing`, `AppRadii`, `AppSizes` (60dp buttons, 52dp icon buttons),
  `AppMotion` (durations, curves, reduced-motion aware).
- **Theme:** `AppTheme.light()` / `AppTheme.dark()`; read tokens with `context.colors` and
  `context.text`.
- **Icons:** `AppIcons` (Hugeicons stroke-rounded), drawn by `HugeIcon`; `AnimatedHugeIcon` plays
  `IconMotions` ported from AnimateIcons.
- **Widgets:** buttons, segmented control, chips and badges, cards and tiles, floating nav bar,
  headers, avatars, progress and countdown, number ticker, quiz widgets (question card, answer
  options, versus header, matchmaking pulse), tournament card, leaderboard, podium, dot-matrix chart,
  sheets and toggle rows, inputs, and empty / error / offline / skeleton states.

Run `flutter test` here for unit tests, and in `example/` for golden screenshots.
