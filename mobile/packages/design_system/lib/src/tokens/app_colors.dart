import 'package:flutter/material.dart';

/// Named pastel families used for tiles, subject accents and badges.
enum PastelTone { sky, mint, lemon, lavender, peach, rose, lime, neutral }

/// A pastel container color and the readable foreground drawn on top of it.
@immutable
class PastelPair {
  const PastelPair({required this.container, required this.onContainer});

  final Color container;
  final Color onContainer;

  static PastelPair lerp(PastelPair a, PastelPair b, double t) => PastelPair(
    container: Color.lerp(a.container, b.container, t)!,
    onContainer: Color.lerp(a.onContainer, b.onContainer, t)!,
  );
}

/// Semantic color tokens. Widgets read these instead of raw hex values so the
/// light and dark themes (and any future re-skin) stay consistent.
@immutable
class AppColors extends ThemeExtension<AppColors> {
  const AppColors({
    required this.brightness,
    required this.paper,
    required this.paperGradientStart,
    required this.paperGradientEnd,
    required this.surface,
    required this.surfaceMuted,
    required this.surfaceSunken,
    required this.outline,
    required this.outlineStrong,
    required this.ink,
    required this.inkMuted,
    required this.inkSubtle,
    required this.inverse,
    required this.onInverse,
    required this.accent,
    required this.accentPressed,
    required this.onAccent,
    required this.accentSoft,
    required this.success,
    required this.successContainer,
    required this.onSuccessContainer,
    required this.error,
    required this.errorContainer,
    required this.onErrorContainer,
    required this.warning,
    required this.warningContainer,
    required this.onWarningContainer,
    required this.coin,
    required this.scrim,
    required this.shadow,
    required this.sky,
    required this.mint,
    required this.lemon,
    required this.lavender,
    required this.peach,
    required this.rose,
  });

  final Brightness brightness;

  /// App background and the soft mint→lemon wash behind hero areas.
  final Color paper;
  final Color paperGradientStart;
  final Color paperGradientEnd;

  /// Cards and raised surfaces.
  final Color surface;
  final Color surfaceMuted;
  final Color surfaceSunken;

  /// Hairline borders and dividers.
  final Color outline;
  final Color outlineStrong;

  /// Text and strong controls.
  final Color ink;
  final Color inkMuted;

  /// Decorative or disabled content only; too light for body text.
  final Color inkSubtle;

  /// The "ink pill": selected segments, FAB, active nav item.
  final Color inverse;
  final Color onInverse;

  /// Lime brand accent used for primary calls to action.
  final Color accent;
  final Color accentPressed;
  final Color onAccent;
  final Color accentSoft;

  final Color success;
  final Color successContainer;
  final Color onSuccessContainer;
  final Color error;
  final Color errorContainer;
  final Color onErrorContainer;
  final Color warning;
  final Color warningContainer;
  final Color onWarningContainer;

  final Color coin;
  final Color scrim;
  final Color shadow;

  final PastelPair sky;
  final PastelPair mint;
  final PastelPair lemon;
  final PastelPair lavender;
  final PastelPair peach;
  final PastelPair rose;

  bool get isDark => brightness == Brightness.dark;

  PastelPair pastel(PastelTone tone) => switch (tone) {
    PastelTone.sky => sky,
    PastelTone.mint => mint,
    PastelTone.lemon => lemon,
    PastelTone.lavender => lavender,
    PastelTone.peach => peach,
    PastelTone.rose => rose,
    PastelTone.lime => PastelPair(container: accentSoft, onContainer: ink),
    PastelTone.neutral => PastelPair(container: surfaceMuted, onContainer: ink),
  };

  static const light = AppColors(
    brightness: Brightness.light,
    paper: Color(0xFFF5F6F0),
    paperGradientStart: Color(0xFFE2F2E6),
    paperGradientEnd: Color(0xFFF2F6D6),
    surface: Color(0xFFFFFFFF),
    surfaceMuted: Color(0xFFF0F1EA),
    surfaceSunken: Color(0xFFE8EAE1),
    outline: Color(0xFFE6E8DF),
    outlineStrong: Color(0xFFD3D7CA),
    ink: Color(0xFF141813),
    inkMuted: Color(0xFF5B6158),
    inkSubtle: Color(0xFF9AA095),
    inverse: Color(0xFF141813),
    onInverse: Color(0xFFFFFFFF),
    accent: Color(0xFFCBE54E),
    accentPressed: Color(0xFFBBD53F),
    onAccent: Color(0xFF141813),
    accentSoft: Color(0xFFEEF7C4),
    success: Color(0xFF2F9E5E),
    successContainer: Color(0xFFE1F4E8),
    onSuccessContainer: Color(0xFF1F7043),
    error: Color(0xFFD84A4A),
    errorContainer: Color(0xFFFBE5E5),
    onErrorContainer: Color(0xFFA42F2F),
    warning: Color(0xFFC68A0A),
    warningContainer: Color(0xFFFDF1D3),
    onWarningContainer: Color(0xFF7A5406),
    coin: Color(0xFFE9B308),
    scrim: Color(0x66141813),
    shadow: Color(0xFF141813),
    sky: PastelPair(container: Color(0xFFDDEEFB), onContainer: Color(0xFF28648F)),
    mint: PastelPair(container: Color(0xFFDDF2E3), onContainer: Color(0xFF2A6E45)),
    lemon: PastelPair(container: Color(0xFFFBF4C4), onContainer: Color(0xFF70600C)),
    lavender: PastelPair(container: Color(0xFFEAE4F8), onContainer: Color(0xFF5E4396)),
    peach: PastelPair(container: Color(0xFFFCE5D6), onContainer: Color(0xFF964A24)),
    rose: PastelPair(container: Color(0xFFFAE1E6), onContainer: Color(0xFF9C3049)),
  );

