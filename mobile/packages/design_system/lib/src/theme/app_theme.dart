import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../tokens/app_colors.dart';
import '../tokens/app_dimens.dart';
import '../tokens/app_typography.dart';

/// Builds [ThemeData] from the design tokens. Stock Material widgets are tuned
/// to match, but most screens use this package's own widgets.
abstract final class AppTheme {
  static ThemeData light() => _build(AppColors.light);
  static ThemeData dark() => _build(AppColors.dark);

  static ThemeData _build(AppColors c) {
    final type = AppTypography.from(c);
    final scheme = ColorScheme(
      brightness: c.brightness,
      primary: c.accent,
      onPrimary: c.onAccent,
      primaryContainer: c.accentSoft,
      onPrimaryContainer: c.ink,
      secondary: c.inverse,
      onSecondary: c.onInverse,
      secondaryContainer: c.surfaceMuted,
      onSecondaryContainer: c.ink,
      tertiary: c.lavender.onContainer,
      onTertiary: c.surface,
      tertiaryContainer: c.lavender.container,
      onTertiaryContainer: c.lavender.onContainer,
      error: c.error,
      onError: c.surface,
      errorContainer: c.errorContainer,
      onErrorContainer: c.onErrorContainer,
      surface: c.surface,
      onSurface: c.ink,
      onSurfaceVariant: c.inkMuted,
      surfaceContainerLowest: c.surface,
      surfaceContainerLow: c.paper,
      surfaceContainer: c.surfaceMuted,
      surfaceContainerHigh: c.surfaceMuted,
      surfaceContainerHighest: c.surfaceSunken,
      outline: c.outlineStrong,
      outlineVariant: c.outline,
      shadow: c.shadow,
      scrim: c.scrim,
      inverseSurface: c.inverse,
      onInverseSurface: c.onInverse,
      inversePrimary: c.accent,
      surfaceTint: Colors.transparent,
    );

    final overlayStyle = c.isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark;

    return ThemeData(
      useMaterial3: true,
      brightness: c.brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: c.paper,
      canvasColor: c.paper,
      fontFamily: 'packages/${AppTypography.fontPackage}/${AppTypography.fontFamily}',
      textTheme: type.toTextTheme(),
      extensions: [c, type],
      splashColor: c.ink.withValues(alpha: 0.06),
      highlightColor: Colors.transparent,
      hoverColor: c.ink.withValues(alpha: 0.04),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: PredictiveBackPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        },
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        foregroundColor: c.ink,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: type.titleMedium,
        systemOverlayStyle: overlayStyle.copyWith(statusBarColor: Colors.transparent),
      ),
      dividerTheme: DividerThemeData(color: c.outline, thickness: 1, space: 1),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: c.surface,
        modalBackgroundColor: c.surface,
        surfaceTintColor: Colors.transparent,
        modalBarrierColor: c.scrim,
        elevation: 0,
        modalElevation: 0,
        showDragHandle: true,
        dragHandleColor: c.outlineStrong,
        dragHandleSize: const Size(40, 4),
        shape: const RoundedRectangleBorder(borderRadius: AppRadii.sheet),
        clipBehavior: Clip.antiAlias,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: c.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadii.xxl)),
        titleTextStyle: type.titleLarge,
        contentTextStyle: type.bodyMedium,
        barrierColor: c.scrim,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: c.inverse,
        contentTextStyle: type.labelMedium.copyWith(color: c.onInverse),
        actionTextColor: c.accent,
        elevation: 0,
        shape: const StadiumBorder(),
        insetPadding: const EdgeInsets.fromLTRB(
          AppSpacing.gutter,
          0,
          AppSpacing.gutter,
          AppSpacing.lg,
        ),
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: c.ink,
        selectionColor: c.accent.withValues(alpha: 0.5),
        selectionHandleColor: c.ink,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: c.surfaceMuted,
        hintStyle: type.bodyLarge.copyWith(color: c.inkSubtle),
        labelStyle: type.labelMedium.copyWith(color: c.inkMuted),
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadii.lg),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadii.lg),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadii.lg),
          borderSide: BorderSide(color: c.ink, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadii.lg),
          borderSide: BorderSide(color: c.error, width: 1.5),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadii.lg),
          borderSide: BorderSide(color: c.error, width: 1.5),
        ),
        errorStyle: type.caption.copyWith(color: c.onErrorContainer),
      ),
      // On is the ink pill used for every selected state; off is a sunken track.
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? c.onInverse : c.inkMuted,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? c.inverse : c.surfaceSunken,
        ),
        trackOutlineColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected) ? c.inverse : c.outlineStrong,
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: c.ink,
        linearTrackColor: c.surfaceSunken,
        circularTrackColor: Colors.transparent,
      ),
      iconTheme: IconThemeData(color: c.ink, size: AppSizes.icon),
    );
  }
}

/// Short accessors: `context.colors.ink`, `context.text.titleLarge`.
extension AppThemeContext on BuildContext {
  AppColors get colors => Theme.of(this).extension<AppColors>() ?? AppColors.light;

  AppTypography get text => Theme.of(this).extension<AppTypography>() ?? AppTypography.from(colors);
}
