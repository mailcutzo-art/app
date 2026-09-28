import 'dart:async';

import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../../app/shell.dart' show Gutter;
import '../../core/network/app_failure.dart';
import '../learn/widgets/learn_widgets.dart' show RowsSkeleton, failureMessage;
import 'data/missions_models.dart';
import 'missions_providers.dart';
import 'widgets/missions_widgets.dart';

/// Today's missions (`/missions`): three goals with progress, one free swap,
/// the all-3 bonus and the streak.
class MissionsScreen extends ConsumerStatefulWidget {
  const MissionsScreen({super.key});

  @override
  ConsumerState<MissionsScreen> createState() => _MissionsScreenState();
}

class _MissionsScreenState extends ConsumerState<MissionsScreen> {
  /// The mission being swapped, while the request runs.
  String? _swapping;

  Future<void> _swap(Mission mission) async {
    final confirmed = await showAppSheet<bool>(
      context,
      builder: (context) => SheetScaffold(
        title: 'Swap this mission?',
        subtitle:
            '"${mission.title}" will be replaced with a different mission. '
            'You get one free swap a day.',
        footer: Column(
          children: [
            AppButton(label: 'Swap', onPressed: () => Navigator.pop(context, true)),
            const SizedBox(height: AppSpacing.sm),
            AppButton(
              label: 'Keep it',
              variant: AppButtonVariant.ghost,
              onPressed: () => Navigator.pop(context, false),
            ),
          ],
        ),
        child: const SizedBox.shrink(),
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _swapping = mission.id);
    try {
      await ref.read(missionsProvider.notifier).swap(mission.id);
      if (mounted) showAppToast(context, 'Mission swapped', icon: AppIcons.refresh);
    } on AppFailure catch (failure) {
      if (mounted) showAppToast(context, failure.message, icon: AppIcons.alert);
    } finally {
      if (mounted) setState(() => _swapping = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final missions = ref.watch(missionsProvider);

    final List<Widget> content = switch (missions) {
      AsyncValue(:final value?) => _content(context, value),
      AsyncValue(:final error?) => [
        Gutter(
          child: SurfaceCard(
            child: ErrorState(
              title: 'Couldn\'t load missions',
              message: failureMessage(error),
              retrying: missions.isLoading,
              onRetry: () => ref.invalidate(missionsProvider),
            ),
          ),
        ),
      ],
      _ => const [Gutter(child: RowsSkeleton())],
    };

    return Scaffold(
      appBar: AppTopBar(onBack: () => context.canPop() ? context.pop() : context.go(Routes.home)),
      body: RefreshIndicator(
        color: context.colors.ink,
        backgroundColor: context.colors.surface,
        onRefresh: () async {
          ref.invalidate(missionsProvider);
          try {
            await ref.read(missionsProvider.future);
          } on Object {
            // The screen shows the error.
          }
        },
        child: ListView(
          padding: const EdgeInsets.only(bottom: AppSpacing.huge),
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            LargeTitle(
              title: 'Today\'s missions',
              subtitle: switch (missions.value) {
                final day? when day.items.isNotEmpty =>
                  '${day.doneCount} of ${day.items.length} done · New ones at midnight',
                _ => 'New ones at midnight',
              },
              trailing: switch (missions.value) {
                final day? => StreakChip(streak: day.streak),
                _ => null,
              },
            ),
            const SizedBox(height: AppSpacing.xl),
            ...content,
          ],
        ),
      ),
    );
  }

  List<Widget> _content(BuildContext context, MissionsDay day) {
    final recommended = day.recommended;
    final canSwap = day.swapsLeft > 0 && _swapping == null;
    return [
      if (day.items.isEmpty)
        const Gutter(
          child: SurfaceCard(
            child: EmptyState(
              icon: AppIcons.target,
              tone: PastelTone.lemon,
              title: 'No missions right now',
              message: 'New missions arrive at midnight.',
            ),
          ),
        ),
      for (final mission in day.items)
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.gutter,
            0,
            AppSpacing.gutter,
            AppSpacing.md,
          ),
          child: Stack(
            children: [
              MissionTile(
                mission: mission,
                onTap: mission.action == null ? null : () => openAction(context, mission.action!),
                onSwap: canSwap ? () => unawaited(_swap(mission)) : null,
              ),
              if (_swapping == mission.id)
                const Positioned.fill(
                  child: Center(
                    child: SizedBox.square(
                      dimension: 24,
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    ),
                  ),
                ),
            ],
          ),
        ),
      if (day.items.isNotEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.gutter,
            0,
            AppSpacing.gutter,
            AppSpacing.md,
          ),
          child: Text(
            day.swapsLeft > 0
                ? 'Not feeling one? Tap ↻ to swap it. One free swap a day.'
                : 'You\'ve used today\'s free swap.',
            style: context.text.caption,
          ),
        ),
      if (day.items.isNotEmpty) Gutter(child: MissionBonusCard(missions: day)),
      if (recommended != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.gutter,
            AppSpacing.xl,
            AppSpacing.gutter,
            0,
          ),
          child: AppButton(
            label: 'Start recommended mission',
            leadingIcon: AppIcons.rocket,
            onPressed: () => openAction(context, recommended.action!),
          ),
        ),
      const SectionHeader(title: 'Keep going'),
      Padding(
        padding: const EdgeInsets.fromLTRB(AppSpacing.gutter, 0, AppSpacing.gutter, AppSpacing.sm),
        child: ListRowCard(
          title: switch (day.streak.days) {
            0 => 'Start a streak',
            1 => '1-day streak',
            final days => '$days-day streak',
          },
          subtitle: switch ((day.streak.todayDone, day.streak.freezes)) {
            (true, _) => 'Today counts. See your calendar',
            (false, 0) => 'Answer 10 questions or finish a battle today',
            (false, final n) =>
              'Answer 10 questions or finish a battle · $n ${n == 1 ? 'freeze' : 'freezes'}',
          },
          leading: _RoundIcon(icon: AppIcons.fire, pair: context.colors.peach),
          trailing: HugeIcon(AppIcons.chevronRight, size: 20, color: context.colors.inkMuted),
          onTap: () => unawaited(context.push(Routes.streak)),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(AppSpacing.gutter, 0, AppSpacing.gutter, AppSpacing.sm),
        child: ListRowCard(
          title: 'Achievements',
          subtitle: 'Badges and coins for milestones',
          leading: _RoundIcon(icon: AppIcons.medal, pair: context.colors.lavender),
          trailing: HugeIcon(AppIcons.chevronRight, size: 20, color: context.colors.inkMuted),
          onTap: () => unawaited(context.push(Routes.achievements)),
        ),
      ),
    ];
  }
}

class _RoundIcon extends StatelessWidget {
  const _RoundIcon({required this.icon, required this.pair});

  final HugeIconData icon;
  final PastelPair pair;

  @override
  Widget build(BuildContext context) => Container(
    width: 40,
    height: 40,
    decoration: BoxDecoration(color: pair.container, shape: BoxShape.circle),
    alignment: Alignment.center,
    child: HugeIcon(icon, size: 20, color: pair.onContainer),
  );
}
