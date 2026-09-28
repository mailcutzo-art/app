import 'dart:async';

import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../../app/shell.dart' show Gutter;
import '../../core/network/app_failure.dart';
import '../../core/utils/ids.dart';
import '../learn/widgets/learn_widgets.dart' show failureMessage;
import 'data/missions_models.dart';
import 'data/missions_repository.dart';
import 'missions_providers.dart';

/// The streak (`/streak`): the last 30 days, current and best, and freezes.
class StreakScreen extends ConsumerStatefulWidget {
  const StreakScreen({super.key});

  @override
  ConsumerState<StreakScreen> createState() => _StreakScreenState();
}

class _StreakScreenState extends ConsumerState<StreakScreen> {
  bool _buying = false;

  /// Kept across retries of the same purchase, so a lost response never
  /// charges twice.
  String? _freezeKey;

  Future<void> _buyFreeze(StreakCalendar streak) async {
    final price = streak.freezePrice;
    final short = streak.coins != null && streak.coins! < price;
    if (short) {
      await _showInsufficient(price);
      return;
    }
    final confirmed = await showAppSheet<bool>(
      context,
      builder: (context) => SheetScaffold(
        title: 'Buy a streak freeze?',
        subtitle:
            'A freeze is used automatically on a day you miss, so your streak keeps going. '
            'You can hold ${streak.maxFreezes}.',
        footer: Column(
          children: [
            AppButton(
              label: 'Buy for $price coins',
              leadingIcon: AppIcons.coins,
              onPressed: () => Navigator.pop(context, true),
            ),
            const SizedBox(height: AppSpacing.sm),
            AppButton(
              label: 'Cancel',
              variant: AppButtonVariant.ghost,
              onPressed: () => Navigator.pop(context, false),
            ),
          ],
        ),
        child: streak.coins == null
            ? const SizedBox.shrink()
            : Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
                child: Row(
                  children: [
                    Text('Your balance', style: context.text.bodySmall),
                    const SizedBox(width: AppSpacing.sm),
                    CoinAmount(amount: streak.coins!),
                  ],
                ),
              ),
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _buying = true);
    final key = _freezeKey ??= randomHexId();
    AppFailure? failed;
    FreezePurchase? bought;
    try {
      bought = await ref.read(missionsRepositoryProvider).buyFreeze(idempotencyKey: key);
      _freezeKey = null;
      ref
        ..invalidate(streakProvider)
        ..invalidate(missionsProvider);
    } on AppFailure catch (failure) {
      // Only a failure that may not have reached the server keeps the key.
      if (!failure.isRetryable) _freezeKey = null;
      failed = failure;
      if (failure.code == 'INSUFFICIENT_COINS' || failure.code == 'LIMIT_REACHED') {
        ref.invalidate(streakProvider);
      }
    }
    if (!mounted) return;
    setState(() => _buying = false);
    if (bought != null) {
      showAppToast(context, 'Freeze added. You hold ${bought.freezes}.', icon: AppIcons.shield);
    } else if (failed?.code == 'INSUFFICIENT_COINS') {
      await _showInsufficient(price);
    } else if (failed != null) {
      showAppToast(context, failed.message, icon: AppIcons.alert);
    }
  }

