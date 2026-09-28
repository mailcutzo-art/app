import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';

import '../../core/auth/user.dart';

/// The preset avatars: a big preview, a row of tones and a grid of symbols. Used by onboarding
/// and Edit profile.
class AvatarPicker extends StatelessWidget {
  const AvatarPicker({super.key, required this.value, required this.onChanged});

  final Avatar value;
  final ValueChanged<Avatar> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Column(
      children: [
        AppAvatar(data: value.toData(), size: 112, ring: true),
        const SizedBox(height: AppSpacing.xl),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final tone in Avatar.tones)
                Padding(
                  padding: const EdgeInsets.only(right: AppSpacing.sm),
                  child: Pressable(
                    onPressed: () => onChanged(Avatar(tone: tone, symbol: value.symbol)),
                    semanticLabel: '$tone color',
                    selected: value.tone == tone,
                    child: AnimatedContainer(
                      duration: AppMotion.fast,
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: colors.pastel(PastelTone.values.byName(tone)).container,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: value.tone == tone ? colors.ink : colors.outline,
                          width: value.tone == tone ? 2.5 : 1,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        GridView.count(
          crossAxisCount: 6,
          shrinkWrap: true,
          padding: EdgeInsets.zero,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: AppSpacing.sm,
          crossAxisSpacing: AppSpacing.sm,
          children: [
            for (final MapEntry(key: symbol, value: icon) in Avatar.symbols.entries)
              Pressable(
                onPressed: () => onChanged(Avatar(tone: value.tone, symbol: symbol)),
                semanticLabel: symbol,
                selected: value.symbol == symbol,
                child: AnimatedContainer(
                  duration: AppMotion.fast,
                  decoration: BoxDecoration(
                    color: value.symbol == symbol ? colors.inverse : colors.surface,
                    shape: BoxShape.circle,
                    border: Border.all(color: colors.outline),
                  ),
                  alignment: Alignment.center,
                  child: HugeIcon(
                    icon,
                    size: 22,
                    color: value.symbol == symbol ? colors.onInverse : colors.ink,
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}
