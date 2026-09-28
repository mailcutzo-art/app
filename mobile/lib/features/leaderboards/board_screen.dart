import 'dart:async';

import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/live/live_hub.dart' show liveClockProvider;
import '../../app/router.dart';
import '../../app/shell.dart' show Gutter;
import '../../core/auth/session.dart';
import '../learn/widgets/learn_widgets.dart' show failureMessage;
import 'data/leaderboard_models.dart';
import 'leaderboard_providers.dart';
import 'widgets/leaderboard_widgets.dart';

/// One board (`/leaderboards/:board`): the top 100, paged, with the viewer's
/// row pinned at the bottom and the players around them.
class BoardScreen extends ConsumerStatefulWidget {
  const BoardScreen({super.key, required this.board});

  final String board;

  @override
  ConsumerState<BoardScreen> createState() => _BoardScreenState();
}

class _BoardScreenState extends ConsumerState<BoardScreen> {
  final _aroundKey = GlobalKey();
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  BoardQuery get _query => (board: widget.board, scope: ref.read(examScopeProvider));

  bool _onScroll(ScrollNotification notification) {
    // After a failed page, only the retry button tries again.
    final failed = ref.read(boardProvider(_query)).value?.moreError != null;
    if (!failed && notification.metrics.extentAfter < 600) {
      unawaited(ref.read(boardProvider(_query).notifier).loadMore());
    }
    return false;
  }

  /// Scrolls to "Around you". The section closes the list, so while it
  /// isn't built yet the list heads for its end first.
  Future<void> _showAroundMe() async {
    for (var i = 0; i < 5 && _aroundKey.currentContext == null && _scroll.hasClients; i++) {
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
      await SchedulerBinding.instance.endOfFrame;
      if (!mounted) return;
    }
    final target = _aroundKey.currentContext;
    if (target == null || !target.mounted) return;
    await Scrollable.ensureVisible(
      target,
      duration: AppMotion.of(target, AppMotion.medium),
      curve: AppMotion.emphasized,
    );
  }

  void _openPlayer(BoardRow row) {
    final handle = row.user.handle;
    if (handle == null) return;
    unawaited(context.push('/u/${Uri.encodeComponent(handle)}'));
  }

  @override
  Widget build(BuildContext context) {
    final scope = ref.watch(examScopeProvider);
    final query = (board: widget.board, scope: scope);
    final board = ref.watch(boardProvider(query));
    final myId = ref.watch(currentUserIdProvider);
    final now = ref.watch(liveClockProvider)();
    final view = board.value;

    final List<Widget> content = switch (board) {
      AsyncValue(:final value?) => _rows(context, value, scope, myId),
      AsyncValue(:final error?) => [
        Gutter(
          child: SurfaceCard(
            child: ErrorState(
              title: 'Couldn\'t load this board',
              message: failureMessage(error),
              retrying: board.isLoading,
              onRetry: () => ref.invalidate(boardProvider(query)),
            ),
          ),
        ),
      ],
      _ => const [Gutter(child: BoardRowsSkeleton())],
    };

    final footer = view == null ? null : _footer(context, view);

    return Scaffold(
      appBar: AppTopBar(
        onBack: () => context.canPop() ? context.pop() : context.go(Routes.leaderboards),
      ),
      body: Column(
        children: [
          Expanded(
            child: NotificationListener<ScrollNotification>(
              onNotification: _onScroll,
              child: RefreshIndicator(
                color: context.colors.ink,
                backgroundColor: context.colors.surface,
                onRefresh: () async {
                  ref.invalidate(boardProvider(query));
                  try {
                    await ref.read(boardProvider(query).future);
                  } on Object {
                    // The screen shows the error.
                  }
                },
                child: ListView(
                  controller: _scroll,
                  padding: const EdgeInsets.only(bottom: AppSpacing.xxl),
                  physics: const AlwaysScrollableScrollPhysics(),
                  children: [
                    LargeTitle(
                      title: view?.first.title ?? 'Leaderboard',
                      subtitle: view == null ? null : _subtitle(view, scope, now),
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    ...content,
                  ],
                ),
              ),
            ),
          ),
          ?footer,
        ],
      ),
    );
  }

  String _subtitle(BoardView view, ExamScope scope, DateTime now) {
    final endsAt = view.first.endsAt;
    final me = view.first.me;
    final players = view.first.players;
    return [
      scope.label,
      if (BoardFamily.of(view.first.board).weekly && endsAt != null) endsInLabel(endsAt, now),
      // Percentiles only mean something on boards with 50 or more players.
      if (me != null && players != null && players >= 50)
        'You\'re in the top ${(me.position * 100 / players).ceil().clamp(1, 100)}%',
    ].join(' · ');
  }

  List<Widget> _rows(BuildContext context, BoardView view, ExamScope scope, String? myId) {
    final family = BoardFamily.of(view.first.board);
    final me = view.first.me;
    Widget row(BoardRow row) => Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.gutter, 0, AppSpacing.gutter, AppSpacing.sm),
      child: BoardRowTile(
        row: row,
        mine: isMine(row, myId),
        onTap: isMine(row, myId) || row.user.handle == null ? null : () => _openPlayer(row),
      ),
    );