  Future<void> _showInsufficient(int price) => showAppSheet<void>(
    context,
    builder: (context) => SheetScaffold(
      title: 'Not enough coins',
      subtitle:
          'A freeze costs $price coins. Finish today\'s missions or win battles to earn more.',
      footer: Column(
        children: [
          AppButton(
            label: 'Play a battle',
            leadingIcon: AppIcons.battle,
            onPressed: () {
              Navigator.pop(context);
              this.context.go(Routes.battle);
            },
          ),
          const SizedBox(height: AppSpacing.sm),
          AppButton(
            label: 'OK',
            variant: AppButtonVariant.ghost,
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
      child: const SizedBox.shrink(),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final streak = ref.watch(streakProvider);

    final List<Widget> content = switch (streak) {
      AsyncValue(:final value?) => _content(context, value),
      AsyncValue(:final error?) => [
        Gutter(
          child: SurfaceCard(
            child: ErrorState(
              title: 'Couldn\'t load your streak',
              message: failureMessage(error),
              retrying: streak.isLoading,
              onRetry: () => ref.invalidate(streakProvider),
            ),
          ),
        ),
      ],
      _ => const [
        Gutter(
          child: Shimmer(
            child: Column(
              children: [
                SkeletonBox(height: 120, radius: AppRadii.xl),
                SizedBox(height: AppSpacing.md),
                SkeletonBox(height: 300, radius: AppRadii.xl),
                SizedBox(height: AppSpacing.md),
                SkeletonBox(height: 120, radius: AppRadii.xl),
              ],
            ),
          ),
        ),
      ],
    };

    return Scaffold(
      appBar: AppTopBar(onBack: () => context.canPop() ? context.pop() : context.go(Routes.home)),
      body: RefreshIndicator(
        color: context.colors.ink,
        backgroundColor: context.colors.surface,
        onRefresh: () async {
          ref.invalidate(streakProvider);
          try {
            await ref.read(streakProvider.future);
          } on Object {
            // The screen shows the error.
          }
        },
        child: ListView(
          padding: const EdgeInsets.only(bottom: AppSpacing.huge),
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            const LargeTitle(
              title: 'Your streak',
              subtitle: 'A day counts with 10 answers or 1 finished battle',
            ),
            const SizedBox(height: AppSpacing.xl),
            ...content,
          ],
        ),
      ),
    );
  }

  List<Widget> _content(BuildContext context, StreakCalendar streak) {
    final colors = context.colors;
    final text = context.text;
    return [
      Gutter(
        child: SurfaceCard(
          color: colors.peach.container,
          bordered: false,
          child: Row(
            children: [
              HugeIcon(AppIcons.fire, size: 40, color: colors.peach.onContainer),
              const SizedBox(width: AppSpacing.lg),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      streak.days == 1 ? '1 day' : '${streak.days} days',
                      style: text.numericLarge.copyWith(color: colors.peach.onContainer),
                    ),
                    Text(
                      streak.todayDone
                          ? 'Today counts. See you tomorrow!'
                          : 'Keep it going: answer 10 questions or finish a battle today.',
                      style: text.bodySmall.copyWith(color: colors.peach.onContainer),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Column(
                children: [
                  Text('Best', style: text.caption.copyWith(color: colors.peach.onContainer)),
                  Text(
                    '${streak.best}',
                    style: text.numericMedium.copyWith(color: colors.peach.onContainer),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      SectionHeader(
        title: 'Last ${streak.calendar.length} days',
        subtitle: streak.freezesUsed == 0
            ? null
            : '${streak.freezesUsed} ${streak.freezesUsed == 1 ? 'freeze' : 'freezes'} used',
      ),
      Gutter(
        child: SurfaceCard(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: streak.calendar.isEmpty
              ? Text('Your days will show here once you start.', style: text.bodySmall)
              : StreakCalendarGrid(days: streak.calendar),
        ),
      ),
      const SectionHeader(title: 'Streak freezes'),
      Gutter(
        child: SurfaceCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  for (var i = 0; i < streak.maxFreezes; i++) ...[
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: i < streak.freezes ? colors.sky.container : colors.surfaceSunken,
                        shape: BoxShape.circle,
                      ),
                      alignment: Alignment.center,
                      child: HugeIcon(
                        AppIcons.shield,
                        size: 22,
                        color: i < streak.freezes ? colors.sky.onContainer : colors.inkSubtle,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                  ],
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(
                      '${streak.freezes} of ${streak.maxFreezes} held',
                      style: text.titleMedium,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              Text(
                'A freeze saves your streak on a day you miss. It\'s used automatically.',
                style: text.bodySmall,
              ),
              const SizedBox(height: AppSpacing.lg),
              AppButton(
                label: streak.canHoldMore
                    ? 'Buy freeze · ${streak.freezePrice} coins'
                    : 'You hold the most freezes',
                leadingIcon: streak.canHoldMore ? AppIcons.coins : null,
                loading: _buying,
                variant: AppButtonVariant.secondary,
                onPressed: streak.canHoldMore && !_buying
                    ? () => unawaited(_buyFreeze(streak))
                    : null,
              ),
            ],
          ),
        ),
      ),
      const SectionHeader(title: 'Streak rewards'),
      Gutter(
        child: Row(
          children: [
            Expanded(child: _Reward(days: 7, coins: 30, reached: streak.best >= 7)),
            const SizedBox(width: AppSpacing.md),
            Expanded(child: _Reward(days: 30, coins: 100, reached: streak.best >= 30)),
          ],
        ),
      ),
    ];
  }
}

class _Reward extends StatelessWidget {
  const _Reward({required this.days, required this.coins, required this.reached});

  final int days;
  final int coins;
  final bool reached;

  @override
  Widget build(BuildContext context) {
    final text = context.text;
    return SurfaceCard(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Day $days', style: text.titleMedium),
          const SizedBox(height: AppSpacing.xs),
          CoinAmount(amount: coins, signed: true),
          if (reached) ...[
            const SizedBox(height: AppSpacing.xs),
            Text('Reached', style: text.caption),
          ],
        ],
      ),
    );
  }
}

/// The streak calendar: one cell per day in weeks from Monday, active days
/// filled, frozen days marked with a shield, today outlined.
class StreakCalendarGrid extends StatelessWidget {
  const StreakCalendarGrid({super.key, required this.days});

  /// Oldest first; the last is today.
  final List<StreakDay> days;

  static const _weekdays = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final text = context.text;
    final lead = days.first.day.weekday - DateTime.monday;
    final cells = <Widget>[
      for (var i = 0; i < lead; i++) const SizedBox.shrink(),
      for (final (i, day) in days.indexed) _cell(context, day, today: i == days.length - 1),
    ];
    return Column(
      children: [
        Row(
          children: [
            for (final label in _weekdays)
              Expanded(
                child: Center(
                  child: Text(label, style: text.caption.copyWith(color: colors.inkSubtle)),
                ),
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        for (var row = 0; row * 7 < cells.length; row++)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.xs),
            child: Row(
              children: [
                for (var col = 0; col < 7; col++)
                  Expanded(
                    child: row * 7 + col < cells.length
                        ? cells[row * 7 + col]
                        : const SizedBox.shrink(),
                  ),
              ],
            ),
          ),
        const SizedBox(height: AppSpacing.md),
        Wrap(
          spacing: AppSpacing.lg,
          runSpacing: AppSpacing.xs,
          children: [
            _Legend(color: colors.peach.container, label: 'Active'),
            _Legend(color: colors.sky.container, label: 'Frozen'),
            _Legend(color: colors.surfaceSunken, label: 'Missed'),
          ],
        ),
      ],
    );
  }

  Widget _cell(BuildContext context, StreakDay day, {required bool today}) {
    final colors = context.colors;
    final text = context.text;
    final (fill, fg) = switch (day.state) {
      StreakDayState.active => (colors.peach.container, colors.peach.onContainer),
      StreakDayState.frozen => (colors.sky.container, colors.sky.onContainer),
      StreakDayState.missed => (colors.surfaceSunken, colors.inkSubtle),
    };
    final label = switch (day.state) {
      StreakDayState.active => 'active',
      StreakDayState.frozen => 'saved by a freeze',
      StreakDayState.missed => today ? 'not done yet' : 'missed',
    };
    return Semantics(
      container: true,
      label: '${_month(day.day.month)} ${day.day.day}${today ? ', today' : ''}: $label',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.all(2),
        child: AspectRatio(
          aspectRatio: 1,
          child: Container(
            decoration: BoxDecoration(
              color: fill,
              borderRadius: BorderRadius.circular(AppRadii.sm),
              border: today ? Border.all(color: colors.ink, width: 1.5) : null,
            ),
            alignment: Alignment.center,
            child: day.state == StreakDayState.frozen
                ? HugeIcon(AppIcons.shield, size: 16, color: fg)
                : Text('${day.day.day}', style: text.labelMedium.copyWith(color: fg)),
          ),
        ),
      ),
    );
  }

  static String _month(int month) => const [
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
  ][month - 1];
}

class _Legend extends StatelessWidget {
  const _Legend({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 12,
        height: 12,
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3)),
      ),
      const SizedBox(width: AppSpacing.xs),
      Text(label, style: context.text.caption),
    ],
  );
}
