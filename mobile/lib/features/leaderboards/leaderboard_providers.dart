import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import 'data/leaderboard_models.dart';
import 'data/leaderboard_repository.dart';

/// The exam filter of the hub and every board. It starts at the viewer's own
/// exam; All India shows everyone.
final examScopeProvider = NotifierProvider<ExamScopeSetting, ExamScope>(ExamScopeSetting.new);

class ExamScopeSetting extends Notifier<ExamScope> {
  @override
  ExamScope build() => ExamScope.of(ref.watch(meProvider.select((me) => me.goal)));

  void select(ExamScope scope) => state = scope;
}

/// Sections show their own retry button, so Riverpod's automatic retry is off.
Duration? _noAutoRetry(int _, Object _) => null;

/// `GET /v1/leaderboards` for one exam filter.
final leaderboardHubProvider = FutureProvider.autoDispose.family<LeaderboardHub, ExamScope>((
  ref,
  scope,
) {
  // Someone else signing in on this phone must not see the last user's standings.
  ref.watch(currentUserIdProvider);
  return ref.watch(leaderboardRepositoryProvider).hub(goal: scope.goal);
}, retry: _noAutoRetry);

/// Which board, under which filter.
typedef BoardQuery = ({String board, ExamScope scope});

/// A board as loaded so far: the first page's facts plus every row fetched.
@immutable
class BoardView {
  const BoardView({
    required this.first,
    required this.rows,
    this.nextCursor,
    this.loadingMore = false,
    this.moreError,
  });

  final BoardPage first;
  final List<BoardRow> rows;
  final String? nextCursor;
  final bool loadingMore;

  /// The last "load more" failed; the list offers a retry.
  final Object? moreError;

  bool get hasMore => nextCursor != null;

  /// Whether the viewer's row is among the rows loaded.
  bool get meListed => first.me != null && rows.any((row) => row.user.id == first.me!.user.id);

  /// How many players the board holds, when known: the server's count, or
  /// the rows once the last page is in.
  int? get players => first.players ?? (hasMore ? null : rows.length);

  /// "Be one of the first on this board": fewer than 10 players.
  bool get fewPlayers => players != null && players! < 10;

  BoardView copyWith({
    List<BoardRow>? rows,
    String? nextCursor,
    bool clearCursor = false,
    bool? loadingMore,
    Object? moreError,
  }) => BoardView(
    first: first,
    rows: rows ?? this.rows,
    nextCursor: clearCursor ? null : nextCursor ?? this.nextCursor,
    loadingMore: loadingMore ?? this.loadingMore,
    moreError: moreError,
  );
}

final boardProvider = AsyncNotifierProvider.autoDispose
    .family<BoardController, BoardView, BoardQuery>(BoardController.new, retry: _noAutoRetry);

/// Loads a board's first page, then more on request (50 at a time, top 100).
class BoardController extends AsyncNotifier<BoardView> {
  BoardController(this.query);

  final BoardQuery query;

  @override
  Future<BoardView> build() async {
    ref.watch(currentUserIdProvider);
    final page = await ref
        .watch(leaderboardRepositoryProvider)
        .board(query.board, goal: query.scope.goal);
    return BoardView(first: page, rows: page.items, nextCursor: page.nextCursor);
  }

  /// Fetches the next page. Does nothing while one is loading or when
  /// everything is in.
  Future<void> loadMore() async {
    final view = state.value;
    if (view == null || !view.hasMore || view.loadingMore) return;
    state = AsyncData(view.copyWith(loadingMore: true));
    try {
      final page = await ref
          .read(leaderboardRepositoryProvider)
          .board(query.board, goal: query.scope.goal, cursor: view.nextCursor);
      if (!ref.mounted) return;
      final seen = {for (final row in view.rows) row.position};
      state = AsyncData(
        view.copyWith(
          rows: [...view.rows, ...page.items.where((row) => !seen.contains(row.position))],
          nextCursor: page.nextCursor,
          clearCursor: page.nextCursor == null,
          loadingMore: false,
        ),
      );
    } on Object catch (error) {
      if (!ref.mounted) return;
      state = AsyncData(view.copyWith(loadingMore: false, moreError: error));
    }
  }
}
