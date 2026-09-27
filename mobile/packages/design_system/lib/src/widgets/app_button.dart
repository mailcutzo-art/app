import 'package:flutter/material.dart';

import '../icons/huge_icon.dart';
import '../icons/icon_shapes.dart';
import '../theme/app_theme.dart';
import '../tokens/app_colors.dart';
import '../tokens/app_dimens.dart';
import '../tokens/app_motion.dart';
import 'pressable.dart';

enum AppButtonVariant {
  /// Lime pill: the one main action on a screen.
  primary,

  /// Ink pill: strong secondary action.
  ink,

  /// White pill with a hairline border.
  secondary,

  /// Pastel pill; pick the family with [AppButton.tone].
  tonal,

  /// Text-only.
  ghost,

  /// Destructive action.
  danger,
}

enum AppButtonSize { large, medium, small }

/// Pill button with generous height, optional icons and a loading state that
/// keeps the button's width stable.
class AppButton extends StatelessWidget {
  const AppButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.variant = AppButtonVariant.primary,
    this.size = AppButtonSize.large,
    this.leadingIcon,
    this.trailingIcon,
    this.loading = false,
    this.expand = true,
    this.tone = PastelTone.neutral,
  });

  final String label;
  final VoidCallback? onPressed;
  final AppButtonVariant variant;
  final AppButtonSize size;
  final HugeIconData? leadingIcon;
  final HugeIconData? trailingIcon;
  final bool loading;

  /// Fill the available width (true) or hug the content.
  final bool expand;
  final PastelTone tone;

  bool get _enabled => onPressed != null && !loading;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.text;
    final (bg, fg, border) = _palette(colors);

    final height = switch (size) {
      AppButtonSize.large => AppSizes.buttonLarge,
      AppButtonSize.medium => AppSizes.buttonMedium,
      AppButtonSize.small => AppSizes.buttonSmall,
    };
    final padding = switch (size) {
      AppButtonSize.large => 28.0,
      AppButtonSize.medium => 24.0,
      AppButtonSize.small => 16.0,
    };
    final iconSize = switch (size) {
      AppButtonSize.large => 22.0,
      AppButtonSize.medium => 20.0,
      AppButtonSize.small => 18.0,
    };
    final style = (size == AppButtonSize.small ? text.labelMedium : text.labelLarge).copyWith(
      color: fg,
    );

    final content = Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (leadingIcon != null) ...[
          HugeIcon(leadingIcon!, size: iconSize, color: fg),
          const SizedBox(width: AppSpacing.sm),
        ],
        Flexible(
          child: Text(label, style: style, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        if (trailingIcon != null) ...[
          const SizedBox(width: AppSpacing.sm),
          HugeIcon(trailingIcon!, size: iconSize, color: fg),
        ],
      ],
    );

    return Pressable(
      onPressed: _enabled ? onPressed : null,
      semanticLabel: loading ? '$label, loading' : null,
      haptic: variant == AppButtonVariant.primary ? HapticKind.light : HapticKind.selection,
      child: AnimatedContainer(
        duration: AppMotion.fast,
        curve: AppMotion.standard,
        height: height,
        width: expand ? double.infinity : null,
        padding: EdgeInsets.symmetric(horizontal: padding),
        decoration: ShapeDecoration(
          color: bg,
          shape: StadiumBorder(side: border == null ? BorderSide.none : BorderSide(color: border)),
        ),
        child: Center(
          widthFactor: 1,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Opacity(opacity: loading ? 0 : 1, child: content),
              if (loading)
                SizedBox.square(
                  dimension: iconSize,
                  child: CircularProgressIndicator(strokeWidth: 2.4, color: fg),
                ),
            ],
          ),
        ),
      ),
    );
  }

  (Color bg, Color fg, Color? border) _palette(AppColors c) {
    if (onPressed == null && !loading) {
      return (c.surfaceSunken, c.inkSubtle, null);
    }
    return switch (variant) {
      AppButtonVariant.primary => (c.accent, c.onAccent, null),
      AppButtonVariant.ink => (c.inverse, c.onInverse, null),
      AppButtonVariant.secondary => (c.surface, c.ink, c.outlineStrong),
      AppButtonVariant.tonal => (c.pastel(tone).container, c.pastel(tone).onContainer, null),
      AppButtonVariant.ghost => (Colors.transparent, c.ink, null),
      AppButtonVariant.danger => (c.errorContainer, c.onErrorContainer, null),
    };
  }
}
