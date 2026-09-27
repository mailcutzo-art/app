import 'package:flutter/material.dart';

import 'app_colors.dart';

/// Type scale built on Plus Jakarta Sans (bundled with this package).
///
/// Numeric styles use tabular figures so timers, scores and ratings don't
/// jitter as digits change.
@immutable
class AppTypography extends ThemeExtension<AppTypography> {
  const AppTypography({
    required this.display,
    required this.headlineLarge,
    required this.headlineMedium,
    required this.titleLarge,
    required this.titleMedium,
    required this.bodyLarge,
    required this.bodyMedium,
    required this.bodySmall,
    required this.labelLarge,
    required this.labelMedium,
    required this.caption,
    required this.overline,
    required this.numericDisplay,
    required this.numericLarge,
    required this.numericMedium,
  });

  static const fontFamily = 'PlusJakartaSans';
  static const fontPackage = 'design_system';
  static const _tabular = [FontFeature.tabularFigures()];

  /// Glyphs Plus Jakarta Sans lacks (e.g. θ, λ) fall back to Roboto, which is
  /// the Android system font; other platforms use their own system fallback.
  static const fallback = ['Roboto'];

  final TextStyle display;
  final TextStyle headlineLarge;
  final TextStyle headlineMedium;
  final TextStyle titleLarge;
  final TextStyle titleMedium;
  final TextStyle bodyLarge;
  final TextStyle bodyMedium;
  final TextStyle bodySmall;
  final TextStyle labelLarge;
  final TextStyle labelMedium;
  final TextStyle caption;
  final TextStyle overline;
  final TextStyle numericDisplay;
  final TextStyle numericLarge;
  final TextStyle numericMedium;

  static TextStyle _base({
    required double size,
    required double height,
    required FontWeight weight,
    required Color color,
    double tracking = 0,
    List<FontFeature>? features,
  }) => TextStyle(
    // Full family name instead of `package:` so the fallback isn't prefixed too.
    fontFamily: 'packages/$fontPackage/$fontFamily',
    fontFamilyFallback: fallback,
    fontSize: size,
    height: height / size,
    fontWeight: weight,
    letterSpacing: tracking,
    color: color,
    fontFeatures: features,
    leadingDistribution: TextLeadingDistribution.even,
  );

  factory AppTypography.from(AppColors colors) {
    final ink = colors.ink;
    final muted = colors.inkMuted;
    return AppTypography(
      display: _base(size: 40, height: 44, weight: FontWeight.w800, color: ink, tracking: -0.8),
      headlineLarge: _base(
        size: 32,
        height: 38,
        weight: FontWeight.w700,
        color: ink,
        tracking: -0.6,
      ),
      headlineMedium: _base(
        size: 26,
        height: 32,
        weight: FontWeight.w700,
        color: ink,
        tracking: -0.4,
      ),
      titleLarge: _base(size: 20, height: 26, weight: FontWeight.w700, color: ink, tracking: -0.2),
      titleMedium: _base(size: 17, height: 22, weight: FontWeight.w600, color: ink, tracking: -0.1),
      bodyLarge: _base(size: 16, height: 24, weight: FontWeight.w500, color: ink),
      bodyMedium: _base(size: 14, height: 20, weight: FontWeight.w500, color: muted),
      bodySmall: _base(size: 13, height: 18, weight: FontWeight.w500, color: muted),
      labelLarge: _base(size: 16, height: 20, weight: FontWeight.w700, color: ink),
      labelMedium: _base(size: 13, height: 16, weight: FontWeight.w600, color: ink),
      caption: _base(size: 12, height: 16, weight: FontWeight.w500, color: muted),
      overline: _base(size: 11, height: 14, weight: FontWeight.w700, color: muted, tracking: 0.7),
      numericDisplay: _base(
        size: 44,
        height: 48,
        weight: FontWeight.w800,
        color: ink,
        tracking: -1.2,
        features: _tabular,
      ),
      numericLarge: _base(
        size: 28,
        height: 32,
        weight: FontWeight.w800,
        color: ink,
        tracking: -0.6,
        features: _tabular,
      ),
      numericMedium: _base(
        size: 17,
        height: 22,
        weight: FontWeight.w700,
        color: ink,
        features: _tabular,
      ),
    );
  }

  /// Material text theme so stock widgets (dialogs, text fields) match.
  TextTheme toTextTheme() => TextTheme(
    displayLarge: display,
    displayMedium: headlineLarge,
    displaySmall: headlineMedium,
    headlineLarge: headlineLarge,
    headlineMedium: headlineMedium,
    headlineSmall: titleLarge,
    titleLarge: titleLarge,
    titleMedium: titleMedium,
    titleSmall: labelMedium,
    bodyLarge: bodyLarge,
    bodyMedium: bodyMedium,
    bodySmall: bodySmall,
    labelLarge: labelLarge,
    labelMedium: labelMedium,
    labelSmall: caption,
  );

  @override
  AppTypography copyWith() => this;

  @override
  AppTypography lerp(covariant AppTypography? other, double t) {
    if (other == null) return this;
    TextStyle l(TextStyle a, TextStyle b) => TextStyle.lerp(a, b, t)!;
    return AppTypography(
      display: l(display, other.display),
      headlineLarge: l(headlineLarge, other.headlineLarge),
      headlineMedium: l(headlineMedium, other.headlineMedium),
      titleLarge: l(titleLarge, other.titleLarge),
      titleMedium: l(titleMedium, other.titleMedium),
      bodyLarge: l(bodyLarge, other.bodyLarge),
      bodyMedium: l(bodyMedium, other.bodyMedium),
      bodySmall: l(bodySmall, other.bodySmall),
      labelLarge: l(labelLarge, other.labelLarge),
      labelMedium: l(labelMedium, other.labelMedium),
      caption: l(caption, other.caption),
      overline: l(overline, other.overline),
      numericDisplay: l(numericDisplay, other.numericDisplay),
      numericLarge: l(numericLarge, other.numericLarge),
      numericMedium: l(numericMedium, other.numericMedium),
    );
  }
}
