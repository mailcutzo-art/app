import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import '../../core/network/paging.dart';
import 'data/profile_models.dart';
import 'data/profile_repository.dart';

/// Sections show their own retry button, so Riverpod's automatic retry is off.
Duration? _noAutoRetry(int _, Object _) => null;

/// `GET /v1/me/stats?range=`. The stats card reads the 30-day one; the chart reads the range
/// picked, so switching to 90 days or all time asks once more.
final statsProvider = FutureProvider.autoDispose.family<PlayerStats, StatsRange>((ref, range) {
  // Someone else signing in on this phone gets their own stats.
  ref.watch(currentUserIdProvider);
  return ref.watch(profileRepositoryProvider).stats(range);
}, retry: _noAutoRetry);

/// The chart's range, kept while the Profile is open.
final ratingRangeProvider = NotifierProvider.autoDispose<RatingRange, StatsRange>(RatingRange.new);

class RatingRange extends Notifier<StatsRange> {
  @override
  StatsRange build() => StatsRange.days30;

  void select(StatsRange range) => state = range;
}

/// `GET /v1/me/opponents?days=30`.
final recentOpponentsProvider = FutureProvider.autoDispose<List<RecentOpponent>>((ref) {
  ref.watch(currentUserIdProvider);
  return ref.watch(profileRepositoryProvider).opponents();
}, retry: _noAutoRetry);

/// Battles, newest first, paged.
final matchHistoryProvider =
    AsyncNotifierProvider.autoDispose<MatchHistoryNotifier, Paged<MatchHistoryItem>>(
      MatchHistoryNotifier.new,
      retry: _noAutoRetry,
    );

class MatchHistoryNotifier extends PagedNotifier<MatchHistoryItem> {
  @override
  Future<Paged<MatchHistoryItem>> build() {
    ref.watch(currentUserIdProvider);
    return super.build();
  }

  @override
  Future<CursorPage<MatchHistoryItem>> fetch(String? cursor) =>
      ref.read(profileRepositoryProvider).matches(cursor: cursor);
}

/// Practice sessions, newest first, paged.
final practiceHistoryProvider =
    AsyncNotifierProvider.autoDispose<PracticeHistoryNotifier, Paged<PracticeHistoryItem>>(
      PracticeHistoryNotifier.new,
      retry: _noAutoRetry,
    );

class PracticeHistoryNotifier extends PagedNotifier<PracticeHistoryItem> {
  @override
  Future<Paged<PracticeHistoryItem>> build() {
    ref.watch(currentUserIdProvider);
    return super.build();
  }

  @override
  Future<CursorPage<PracticeHistoryItem>> fetch(String? cursor) =>
      ref.read(profileRepositoryProvider).practiceSessions(cursor: cursor);
}

/// Which history the Profile shows.
enum HistoryTab { battles, practice }

final historyTabProvider = NotifierProvider.autoDispose<HistoryTabSetting, HistoryTab>(
  HistoryTabSetting.new,
);

class HistoryTabSetting extends Notifier<HistoryTab> {
  @override
  HistoryTab build() => HistoryTab.battles;

  void select(HistoryTab tab) => state = tab;
}