  static const dark = AppColors(
    brightness: Brightness.dark,
    paper: Color(0xFF0E110F),
    paperGradientStart: Color(0xFF132019),
    paperGradientEnd: Color(0xFF1B1F10),
    surface: Color(0xFF171B18),
    surfaceMuted: Color(0xFF1E231F),
    surfaceSunken: Color(0xFF242A25),
    outline: Color(0xFF2A302B),
    outlineStrong: Color(0xFF3A413B),
    ink: Color(0xFFF1F4EC),
    inkMuted: Color(0xFFA8AFA3),
    inkSubtle: Color(0xFF6F766B),
    inverse: Color(0xFFF1F4EC),
    onInverse: Color(0xFF0E110F),
    accent: Color(0xFFD3EC5C),
    accentPressed: Color(0xFFC2DB4B),
    onAccent: Color(0xFF0E110F),
    accentSoft: Color(0xFF2A3314),
    success: Color(0xFF5CC98A),
    successContainer: Color(0xFF173222),
    onSuccessContainer: Color(0xFF9BE3B8),
    error: Color(0xFFF07A7A),
    errorContainer: Color(0xFF3A1B1B),
    onErrorContainer: Color(0xFFF7B4B4),
    warning: Color(0xFFE8B64C),
    warningContainer: Color(0xFF362A10),
    onWarningContainer: Color(0xFFF2D38E),
    coin: Color(0xFFF2C94C),
    scrim: Color(0x99000000),
    shadow: Color(0xFF000000),
    sky: PastelPair(container: Color(0xFF1B2A36), onContainer: Color(0xFF9CCBF0)),
    mint: PastelPair(container: Color(0xFF1B2E22), onContainer: Color(0xFF98D9AE)),
    lemon: PastelPair(container: Color(0xFF302C12), onContainer: Color(0xFFE8D77A)),
    lavender: PastelPair(container: Color(0xFF28223A), onContainer: Color(0xFFC3B2EE)),
    peach: PastelPair(container: Color(0xFF36241A), onContainer: Color(0xFFF0B894)),
    rose: PastelPair(container: Color(0xFF36202A), onContainer: Color(0xFFF0A6BA)),
  );

  @override
  AppColors copyWith({Brightness? brightness}) =>
      brightness == null || brightness == this.brightness
      ? this
      : (brightness == Brightness.dark ? dark : light);

  @override
  AppColors lerp(covariant AppColors? other, double t) {
    if (other == null) return this;
    Color c(Color a, Color b) => Color.lerp(a, b, t)!;
    return AppColors(
      brightness: t < 0.5 ? brightness : other.brightness,
      paper: c(paper, other.paper),
      paperGradientStart: c(paperGradientStart, other.paperGradientStart),
      paperGradientEnd: c(paperGradientEnd, other.paperGradientEnd),
      surface: c(surface, other.surface),
      surfaceMuted: c(surfaceMuted, other.surfaceMuted),
      surfaceSunken: c(surfaceSunken, other.surfaceSunken),
      outline: c(outline, other.outline),
      outlineStrong: c(outlineStrong, other.outlineStrong),
      ink: c(ink, other.ink),
      inkMuted: c(inkMuted, other.inkMuted),
      inkSubtle: c(inkSubtle, other.inkSubtle),
      inverse: c(inverse, other.inverse),
      onInverse: c(onInverse, other.onInverse),
      accent: c(accent, other.accent),
      accentPressed: c(accentPressed, other.accentPressed),
      onAccent: c(onAccent, other.onAccent),
      accentSoft: c(accentSoft, other.accentSoft),
      success: c(success, other.success),
      successContainer: c(successContainer, other.successContainer),
      onSuccessContainer: c(onSuccessContainer, other.onSuccessContainer),
      error: c(error, other.error),
      errorContainer: c(errorContainer, other.errorContainer),
      onErrorContainer: c(onErrorContainer, other.onErrorContainer),
      warning: c(warning, other.warning),
      warningContainer: c(warningContainer, other.warningContainer),
      onWarningContainer: c(onWarningContainer, other.onWarningContainer),
      coin: c(coin, other.coin),
      scrim: c(scrim, other.scrim),
      shadow: c(shadow, other.shadow),
      sky: PastelPair.lerp(sky, other.sky, t),
      mint: PastelPair.lerp(mint, other.mint, t),
      lemon: PastelPair.lerp(lemon, other.lemon, t),
      lavender: PastelPair.lerp(lavender, other.lavender, t),
      peach: PastelPair.lerp(peach, other.peach, t),
      rose: PastelPair.lerp(rose, other.rose, t),
    );
  }
}
