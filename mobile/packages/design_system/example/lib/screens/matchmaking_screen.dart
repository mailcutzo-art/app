import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';

import '../mock_data.dart';

class MatchmakingMockScreen extends StatelessWidget {
  const MatchmakingMockScreen({super.key, this.widened = true});

  final bool widened;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.text;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            AppTopBar(
              actions: [
                AppIconButton(
                  icon: AppIcons.close,
                  semanticLabel: 'Cancel search',
                  onPressed: () => Navigator.maybePop(context),
                ),
              ],
            ),
            const Spacer(),
            SearchingPulse(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  boxShadow: AppShadows.floating(colors),
                ),
                child: const AppAvatar(data: Mock.me, size: 96, ring: true),
              ),
            ),
            const SizedBox(height: AppSpacing.xxl),
            Text('Finding an opponent…', style: text.headlineMedium),
            const SizedBox(height: AppSpacing.xs),
            Text('0:18', style: text.numericLarge.copyWith(color: colors.inkMuted)),
            const SizedBox(height: AppSpacing.lg),
            const Wrap(
              spacing: AppSpacing.sm,
              children: [
                OverlineBadge(label: 'Rated', solid: true, icon: AppIcons.flash),
                OverlineBadge(label: 'Physics', tone: PastelTone.sky),
                OverlineBadge(label: 'Kinematics', tone: PastelTone.sky),
              ],
            ),
            const SizedBox(height: AppSpacing.lg),
            AnimatedOpacity(
              opacity: widened ? 1 : 0,
              duration: AppMotion.medium,
              child: InfoChip(
                icon: AppIcons.info,
                label: 'Searching all of Physics for a faster match',
                background: colors.lemon.container,
                foreground: colors.lemon.onContainer,
              ),
            ),
            const Spacer(),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.gutter,
                0,
                AppSpacing.gutter,
                AppSpacing.lg,
              ),
              child: AppButton(
                label: 'Cancel',
                variant: AppButtonVariant.secondary,
                onPressed: () => Navigator.maybePop(context),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
