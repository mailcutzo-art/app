import 'package:flutter/material.dart';

import '../icons/huge_icon.dart';
import '../icons/icon_shapes.dart';
import '../theme/app_theme.dart';
import '../tokens/app_colors.dart';
import '../tokens/app_dimens.dart';

enum Presence { online, playing, offline }

/// Preset-avatar model: a pastel circle with a symbol (no photo uploads in v1).
@immutable
class AvatarData {
  const AvatarData({required this.tone, this.symbol, this.initials});

  final PastelTone tone;
  final HugeIconData? symbol;
  final String? initials;
}

/// Circular avatar with an optional ring and presence dot.
class AppAvatar extends StatelessWidget {
  const AppAvatar({
    super.key,
    required this.data,
    this.size = AppSizes.avatar,
    this.ring = false,
    this.presence,
    this.semanticLabel,
  });

  final AvatarData data;
  final double size;
  final bool ring;
  final Presence? presence;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final pair = colors.pastel(data.tone);
    final Widget content;
    if (data.symbol != null) {
      content = HugeIcon(data.symbol!, size: size * 0.5, color: pair.onContainer);
    } else {
      content = Text(
        (data.initials ?? '?').characters.take(2).toString().toUpperCase(),
        style: context.text.labelLarge.copyWith(
          color: pair.onContainer,
          fontSize: size * 0.36,
          height: 1,
        ),
      );
    }

    final dotSize = (size * 0.28).clamp(8.0, 14.0);
    return Semantics(
      label: semanticLabel,
      image: semanticLabel != null,
      child: SizedBox.square(
        dimension: size,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: pair.container,
                  shape: BoxShape.circle,
                  border: ring ? Border.all(color: colors.accent, width: 2.5) : null,
                ),
                child: Center(child: content),
              ),
            ),
            if (presence != null && presence != Presence.offline)
              Positioned(
                right: 0,
                bottom: 0,
                child: Container(
                  width: dotSize,
                  height: dotSize,
                  decoration: BoxDecoration(
                    color: presence == Presence.online ? colors.success : colors.warning,
                    shape: BoxShape.circle,
                    border: Border.all(color: colors.surface, width: 2),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Overlapping avatars with an optional "+N" counter.
class AvatarStack extends StatelessWidget {
  const AvatarStack({
    super.key,
    required this.avatars,
    this.size = 32,
    this.max = 4,
    this.extraCount = 0,
  });

  final List<AvatarData> avatars;
  final double size;
  final int max;

  /// Additional people not represented by [avatars].
  final int extraCount;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final shown = avatars.take(max).toList();
    final hidden = extraCount + (avatars.length - shown.length);
    final step = size * 0.68;
    final count = shown.length + (hidden > 0 ? 1 : 0);
    return SizedBox(
      height: size,
      width: count == 0 ? 0 : step * (count - 1) + size,
      child: Stack(
        children: [
          for (var i = 0; i < shown.length; i++)
            Positioned(
              left: step * i,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: colors.surface, width: 2),
                ),
                child: AppAvatar(data: shown[i], size: size - 4),
              ),
            ),
          if (hidden > 0)
            Positioned(
              left: step * shown.length,
              child: Container(
                width: size,
                height: size,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: colors.inverse,
                  shape: BoxShape.circle,
                  border: Border.all(color: colors.surface, width: 2),
                ),
                child: Text(
                  '+$hidden',
                  style: context.text.caption.copyWith(
                    color: colors.onInverse,
                    fontWeight: FontWeight.w700,
                    fontSize: size * 0.32,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
