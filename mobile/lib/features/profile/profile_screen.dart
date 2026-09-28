import 'dart:async';

import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../../core/auth/session.dart';
import '../../core/network/paging.dart';
import '../common/paged_list.dart';
import '../learn/widgets/learn_widgets.dart' show CardSkeleton, RowsSkeleton, failureMessage;
import '../wallet/wallet_providers.dart';
import 'data/profile_models.dart';
import 'profile_providers.dart';
import 'widgets/history_rows.dart';
import 'widgets/stats_views.dart';

/// Your own profile (`/profile`): the header with level and XP, stats, the rating chart, recent
/// opponents, and the battle and practice history, plus the ways into Wallet and Settings.
/// Every section loads and fails on its own.
class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  Future<void> _refresh(BuildContext context, WidgetRef ref) async {
    final range = ref.read(ratingRangeProvider);
    ref
      ..invalidate(statsProvider)
      ..invalidate(recentOpponentsProvider)
      ..invalidate(walletProvider);
    final history = switch (ref.read(historyTabProvider)) {
      HistoryTab.battles => ref.read(matchHistoryProvider.notifier).refresh(),
      HistoryTab.practice => ref.read(practiceHistoryProvider.notifier).refresh(),
    };
    await Future.wait([
      settle(ref.read(statsProvider(StatsRange.days30).future)),
      settle(ref.read(statsProvider(range).future)),
      settle(ref.read(recentOpponentsProvider.future)),
      settle(history),
    ]);
    if (!context.mounted) return;
    final failed =
        ref.read(statsProvider(StatsRange.days30)).hasError ||
        ref.read(recentOpponentsProvider).hasError;
    if (failed) showAppToast(context, 'Couldn\'t refresh everything. Try again in a moment.');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider).value;
    if (session is! SignedIn) return const Scaffold();
    return Scaffold(
      appBar: AppTopBar(
        title: 'Profile',
        actions: [
          AppIconButton(
            icon: AppIcons.settings,
            semanticLabel: 'Settings',
            variant: AppIconButtonVariant.ghost,
            motion: IconMotions.settings,
            onPressed: () => unawaited(context.push(Routes.settings)),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => _refresh(context, ref),
        color: context.colors.ink,
        backgroundColor: context.colors.surface,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.gutter,
            AppSpacing.sm,
            AppSpacing.gutter,
            AppSpacing.xxxl,
          ),
          children: const [
            _Header(),
            SizedBox(height: AppSpacing.xl),
            _Links(),
            _Section(title: 'Stats', child: _Stats()),
            _Section(title: 'Rating', child: _RatingChartSection()),
            _Section(title: 'Recent opponents', child: _Opponents()),
            _Section(title: 'History', child: _History()),
          ],
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      SectionHeader(
        title: title,
        padding: const EdgeInsets.fromLTRB(0, AppSpacing.xxl, 0, AppSpacing.md),
      ),
      child,
    ],
  );
}

/// Avatar, name, @handle, goal, and the level with its XP bar (from the stats).
class _Header extends ConsumerWidget {
  const _Header();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(meProvider);
    final text = context.text;
    final stats = ref.watch(statsProvider(StatsRange.days30));
    return Column(
      children: [
        AppAvatar(data: me.avatar.toData(), size: 104, ring: true, semanticLabel: 'Your avatar'),
        const SizedBox(height: AppSpacing.lg),
        Text(me.displayName, style: text.headlineMedium, textAlign: TextAlign.center),
        if (me.handle != null) Text('@${me.handle}', style: text.bodyMedium),
        if (me.goal != null) ...[
          const SizedBox(height: AppSpacing.md),
          OverlineBadge(label: me.goal!.label, tone: PastelTone.mint),
        ],
        const SizedBox(height: AppSpacing.lg),
        switch (stats) {
          AsyncValue(:final value?) => switch (value.level) {
            final level? => LevelBar(level: level),
            null => const SizedBox.shrink(),
          },
          // The Stats section shows the error and its retry.
          AsyncValue(hasError: true) => const SizedBox.shrink(),
          _ => const CardSkeleton(height: 56),
        },
      ],
    );
  }
}

class _Links extends ConsumerWidget {
  const _Links();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final balance = ref.watch(walletProvider).value?.balance;
    final chevron = HugeIcon(AppIcons.chevronRight, size: 20, color: colors.inkMuted);
    return Column(
      children: [
        ListRowCard(
          title: 'Wallet',
          subtitle: balance == null ? 'Coins and their history' : '${formatCount(balance)} coins',
          leading: const RowIcon(icon: AppIcons.wallet, tone: PastelTone.lemon),
          trailing: chevron,
          onTap: () => unawaited(context.push(Routes.wallet)),
        ),
        const SizedBox(height: AppSpacing.sm),
        ListRowCard(
          title: 'Settings',
          subtitle: 'Profile, privacy, notifications and more',
          leading: const RowIcon(icon: AppIcons.settings, tone: PastelTone.lavender),
          trailing: chevron,
          onTap: () => unawaited(context.push(Routes.settings)),
        ),
      ],
    );
  }
}

class _Stats extends ConsumerWidget {
  const _Stats();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stats = ref.watch(statsProvider(StatsRange.days30));
    return switch (stats) {
      AsyncValue(:final value?) => StatsCard(stats: value),
      AsyncValue(:final error?) => ErrorState(
        compact: true,
        title: 'Couldn\'t load your stats',
        message: failureMessage(error),
        retrying: stats.isLoading,
        onRetry: () => ref.invalidate(statsProvider(StatsRange.days30)),
      ),
      _ => const CardSkeleton(height: 260),
    };
  }
}

