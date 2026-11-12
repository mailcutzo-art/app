# Mobile app (Flutter)

- `lib/` — the app (routing, features and data layers arrive in plan phase 2+).
- `packages/design_system/` — tokens, theme, icons, motion and widgets, with unit tests.
- `packages/design_system/example/` — catalog app with mock screens; its tests record golden
  screenshots in `test/goldens/{light,dark}/`.

Shared lint and formatter settings live in `analysis_options.yaml` (100-column lines).

## Sound effects

`assets/sounds/*.wav` are generated, not recorded: `python3 tool/generate_sounds.py` (no
dependencies) rebuilds them. They are deliberately soft and low (warm mallet tones under about
600 Hz, low-passed, normalised with headroom). `lib/core/sound/sound_effects.dart` plays them only
when Settings → Sounds is on, mixed with other audio and silent in silent mode.
