import 'package:flutter/material.dart';

import '../icons/huge_icon.dart';
import '../icons/icon_shapes.dart';
import '../theme/app_theme.dart';
import '../tokens/app_colors.dart';
import '../tokens/app_dimens.dart';
import '../tokens/app_motion.dart';
import 'pressable.dart';

/// Selectable pill for filters and choices (status, subject, entry fee…).
class AppChip extends StatelessWidget {
  const AppChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onSelected,
    this.icon,
    this.dotColor,
  });

  final String label;
  final bool selected;
  final ValueChanged<bool>? onSelected;
  final HugeIconData? icon;

  /// Small colored dot before the label (e.g. a subject color).
  final Color? dotColor;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final fg = selected ? colors.onInverse : colors.ink;
    return Pressable(
      onPressed: onSelected == null ? null : () => onSelected!(!selected),
      selected: selected,
      pressedScale: 0.95,
      child: AnimatedContainer(
        duration: AppMotion.fast,
        curve: AppMotion.standard,
        height: AppSizes.chip,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
        decoration: ShapeDecoration(
          color: selected ? colors.inverse : colors.surface,
          shape: StadiumBorder(side: BorderSide(color: selected ? colors.inverse : colors.outline)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (dotColor != null) ...[
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
              ),
              const SizedBox(width: AppSpacing.sm),
            ] else if (icon != null) ...[
              HugeIcon(icon!, size: 18, color: fg),
              const SizedBox(width: AppSpacing.sm - 2),
            ],
            Text(label, style: context.text.labelMedium.copyWith(color: fg)),
          ],
        ),
      ),
    );
  }
}

/// Non-interactive icon + text pill (e.g. "6 rounds", "1km to centre").
class InfoChip extends StatelessWidget {
  const InfoChip({
    super.key,
    required this.label,
    this.icon,
    this.iconColor,
    this.background,
    this.foreground,
  });

  final String label;
  final HugeIconData? icon;
  final Color? iconColor;
  final Color? background;
  final Color? foreground;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final fg = foreground ?? colors.ink;
    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
      decoration: BoxDecoration(
        color: background ?? colors.surface.withValues(alpha: 0.7),
        borderRadius: AppRadii.pillAll,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            HugeIcon(icon!, size: 16, color: iconColor ?? fg),
            const SizedBox(width: 6),
          ],
          Text(label, style: context.text.labelMedium.copyWith(color: fg)),
        ],
      ),
    );
  }
}

/// Small uppercase status pill ("REGISTRATION OPEN", "BIOLOGY", "NEW").
class OverlineBadge extends StatelessWidget {
  const OverlineBadge({
    super.key,
    required this.label,
    this.tone = PastelTone.neutral,
    this.icon,
    this.solid = false,
  });

  final String label;
  final PastelTone tone;
  final HugeIconData? icon;

  /// Ink background instead of pastel.
  final bool solid;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final pair = colors.pastel(tone);
    final bg = solid ? colors.inverse : pair.container;
    final fg = solid ? colors.onInverse : pair.onContainer;
    return Container(
      height: 26,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(color: bg, borderRadius: AppRadii.pillAll),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[HugeIcon(icon!, size: 14, color: fg), const SizedBox(width: 5)],
          Flexible(
            child: Text(
              label.toUpperCase(),
              style: context.text.overline.copyWith(color: fg),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// "LIVE" badge with a softly pulsing dot.
class LiveBadge extends StatefulWidget {
  const LiveBadge({super.key, this.label = 'Live'});

  final String label;

  @override
  State<LiveBadge> createState() => _LiveBadgeState();
}

class _LiveBadgeState extends State<LiveBadge> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (AppMotion.reduced(context)) {
      _controller.stop();
    } else if (!_controller.isAnimating) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      height: 26,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(color: colors.errorContainer, borderRadius: AppRadii.pillAll),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          FadeTransition(
            opacity: Tween<double>(begin: 0.35, end: 1).animate(_controller),
            child: Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(color: colors.error, shape: BoxShape.circle),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            widget.label.toUpperCase(),
            style: context.text.overline.copyWith(color: colors.onErrorContainer),
          ),
        ],
      ),
    );
  }
}
