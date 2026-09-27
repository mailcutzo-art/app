import 'dart:math' as math;

import 'package:design_system/design_system.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

/// WCAG 2.x contrast ratio between two opaque colors.
double contrast(Color a, Color b) {
  double channel(double c) =>
      c <= 0.03928 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
  double luminance(Color c) =>
      0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);
  final la = luminance(a);
  final lb = luminance(b);
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

void main() {
  for (final colors in [AppColors.light, AppColors.dark]) {
    group('${colors.brightness.name} palette meets WCAG AA', () {
      const body = 4.5;
      const large = 3.0;

      test('text on backgrounds', () {
        for (final bg in [colors.paper, colors.surface, colors.surfaceMuted]) {
          expect(contrast(colors.ink, bg), greaterThanOrEqualTo(body));
          expect(contrast(colors.inkMuted, bg), greaterThanOrEqualTo(body));
        }
      });

      test('buttons', () {
        expect(contrast(colors.onAccent, colors.accent), greaterThanOrEqualTo(body));
        expect(contrast(colors.onInverse, colors.inverse), greaterThanOrEqualTo(body));
      });

      test('pastel pairs', () {
        for (final tone in PastelTone.values) {
          final pair = colors.pastel(tone);
          expect(
            contrast(pair.onContainer, pair.container),
            greaterThanOrEqualTo(body),
            reason: '$tone',
          );
          expect(contrast(colors.ink, pair.container), greaterThanOrEqualTo(body), reason: '$tone');
        }
      });

      test('status containers', () {
        expect(
          contrast(colors.onSuccessContainer, colors.successContainer),
          greaterThanOrEqualTo(body),
        );
        expect(
          contrast(colors.onErrorContainer, colors.errorContainer),
          greaterThanOrEqualTo(body),
        );
        expect(
          contrast(colors.onWarningContainer, colors.warningContainer),
          greaterThanOrEqualTo(body),
        );
      });

      test('icons and large status marks', () {
        expect(contrast(colors.success, colors.surface), greaterThanOrEqualTo(large));
        expect(contrast(colors.error, colors.surface), greaterThanOrEqualTo(large));
      });
    });
  }

  test('theme exposes tokens through context-free accessors', () {
    final theme = AppTheme.light();
    expect(theme.extension<AppColors>(), same(AppColors.light));
    expect(theme.extension<AppTypography>(), isNotNull);
    expect(AppTheme.dark().extension<AppColors>()!.isDark, isTrue);
  });

  test('colors lerp between themes', () {
    final mid = AppColors.light.lerp(AppColors.dark, 0.5);
    expect(mid.ink, Color.lerp(AppColors.light.ink, AppColors.dark.ink, 0.5));
    expect(AppColors.light.lerp(null, 0.5), same(AppColors.light));
  });
}
