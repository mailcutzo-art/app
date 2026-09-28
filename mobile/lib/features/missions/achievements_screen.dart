import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../../app/shell.dart' show Gutter;
import '../learn/widgets/learn_widgets.dart' show TwoColumnGrid, failureMessage;
import 'data/missions_models.dart';
import 'missions_providers.dart';
import 'widgets/missions_widgets.dart';

/// Achievements (`/achievements`): earned ones first, then the rest with
/// progress.
class AchievementsScreen extends ConsumerWidget {
  const AchievementsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final achievements = ref.watch(achievementsProvider);

    final List<Widget> content = switch (achievements) {
      AsyncValue(:final value?) when value.items.isEmpty => const [
        Gutter(
          child: SurfaceCard(
            child: EmptyState(
              icon: AppIcons.medal,
              tone: PastelTone.lavender,
              title: 'No achievements yet',
              message: 'Badges for milestones will show up here.',
            ),
          ),
        ),
      ],
      AsyncValue(:final value?) => [
        if (value.earned.isNotEmpty) ...[
          const SectionHeader(title: 'Earned'),
          Gutter(
            child: TwoColumnGrid(
              children: [for (final item in value.earned) AchievementTile(achievement: item)],
            ),
          ),
        ],
        if (value.locked.isNotEmpty) ...[
          const SectionHeader(title: 'In progress'),
          Gutter(
            child: TwoColumnGrid(
              children: [for (final item in value.locked) AchievementTile(achievement: item)],
            ),
          ),
        ],
      ],
      AsyncValue(:final error?) => [
        Gutter(
          child: SurfaceCard(
            child: ErrorState(
              title: 'Couldn\'t load achievements',
              message: failureMessage(error),
              retrying: achievements.isLoading,
              onRetry: () => ref.invalidate(achievementsProvider),
            ),
          ),
        ),
      ],
      _ => [
        Gutter(
          child: Shimmer(
            child: TwoColumnGrid(
              children: [
                for (var i = 0; i < 6; i++) const SkeletonBox(height: 170, radius: AppRadii.xl),
              ],
            ),
          ),
        ),
      ],
    };

    final value = achievements.value;
    return Scaffold(
      appBar: AppTopBar(onBack: () => context.canPop() ? context.pop() : context.go(Routes.home)),
      body: RefreshIndicator(
        color: context.colors.ink,
        backgroundColor: context.colors.surface,
        onRefresh: () async {
          ref.invalidate(achievementsProvider);
          try {
            await ref.read(achievementsProvider.future);
          } on Object {
            // The screen shows the error.
          }
        },
        child: ListView(
          padding: const EdgeInsets.only(bottom: AppSpacing.huge),
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            LargeTitle(
              title: 'Achievements',
              subtitle: value == null || value.items.isEmpty
                  ? 'Milestones that earn badges and coins'
                  : '${value.earned.length} of ${value.items.length} earned',
            ),
            const SizedBox(height: AppSpacing.sm),
            ...content,
          ],
        ),
      ),
    );
  }
}

/// One achievement: its badge, what it takes, and progress or when it was earned.
class AchievementTile extends StatelessWidget {
  const AchievementTile({super.key, required this.achievement});

  final Achievement achievement;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.text;
    final earned = achievement.earned;
    final pair = earned ? colors.lavender : null;
    return Semantics(
      label: earned ? '${achievement.title}, earned' : '${achievement.title}, not earned yet',
      child: SurfaceCard(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: pair?.container ?? colors.surfaceSunken,
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: HugeIcon(
                    earned ? achievementIcon(achievement.icon) : AppIcons.lock,
                    size: 22,
                    color: pair?.onContainer ?? colors.inkSubtle,
                  ),
                ),
                const Spacer(),
                if (achievement.coins > 0)
                  CoinAmount(
                    amount: achievement.coins,
                    signed: true,
                    iconSize: 14,
                    style: text.labelMedium,
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              achievement.title,
              style: text.titleMedium,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 2),
            Text(
              achievement.description,
              style: text.caption,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: AppSpacing.md),
            if (earned)
              Text(
                'Earned ${_date(achievement.earnedAt!)}',
                style: text.labelMedium.copyWith(color: colors.success),
              )
            else ...[
              AppProgressBar(
                value: achievement.fraction,
                height: 6,
                semanticLabel: '${achievement.progress} of ${achievement.target}',
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                '${formatCount(achievement.progress)} / ${formatCount(achievement.target)}',
                style: text.caption,
              ),
            ],
          ],
        ),
      ),
    );
  }

  static String _date(DateTime at) {
    // Earned times are shown on the IST calendar.
    final ist = at.toUtc().add(const Duration(hours: 5, minutes: 30));
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${ist.day} ${months[ist.month - 1]} ${ist.year}';
  }
}
