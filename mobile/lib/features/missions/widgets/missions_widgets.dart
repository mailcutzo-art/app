import 'dart:async';

import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../app/router.dart';
import '../data/missions_models.dart';

/// Follows an [AppAction]: a tab is switched to, anything else opens on top.
void openAction(BuildContext context, AppAction action) {
  final location = action.location;
  final path = Uri.parse(location).path;
  if (Routes.tabs.contains(path)) {
    context.go(location);
  } else {
    unawaited(context.push(location));
  }
}

/// The streak flame and day count. Muted until today counts.
class StreakChip extends StatelessWidget {
  const StreakChip({super.key, required this.streak, this.onTap});

  final StreakSummary streak;

  /// Defaults to opening the streak calendar.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.text;
    final lit = streak.todayDone;
    final label = switch (streak.days) {
      0 => 'Start a streak',
      1 => '1 day',
      final days => '$days days',
    };
    return Pressable(
      onPressed: onTap ?? () => unawaited(context.push(Routes.streak)),
      semanticLabel: switch ((streak.days, lit)) {
        (0, _) => 'No streak yet',
        (final days, true) => '$days-day streak, today done',
        (final days, false) => '$days-day streak, today not done yet',
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: 6),
        decoration: BoxDecoration(
          color: lit ? colors.peach.container : colors.surface,
          borderRadius: AppRadii.pillAll,
          border: Border.all(color: lit ? colors.peach.container : colors.outline),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            HugeIcon(
              AppIcons.fire,
              size: 18,
              color: lit ? colors.peach.onContainer : colors.inkMuted,
            ),
            const SizedBox(width: AppSpacing.xs),
            Text(
              label,
              style: text.labelMedium.copyWith(color: lit ? colors.peach.onContainer : colors.ink),
            ),
          ],
        ),
      ),
    );
  }
}

/// One mission with its progress, XP and (optionally) a swap button.
class MissionTile extends StatelessWidget {
  const MissionTile({super.key, required this.mission, this.onTap, this.onSwap});

  final Mission mission;
  final VoidCallback? onTap;

  /// Shown as a Swap button when set (not for done missions).
  final VoidCallback? onSwap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.text;
    final done = mission.done;
    return SurfaceCard(
      onTap: done ? null : onTap,
      semanticLabel: mission.title,
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Row(
        children: [
          _MissionMark(done: done),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  mission.title,
                  style: text.titleMedium.copyWith(color: done ? colors.inkMuted : colors.ink),
                ),
                const SizedBox(height: AppSpacing.sm),
                AppProgressBar(
                  value: mission.fraction,
                  height: 6,
                  color: done ? colors.success : null,
                  semanticLabel: '${mission.progress} of ${mission.target}',
                ),
                const SizedBox(height: AppSpacing.xs),
                Row(
                  children: [
                    Text(
                      done ? 'Done' : '${mission.progress} / ${mission.target}',
                      style: text.caption,
                    ),
                    const Spacer(),
                    Text(
                      '+${mission.xp} XP',
                      style: text.labelMedium.copyWith(
                        color: done ? colors.success : colors.inkMuted,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (onSwap != null && !done) ...[
            const SizedBox(width: AppSpacing.sm),
            AppIconButton(
              icon: AppIcons.refresh,
              semanticLabel: 'Swap mission',
              size: AppSizes.iconButtonSmall,
              variant: AppIconButtonVariant.ghost,
              onPressed: onSwap,
            ),
          ],
        ],
      ),
    );
  }
}

class _MissionMark extends StatelessWidget {
  const _MissionMark({required this.done});

  final bool done;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: done ? colors.successContainer : colors.lemon.container,
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: HugeIcon(
        done ? AppIcons.check : AppIcons.target,
        size: 20,
        color: done ? colors.onSuccessContainer : colors.lemon.onContainer,
      ),
    );
  }
}

/// "Finish all 3: +100 XP and 25 coins", with a three-step bar.
class MissionBonusCard extends StatelessWidget {
  const MissionBonusCard({super.key, required this.missions});

