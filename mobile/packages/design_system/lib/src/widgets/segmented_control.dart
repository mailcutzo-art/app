import 'package:flutter/material.dart';

import '../icons/huge_icon.dart';
import '../icons/icon_shapes.dart';
import '../theme/app_theme.dart';
import '../tokens/app_dimens.dart';
import '../tokens/app_motion.dart';
import '../tokens/app_shadows.dart';
import 'pressable.dart';

@immutable
class AppSegment<T> {
  const AppSegment({required this.value, required this.label, this.icon, this.enabled = true});

  final T value;
  final String label;
  final HugeIconData? icon;

  /// A disabled segment is greyed out and can't be picked (e.g. Casual without enough coins).
  final bool enabled;
}

/// Pill segmented control with a sliding ink indicator (e.g. Rated / Casual).
class AppSegmentedControl<T> extends StatelessWidget {
  const AppSegmentedControl({
    super.key,
    required this.segments,
    required this.selected,
    required this.onChanged,
    this.height = AppSizes.buttonMedium,
  }) : assert(segments.length >= 2);

  final List<AppSegment<T>> segments;
  final T selected;
  final ValueChanged<T>? onChanged;
  final double height;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.text;
    final index = segments.indexWhere((s) => s.value == selected);
    final duration = AppMotion.of(context, AppMotion.medium);
    const inset = 4.0;

    return Container(
      height: height,
      padding: const EdgeInsets.all(inset),
      decoration: BoxDecoration(color: colors.surfaceMuted, borderRadius: AppRadii.pillAll),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final segmentWidth = constraints.maxWidth / segments.length;
          return Stack(
            children: [
              if (index >= 0)
                AnimatedPositioned(
                  duration: duration,
                  curve: AppMotion.emphasized,
                  left: segmentWidth * index,
                  top: 0,
                  bottom: 0,
                  width: segmentWidth,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: colors.inverse,
                      borderRadius: AppRadii.pillAll,
                      boxShadow: AppShadows.card(colors),
                    ),
                  ),
                ),
              Row(
                children: [
                  for (final segment in segments)
                    Expanded(
                      child: Pressable(
                        onPressed: onChanged == null || !segment.enabled
                            ? null
                            : () => onChanged!(segment.value),
                        selected: segment.value == selected,
                        pressedScale: 0.97,
                        child: _SegmentLabel(
                          segment: segment,
                          selected: segment.value == selected,
                          style: text.labelLarge,
                          selectedColor: colors.onInverse,
                          color: segment.enabled ? colors.inkMuted : colors.inkSubtle,
                          duration: duration,
                        ),
                      ),
                    ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

class _SegmentLabel<T> extends StatelessWidget {
  const _SegmentLabel({
    required this.segment,
    required this.selected,
    required this.style,
    required this.selectedColor,
    required this.color,
    required this.duration,
  });

  final AppSegment<T> segment;
  final bool selected;
  final TextStyle style;
  final Color selectedColor;
  final Color color;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    final fg = selected ? selectedColor : color;
    return Center(
      child: AnimatedDefaultTextStyle(
        duration: duration,
        style: style.copyWith(color: fg),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (segment.icon != null) ...[
              TweenAnimationBuilder<Color?>(
                tween: ColorTween(end: fg),
                duration: duration,
                builder: (context, value, _) => HugeIcon(segment.icon!, size: 18, color: value),
              ),
              const SizedBox(width: AppSpacing.sm),
            ],
            Text(segment.label),
          ],
        ),
      ),
    );
  }
}