    if (view.rows.isEmpty) {
      return [
        Gutter(
          child: SurfaceCard(
            child: EmptyState(
              icon: AppIcons.arena,
              tone: PastelTone.lemon,
              title: 'Be one of the first on this board',
              message: scope == ExamScope.allIndia
                  ? 'No one is on it yet. Play to take the top spot.'
                  : 'No ${scope.label} player is on it yet. See everyone with All India.',
              actionLabel: scope == ExamScope.allIndia ? 'Play a battle' : 'See All India',
              onAction: scope == ExamScope.allIndia
                  ? () => context.go(Routes.battleWith(subject: boardSubject(view.first.board)))
                  : () => ref.read(examScopeProvider.notifier).select(ExamScope.allIndia),
            ),
          ),
        ),
      ];
    }

    return [
      if (view.fewPlayers)
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.gutter,
            0,
            AppSpacing.gutter,
            AppSpacing.md,
          ),
          child: _FewPlayers(
            onAllIndia: scope == ExamScope.allIndia
                ? null
                : () => ref.read(examScopeProvider.notifier).select(ExamScope.allIndia),
          ),
        ),
      for (final item in view.rows) row(item),
      if (view.hasMore || view.moreError != null) _more(view),
      if (me != null && !view.meListed && view.first.aroundMe.isNotEmpty) ...[
        SectionHeader(
          key: _aroundKey,
          title: 'Around you',
          subtitle: family.weekly ? 'The players just above and below you this week' : null,
        ),
        for (final item in view.first.aroundMe) row(item),
      ],
    ];
  }

  Widget _more(BoardView view) {
    final notifier = ref.read(boardProvider(_query).notifier);
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.gutter, AppSpacing.sm, AppSpacing.gutter, 0),
      child: switch (view) {
        BoardView(loadingMore: true) => const Center(
          child: Padding(
            padding: EdgeInsets.all(AppSpacing.md),
            child: SizedBox.square(
              dimension: 24,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
          ),
        ),
        BoardView(:final moreError?) => ErrorState(
          compact: true,
          title: 'Couldn\'t load more',
          message: failureMessage(moreError),
          onRetry: () => unawaited(notifier.loadMore()),
        ),
        _ => AppButton(
          label: 'Show more',
          variant: AppButtonVariant.secondary,
          size: AppButtonSize.medium,
          onPressed: () => unawaited(notifier.loadMore()),
        ),
      },
    );
  }

  /// The pinned bottom bar: the viewer's own row when it isn't in view, or
  /// what they need to do to appear.
  Widget? _footer(BuildContext context, BoardView view) {
    final me = view.first.me;
    final games = view.first.gamesToRank;
    final family = BoardFamily.of(view.first.board);
    final Widget child;
    if (me != null) {
      if (view.meListed) return null;
      child = BoardRowTile(row: me, mine: true, onTap: () => unawaited(_showAroundMe()));
    } else if (games != null && games > 0) {
      child = _NotRanked(
        family: family,
        games: games,
        onPlay: () => context.go(Routes.battleWith(subject: boardSubject(view.first.board))),
      );
    } else {
      return null;
    }
    final colors = context.colors;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.paper,
        border: Border(top: BorderSide(color: colors.outline)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.gutter,
            AppSpacing.md,
            AppSpacing.gutter,
            AppSpacing.md,
          ),
          child: child,
        ),
      ),
    );
  }
}

class _FewPlayers extends StatelessWidget {
  const _FewPlayers({required this.onAllIndia});

  final VoidCallback? onAllIndia;

  @override
  Widget build(BuildContext context) {
    final text = context.text;
    final colors = context.colors;
    return SurfaceCard(
      color: colors.lemon.container,
      bordered: false,
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Row(
        children: [
          HugeIcon(AppIcons.rocket, size: 24, color: colors.lemon.onContainer),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Text(
              'Be one of the first on this board',
              style: text.titleMedium.copyWith(color: colors.lemon.onContainer),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (onAllIndia != null)
            AppButton(
              label: 'All India',
              variant: AppButtonVariant.secondary,
              size: AppButtonSize.small,
              expand: false,
              onPressed: onAllIndia,
            ),
        ],
      ),
    );
  }
}

/// "Play 7 more rated battles to appear", with progress and a Play button.
class _NotRanked extends StatelessWidget {
  const _NotRanked({required this.family, required this.games, required this.onPlay});

  final BoardFamily family;
  final int games;
  final VoidCallback onPlay;

  /// Rated games needed on rating boards; weekly subject boards need one.
  int get _needed => family.rated ? 10 : 1;

  @override
  Widget build(BuildContext context) {
    final text = context.text;
    final done = (_needed - games).clamp(0, _needed);
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Not on this board yet', style: text.titleMedium),
              const SizedBox(height: 2),
              Text(notRankedMessage(family, games), style: text.bodySmall),
              const SizedBox(height: AppSpacing.sm),
              AppProgressBar(
                value: done / _needed,
                height: 6,
                semanticLabel: '$done of $_needed games played',
              ),
            ],
          ),
        ),
        const SizedBox(width: AppSpacing.lg),
        AppButton(
          label: 'Play',
          leadingIcon: AppIcons.battle,
          size: AppButtonSize.medium,
          expand: false,
          onPressed: onPlay,
        ),
      ],
    );
  }
}