  final MissionsDay missions;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.text;
    final bonus = missions.bonus;
    final done = bonus.done || missions.allDone;
    final pair = done ? colors.mint : colors.lemon;
    return SurfaceCard(
      color: pair.container,
      bordered: false,
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              HugeIcon(done ? AppIcons.party : AppIcons.award, size: 22, color: pair.onContainer),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  done ? 'Bonus earned' : 'Finish all ${missions.items.length}',
                  style: text.titleMedium.copyWith(color: pair.onContainer),
                ),
              ),
              Text('+${bonus.xp} XP', style: text.labelLarge.copyWith(color: pair.onContainer)),
              const SizedBox(width: AppSpacing.sm),
              CoinAmount(
                amount: bonus.coins,
                signed: true,
                style: text.labelLarge.copyWith(color: pair.onContainer),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          SegmentedProgress(
            total: missions.items.isEmpty ? 3 : missions.items.length,
            completed: missions.doneCount,
            color: pair.onContainer,
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            done
                ? 'Rewards are in your wallet. New missions tomorrow.'
                : 'Rewards are credited automatically.',
            style: text.caption.copyWith(color: pair.onContainer),
          ),
        ],
      ),
    );
  }
}

/// Today's missions in one card, for Home: the streak, each mission with
/// its progress and one tap to start, and the all-3 bonus.
class MissionsCard extends StatelessWidget {
  const MissionsCard({
    super.key,
    required this.missions,
    this.onMissionTap,
    this.onStreakTap,
    this.onOpen,
  });

  final MissionsDay missions;

  /// Defaults to following the mission's action.
  final ValueChanged<Mission>? onMissionTap;

  /// Defaults to opening the streak calendar.
  final VoidCallback? onStreakTap;

  /// Defaults to opening the Missions screen.
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.text;
    final bonus = missions.bonus;
    return SurfaceCard(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Pressable(
                  onPressed: onOpen ?? () => unawaited(context.push(Routes.missions)),
                  semanticLabel: 'Open missions',
                  child: Text(
                    '${missions.doneCount} of ${missions.items.length} done',
                    style: text.titleMedium,
                  ),
                ),
              ),
              StreakChip(streak: missions.streak, onTap: onStreakTap),
            ],
          ),
          if (missions.items.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.md),
              child: Text('New missions arrive at midnight.', style: text.bodySmall),
            ),
          for (final mission in missions.items)
            _CompactMission(
              mission: mission,
              onTap: mission.done
                  ? null
                  : switch ((onMissionTap, mission.action)) {
                      (final tap?, _) => () => tap(mission),
                      (null, final action?) => () => openAction(context, action),
                      _ => null,
                    },
            ),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              HugeIcon(
                missions.allDone || bonus.done ? AppIcons.party : AppIcons.award,
                size: 18,
                color: colors.inkMuted,
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  missions.allDone || bonus.done
                      ? 'All done: +${bonus.xp} XP and ${bonus.coins} coins earned'
                      : 'All ${missions.items.length}: +${bonus.xp} XP and ${bonus.coins} coins',
                  style: text.caption,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CompactMission extends StatelessWidget {
  const _CompactMission({required this.mission, this.onTap});

  final Mission mission;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.text;
    final done = mission.done;
    final row = Padding(
      padding: const EdgeInsets.only(top: AppSpacing.md),
      child: Row(
        children: [
          HugeIcon(
            done ? AppIcons.checkCircle : AppIcons.target,
            size: 22,
            color: done ? colors.success : colors.inkMuted,
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  mission.title,
                  style: text.labelLarge.copyWith(color: done ? colors.inkMuted : colors.ink),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: AppSpacing.xs),
                AppProgressBar(
                  value: mission.fraction,
                  height: 4,
                  color: done ? colors.success : null,
                  semanticLabel: '${mission.progress} of ${mission.target}',
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Text(
            done ? '+${mission.xp} XP' : '${mission.progress}/${mission.target}',
            style: text.labelMedium.copyWith(color: done ? colors.success : colors.inkMuted),
          ),
        ],
      ),
    );
    if (onTap == null) return row;
    return Pressable(onPressed: onTap, semanticLabel: mission.title, child: row);
  }
}

/// Icon for an achievement's `icon` name.
HugeIconData achievementIcon(String name) => switch (name) {
  'fire' || 'streak' => AppIcons.fire,
  'medal' => AppIcons.medal,
  'crown' => AppIcons.crown,
  'star' => AppIcons.star,
  'battle' => AppIcons.battle,
  'arena' || 'trophy' => AppIcons.arena,
  'quiz' => AppIcons.quiz,
  'target' => AppIcons.target,
  'flash' => AppIcons.flash,
  'shield' => AppIcons.shield,
  'brain' => AppIcons.brain,
  'rocket' => AppIcons.rocket,
  'learn' || 'book' => AppIcons.learn,
  'sparkles' => AppIcons.sparkles,
  'coins' => AppIcons.coins,
  'social' || 'friends' => AppIcons.social,
  'calendar' => AppIcons.calendar,
  _ => AppIcons.award,
};
