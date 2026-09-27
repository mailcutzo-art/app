import 'package:flutter/painting.dart';

import 'app_colors.dart';

/// Very soft shadows: the look is mostly flat, with depth only on floating
/// elements (nav bar, FAB, sheets).
abstract final class AppShadows {
  static List<BoxShadow> card(AppColors colors) => [
    BoxShadow(
      color: colors.shadow.withValues(alpha: colors.isDark ? 0.24 : 0.04),
      blurRadius: 16,
      offset: const Offset(0, 4),
    ),
  ];

  static List<BoxShadow> floating(AppColors colors) => [
    BoxShadow(
      color: colors.shadow.withValues(alpha: colors.isDark ? 0.4 : 0.10),
      blurRadius: 32,
      offset: const Offset(0, 12),
    ),
    BoxShadow(
      color: colors.shadow.withValues(alpha: colors.isDark ? 0.2 : 0.04),
      blurRadius: 6,
      offset: const Offset(0, 2),
    ),
  ];
}
