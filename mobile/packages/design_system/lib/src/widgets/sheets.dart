import 'package:flutter/material.dart';

import '../icons/app_icons.dart';
import '../icons/huge_icon.dart';
import '../icons/icon_shapes.dart';
import '../theme/app_theme.dart';
import '../tokens/app_dimens.dart';
import '../tokens/app_motion.dart';
import 'pressable.dart';

/// Shows a modal bottom sheet styled by the theme (rounded top, drag handle).
///
/// It opens on the root navigator by default, so it covers a floating nav bar
/// even when called from a screen inside a tab.
Future<T?> showAppSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  bool useRootNavigator = true,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    useRootNavigator: useRootNavigator,
    builder: builder,
  );
}

/// Standard sheet layout: title, optional subtitle, content, footer actions.
class SheetScaffold extends StatelessWidget {
  const SheetScaffold({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
    this.footer,
  });

  final String title;
  final String? subtitle;
  final Widget child;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final text = context.text;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.gutter,
              0,
              AppSpacing.gutter,
              AppSpacing.lg,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: text.headlineMedium),
                if (subtitle != null) ...[
                  const SizedBox(height: AppSpacing.xs),
                  Text(subtitle!, style: text.bodyMedium),
                ],
              ],
            ),
          ),
          Flexible(child: child),
          if (footer != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.gutter,
                AppSpacing.md,
                AppSpacing.gutter,
                AppSpacing.lg,
              ),
              child: footer,
            ),
        ],
      ),
    );
  }
}

/// Single-choice row for pickers (chapters, subjects, options).
class SelectableRow extends StatelessWidget {
  const SelectableRow({
    super.key,
    required this.title,
    required this.selected,
    required this.onTap,
    this.subtitle,
    this.icon,
    this.iconBackground,
    this.iconColor,
    this.trailingText,
    this.enabled = true,
  });

  final String title;
  final String? subtitle;
  final bool selected;
  final VoidCallback? onTap;
  final HugeIconData? icon;
  final Color? iconBackground;
  final Color? iconColor;
  final String? trailingText;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.text;
    final duration = AppMotion.of(context, AppMotion.fast);
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: Pressable(
        onPressed: enabled ? onTap : null,
        selected: selected,
        pressedScale: 0.98,
        child: AnimatedContainer(
          duration: duration,
          margin: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter, vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.md),
          decoration: BoxDecoration(
            color: selected ? colors.accentSoft : colors.surface,
            borderRadius: BorderRadius.circular(AppRadii.lg),
            border: Border.all(
              color: selected ? colors.ink : colors.outline,
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Row(
            children: [
              if (icon != null) ...[
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: iconBackground ?? colors.surfaceMuted,
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: HugeIcon(icon!, size: 22, color: iconColor ?? colors.ink),
                ),
                const SizedBox(width: AppSpacing.md),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: text.titleMedium.copyWith(fontSize: 16)),
                    if (subtitle != null) Text(subtitle!, style: text.caption),
                  ],
                ),
              ),
              if (trailingText != null) ...[
                Text(trailingText!, style: text.caption),
                const SizedBox(width: AppSpacing.md),
              ],
              AnimatedContainer(
                duration: duration,
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  color: selected ? colors.inverse : Colors.transparent,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: selected ? colors.inverse : colors.outlineStrong,
                    width: 1.5,
                  ),
                ),
                alignment: Alignment.center,
                child: selected
                    ? HugeIcon(AppIcons.check, size: 14, color: colors.onInverse, strokeWidth: 2.4)
                    : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// On/off row for a setting (e.g. "Timed"), styled like [SelectableRow].
/// Tapping anywhere on the row flips it.
class ToggleRow extends StatelessWidget {
  const ToggleRow({
    super.key,
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
    this.icon,
    this.margin = const EdgeInsets.symmetric(horizontal: AppSpacing.gutter, vertical: 4),
  });

  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final HugeIconData? icon;
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.text;
    final enabled = onChanged != null;
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: MergeSemantics(
        child: Pressable(
          onPressed: enabled ? () => onChanged!(!value) : null,
          pressedScale: 0.98,
          isButton: false,
          child: Container(
            margin: margin,
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              AppSpacing.sm,
              AppSpacing.sm,
              AppSpacing.sm,
            ),
            constraints: const BoxConstraints(minHeight: AppSizes.minTouch + AppSpacing.md),
            decoration: BoxDecoration(
              color: colors.surface,
              borderRadius: BorderRadius.circular(AppRadii.lg),
              border: Border.all(color: colors.outline),
            ),
            child: Row(
              children: [
                if (icon != null) ...[
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(color: colors.surfaceMuted, shape: BoxShape.circle),
                    alignment: Alignment.center,
                    child: HugeIcon(icon!, size: 22, color: colors.ink),
                  ),
                  const SizedBox(width: AppSpacing.md),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: text.titleMedium.copyWith(fontSize: 16)),
                      if (subtitle != null) Text(subtitle!, style: text.caption),
                    ],
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Switch(value: value, onChanged: onChanged),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Floating pill toast. Replaces any toast already showing.
void showAppToast(BuildContext context, String message, {HugeIconData? icon}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  final colors = context.colors;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Row(
          children: [
            if (icon != null) ...[
              HugeIcon(icon, size: 18, color: colors.onInverse),
              const SizedBox(width: AppSpacing.sm),
            ],
            Expanded(child: Text(message)),
          ],
        ),
        duration: const Duration(seconds: 3),
      ),
    );
}
