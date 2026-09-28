import 'dart:async';

import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../../app/shell.dart';
import '../../core/auth/session.dart';
import '../../core/network/connectivity.dart';
import '../../core/network/paging.dart';
import '../common/paged_list.dart';
import '../learn/widgets/learn_widgets.dart' show failureMessage;
import 'arena_providers.dart';
import 'data/tournament_models.dart';
import 'widgets/arena_widgets.dart';

/// The filters in `?filter=` (`/arena?filter=live,upcoming`), or null when none are valid.
List<ArenaFilter>? parseArenaFilters(String? value) {
  if (value == null) return null;
  final filters = [for (final part in value.split(',')) ?ArenaFilter.parse(part.trim())];
  return filters.isEmpty ? null : filters.toSet().toList();
}

/// The Arena tab: the viewer's tournaments pinned on top, then Open, Upcoming, Live or Finished
/// tournaments. `?filter=live,upcoming` ("Browse live contests") shows two lists at once.
class ArenaScreen extends ConsumerStatefulWidget {
  const ArenaScreen({super.key});

  @override
  ConsumerState<ArenaScreen> createState() => _ArenaScreenState();
}

class _ArenaScreenState extends ConsumerState<ArenaScreen> {
  List<ArenaFilter> _filters = const [ArenaFilter.open];
  String? _query;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // A link (or "Browse live contests") picks the filters; the control changes them after.
    final query = GoRouterState.of(context).uri.queryParameters['filter'];
    if (query != _query) {
      _query = query;
      final parsed = parseArenaFilters(query);
      if (parsed != null) _filters = parsed;
    }
  }

  void _select(ArenaFilter filter) => setState(() => _filters = [filter]);

  Future<void> _refresh() async {
    ref.invalidate(activeEntriesProvider);
    var failed = false;
    for (final filter in _filters) {
      try {
        await ref.read(arenaListProvider(filter).notifier).refresh();
      } on Object {
        failed = true;
      }
    }
    await settle(ref.read(activeEntriesProvider.future));
    if (failed && mounted) {
      showAppToast(context, 'Couldn\'t refresh the tournaments. Try again in a moment.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(meProvider);
    final online = ref.watch(isOnlineProvider);
    final single = _filters.length == 1 ? _filters.single : null;
    return LoadMoreListener(
      onNearEnd: () =>
          unawaited(ref.read(arenaListProvider(_filters.last).notifier).autoLoadMore()),
      child: TabPage(
        onRefresh: _refresh,
        children: [
          OfflineBanner(visible: !online, message: 'You\'re offline · showing what was loaded'),
          LargeTitle(
            title: 'Arena',
            subtitle: 'Swiss tournaments · live standings · coin prizes',
            trailing: Pressable(
              onPressed: () => context.push(Routes.profile),
              semanticLabel: 'Your profile',
              child: AppAvatar(data: me.avatar.toData(), ring: true),
            ),
          ),
          const _MyTournaments(),
          const SizedBox(height: AppSpacing.xl),
          Gutter(
            child: AppSegmentedControl<ArenaFilter?>(
              segments: [
                for (final filter in ArenaFilter.values)
                  AppSegment(value: filter, label: filter.label),
              ],
              selected: single,
              onChanged: (filter) => _select(filter!),
            ),
          ),
          if (single == null)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.gutter,
                AppSpacing.md,
                AppSpacing.gutter,
                0,
              ),
              child: Text(
                'Showing ${_filters.map((f) => f.label.toLowerCase()).join(' and ')} '
                'tournaments',
                style: context.text.caption,
              ),
            ),
          const SizedBox(height: AppSpacing.lg),
          for (final filter in _filters) ...[
            if (single == null) SectionHeader(title: _sectionTitle(filter)),
            Gutter(
              child: _FilterList(filter: filter, manual: filter != _filters.last),
            ),
          ],
        ],
      ),
    );
  }

  static String _sectionTitle(ArenaFilter filter) => switch (filter) {
    ArenaFilter.live => 'Live now',
    ArenaFilter.upcoming => 'Upcoming',
    ArenaFilter.open => 'Open for registration',
    ArenaFilter.finished => 'Finished',
  };
}

/// "My tournaments": what the viewer registered for and hasn't finished. Hidden when empty.
class _MyTournaments extends ConsumerWidget {
  const _MyTournaments();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entries = ref.watch(activeEntriesProvider);
    final content = switch (entries) {
      AsyncValue(:final value?) when value.isEmpty => null,
      AsyncValue(:final value?) => Column(
        children: [
          for (final t in value)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.md),
              child: ArenaTournamentCard(tournament: t, hero: false),
            ),
        ],
      ),
      AsyncValue(:final error?) => ErrorState(
        compact: true,
        title: 'Couldn\'t load your tournaments',
        message: failureMessage(error),
        retrying: entries.isLoading,
        onRetry: () => ref.invalidate(activeEntriesProvider),
      ),
      _ => const TournamentCardsSkeleton(cards: 1),
    };
    if (content == null) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader(title: 'My tournaments'),
        Gutter(child: content),
      ],
    );
  }
}

/// One filter's cards: skeleton, cards with paging, empty or error.
class _FilterList extends ConsumerWidget {
  const _FilterList({required this.filter, this.manual = false});

  final ArenaFilter filter;

  /// "Show more" instead of loading on scroll (a list above another).
  final bool manual;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(arenaListProvider(filter));
    return switch (list) {
      AsyncValue(:final value?) when value.items.isEmpty => SurfaceCard(
        child: EmptyState(
          icon: switch (filter) {
            ArenaFilter.finished => AppIcons.award,
            ArenaFilter.upcoming => AppIcons.calendar,
            _ => AppIcons.arena,
          },
          tone: PastelTone.lemon,
          title: switch (filter) {
            ArenaFilter.open => 'No open tournaments right now',
            ArenaFilter.upcoming => 'Nothing scheduled yet',
            ArenaFilter.live => 'No tournaments are live',
            ArenaFilter.finished => 'No finished tournaments yet',
          },
          message: switch (filter) {
            ArenaFilter.open => 'New ones open every day. Upcoming shows what\'s next.',
            ArenaFilter.upcoming => 'New tournaments are added a week ahead.',
            ArenaFilter.live => 'Upcoming tournaments start soon; you can watch any that\'s on.',
            ArenaFilter.finished => 'Results of past tournaments show up here.',
          },
        ),
      ),
      AsyncValue(:final value?) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final t in value.items)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.md),
              child: ArenaTournamentCard(tournament: t),
            ),
          PagedFooter(
            paged: value,
            manual: manual,
            onLoadMore: () => unawaited(ref.read(arenaListProvider(filter).notifier).loadMore()),
          ),
        ],
      ),
      AsyncValue(:final error?) => ErrorState(
        compact: true,
        title: 'Couldn\'t load tournaments',
        message: failureMessage(error),
        retrying: list.isLoading,
        onRetry: () => ref.invalidate(arenaListProvider(filter)),
      ),
      _ => const TournamentCardsSkeleton(),
    };
  }
}
