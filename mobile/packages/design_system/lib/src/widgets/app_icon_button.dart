import 'package:flutter/material.dart';

import '../icons/huge_icon.dart';
import '../icons/icon_motion.dart';
import '../icons/icon_shapes.dart';
import '../theme/app_theme.dart';
import '../tokens/app_colors.dart';
import '../tokens/app_dimens.dart';
import '../tokens/app_motion.dart';
import 'pressable.dart';

enum AppIconButtonVariant { surface, tonal, ink, ghost }

/// Circular icon button (52dp by default) with an optional badge and an
/// optional icon animation that plays on tap and whenever [motionTrigger]
/// changes (e.g. the unread count for a bell).
class AppIconButton extends StatefulWidget {
  const AppIconButton({
    super.key,
    required this.icon,
    required this.onPressed,
    required this.semanticLabel,
    this.variant = AppIconButtonVariant.surface,
    this.size = AppSizes.iconButton,
    this.badgeCount,
    this.showDot = false,
    this.motion,
    this.motionTrigger,
    this.iconColor,
  });

  final HugeIconData icon;
  final VoidCallback? onPressed;
  final String semanticLabel;
  final AppIconButtonVariant variant;
  final double size;
  final int? badgeCount;
  final bool showDot;
  final IconMotion? motion;
  final Object? motionTrigger;
  final Color? iconColor;

  @override
  State<AppIconButton> createState() => _AppIconButtonState();
}

class _AppIconButtonState extends State<AppIconButton> {
  final _iconKey = GlobalKey<AnimatedHugeIconState>();

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final (bg, fg, border) = switch (widget.variant) {
      AppIconButtonVariant.surface => (colors.surface, colors.ink, colors.outline),
      AppIconButtonVariant.tonal => (colors.surfaceMuted, colors.ink, null),
      AppIconButtonVariant.ink => (colors.inverse, colors.onInverse, null),
      AppIconButtonVariant.ghost => (Colors.transparent, colors.ink, null),
    };
    final iconColor = widget.onPressed == null ? colors.inkSubtle : (widget.iconColor ?? fg);
    final iconSize = widget.size >= AppSizes.iconButton ? AppSizes.icon : AppSizes.iconSmall;

    final icon = widget.motion == null
        ? HugeIcon(widget.icon, size: iconSize, color: iconColor)
        : AnimatedHugeIcon(
            widget.icon,
            key: _iconKey,
            motion: widget.motion!,
            trigger: widget.motionTrigger,
            size: iconSize,
            color: iconColor,
          );

    final count = widget.badgeCount ?? 0;
    final label = count > 0 ? '${widget.semanticLabel}, $count new' : widget.semanticLabel;

    return Pressable(
      onPressed: widget.onPressed == null
          ? null
          : () {
              _iconKey.currentState?.play();
              widget.onPressed!();
            },
      semanticLabel: label,
      pressedScale: 0.92,
      child: SizedBox.square(
        dimension: widget.size,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              child: DecoratedBox(
                decoration: ShapeDecoration(
                  color: bg,
                  shape: CircleBorder(
                    side: border == null ? BorderSide.none : BorderSide(color: border),
                  ),
                ),
                child: Center(child: icon),
              ),
            ),
            if (count > 0 || widget.showDot)
              Positioned(
                top: count > 0 ? -2 : 10,
                right: count > 0 ? -2 : 12,
                child: _Badge(count: count, colors: colors),
              ),
          ],
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.count, required this.colors});

  final int count;
  final AppColors colors;

  @override
  Widget build(BuildContext context) {
    final border = Border.all(color: colors.surface, width: 2);
    if (count <= 0) {
      return AnimatedContainer(
        duration: AppMotion.fast,
        width: 10,
        height: 10,
        decoration: BoxDecoration(color: colors.error, shape: BoxShape.circle, border: border),
      );
    }
    return Container(
      constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
      padding: const EdgeInsets.symmetric(horizontal: 5),
      decoration: BoxDecoration(
        color: colors.error,
        borderRadius: AppRadii.pillAll,
        border: border,
      ),
      alignment: Alignment.center,
      child: Text(
        count > 99 ? '99+' : '$count',
        style: context.text.caption.copyWith(
          color: const Color(0xFFFFFFFF),
          fontWeight: FontWeight.w700,
          height: 1.2,
        ),
      ),
    );
  }
}