class _RatingChartSection extends ConsumerWidget {
  const _RatingChartSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final range = ref.watch(ratingRangeProvider);
    final stats = ref.watch(statsProvider(range));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppSegmentedControl<StatsRange>(
          segments: [for (final r in StatsRange.values) AppSegment(value: r, label: r.label)],
          selected: range,
          onChanged: ref.read(ratingRangeProvider.notifier).select,
        ),
        const SizedBox(height: AppSpacing.md),
        switch (stats) {
          AsyncValue(:final value?) => RatingChartCard(
            key: ValueKey(range),
            history: value.ratingHistory,
          ),
          AsyncValue(:final error?) => ErrorState(
            compact: true,
            title: 'Couldn\'t load your rating history',
            message: failureMessage(error),
            retrying: stats.isLoading,
            onRetry: () => ref.invalidate(statsProvider(range)),
          ),
          _ => const CardSkeleton(height: 210),
        },
      ],
    );
  }
}

class _Opponents extends ConsumerWidget {
  const _Opponents();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final opponents = ref.watch(recentOpponentsProvider);
    return switch (opponents) {
      AsyncValue(:final value?) when value.isEmpty => const SurfaceCard(
        child: EmptyState(
          icon: AppIcons.social,

          title: 'No opponents yet',
          message: 'People you play in the last 30 days show up here.',
        ),
      ),
      AsyncValue(:final value?) => Column(
        children: [
          for (final opponent in value)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: OpponentRow(opponent: opponent),
            ),
        ],
      ),
      AsyncValue(:final error?) => ErrorState(
        compact: true,
        title: 'Couldn\'t load recent opponents',
        message: failureMessage(error),
        retrying: opponents.isLoading,
        onRetry: () => ref.invalidate(recentOpponentsProvider),
      ),
      _ => const RowsSkeleton(rows: 2),
    };
  }
}

class _History extends ConsumerWidget {
  const _History();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tab = ref.watch(historyTabProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppSegmentedControl<HistoryTab>(
          segments: const [
            AppSegment(value: HistoryTab.battles, label: 'Battles', icon: AppIcons.battle),
            AppSegment(value: HistoryTab.practice, label: 'Practice', icon: AppIcons.learn),
          ],
          selected: tab,
          onChanged: ref.read(historyTabProvider.notifier).select,
        ),
        const SizedBox(height: AppSpacing.md),
        switch (tab) {
          HistoryTab.battles => const _MatchHistory(),
          HistoryTab.practice => const _PracticeHistory(),
        },
      ],
    );
  }
}

class _MatchHistory extends ConsumerWidget {
  const _MatchHistory();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(matchHistoryProvider);
    return _PagedSection(
      value: history,
      emptyIcon: AppIcons.battle,
      emptyTitle: 'No battles yet',
      emptyMessage: 'Every game you play shows up here, with its review.',
      errorTitle: 'Couldn\'t load your battles',
      onRetry: () => ref.invalidate(matchHistoryProvider),
      onLoadMore: () => unawaited(ref.read(matchHistoryProvider.notifier).loadMore()),
      row: (match) => MatchHistoryRow(
        match: match,
        onTap: match.hasReview
            ? () => unawaited(context.push(Routes.battleReview(match.id)))
            : null,
      ),
    );
  }
}

class _PracticeHistory extends ConsumerWidget {
  const _PracticeHistory();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(practiceHistoryProvider);
    return _PagedSection(
      value: history,
      emptyIcon: AppIcons.learn,
      emptyTitle: 'No practice yet',
      emptyMessage: 'Sessions you practise show up here with their score.',
      errorTitle: 'Couldn\'t load your practice',
      onRetry: () => ref.invalidate(practiceHistoryProvider),
      onLoadMore: () => unawaited(ref.read(practiceHistoryProvider.notifier).loadMore()),
      row: (session) => PracticeHistoryRow(
        session: session,
        onTap: session.finished
            ? null
            : () => unawaited(context.push(Routes.practiceSession(session.sessionId))),
      ),
    );
  }
}

/// A history list inside the Profile: skeleton, rows with "Show more", empty or error.
class _PagedSection<T> extends StatelessWidget {
  const _PagedSection({
    required this.value,
    required this.emptyIcon,
    required this.emptyTitle,
    required this.emptyMessage,
    required this.errorTitle,
    required this.onRetry,
    required this.onLoadMore,
    required this.row,
  });

  final AsyncValue<Paged<T>> value;
  final HugeIconData emptyIcon;
  final String emptyTitle;
  final String emptyMessage;
  final String errorTitle;
  final VoidCallback onRetry;
  final VoidCallback onLoadMore;
  final Widget Function(T item) row;

  @override
  Widget build(BuildContext context) => switch (value) {
    AsyncValue(value: final paged?) when paged.items.isEmpty => SurfaceCard(
      child: EmptyState(
        icon: emptyIcon,
        tone: PastelTone.lavender,
        title: emptyTitle,
        message: emptyMessage,
      ),
    ),
    AsyncValue(value: final paged?) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final item in paged.items)
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
            child: row(item),
          ),
        PagedFooter(paged: paged, onLoadMore: onLoadMore, manual: true),
      ],
    ),
    AsyncValue(:final error?) => ErrorState(
      compact: true,
      title: errorTitle,
      message: failureMessage(error),
      retrying: value.isLoading,
      onRetry: onRetry,
    ),
    _ => const RowsSkeleton(rows: 3),
  };
}
