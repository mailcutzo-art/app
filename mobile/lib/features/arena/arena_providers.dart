import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/live/live_hub.dart';
import '../../core/auth/session.dart';
import '../../core/auth/user.dart';
import '../../core/network/paging.dart';
import '../../core/notifications/local_reminders.dart';
import '../wallet/wallet_providers.dart';
import 'data/tournament_models.dart';
import 'data/tournament_repository.dart';
import 'tournament_reminders.dart';

/// Sections show their own retry button, so Riverpod's automatic retry is off.
Duration? _noAutoRetry(int _, Object _) => null;

/// The viewer's exam, which the lists are filtered by (`goal=`).
Goal? _goal(Ref ref) => switch (ref.watch(sessionProvider).value) {
  SignedIn(:final user) => user.goal,
  _ => null,
};

/// One Arena filter's tournaments, paged.
final arenaListProvider = AsyncNotifierProvider.autoDispose
    .family<ArenaListNotifier, Paged<Tournament>, ArenaFilter>(
      ArenaListNotifier.new,
      retry: _noAutoRetry,
    );

class ArenaListNotifier extends PagedNotifier<Tournament> {
  ArenaListNotifier(this.filter);

  final ArenaFilter filter;

  @override
  Future<Paged<Tournament>> build() {
    ref.watch(currentUserIdProvider);
    return super.build();
  }

  @override
  Future<CursorPage<Tournament>> fetch(String? cursor) =>
      ref.read(tournamentRepositoryProvider).list(filter, goal: _goal(ref), cursor: cursor);

  /// Shows [tournament]'s new state (after registering, say) without a reload.
  void replace(Tournament tournament) =>
      updateItems((items) => [for (final t in items) t.id == tournament.id ? tournament : t]);
}

/// `GET /v1/me/tournaments`, paged: Profile → Tournaments.
final myTournamentsProvider =
    AsyncNotifierProvider.autoDispose<MyTournamentsNotifier, Paged<MyTournament>>(
      MyTournamentsNotifier.new,
      retry: _noAutoRetry,
    );

class MyTournamentsNotifier extends PagedNotifier<MyTournament> {
  @override
  Future<Paged<MyTournament>> build() {
    ref.watch(currentUserIdProvider);
    return super.build();
  }

  @override
  Future<CursorPage<MyTournament>> fetch(String? cursor) =>
      ref.read(tournamentRepositoryProvider).mine(cursor: cursor);
}

/// The tournaments the viewer is in that haven't finished, soonest first: "My tournaments",
/// pinned at the top of the Arena.
final activeEntriesProvider = FutureProvider.autoDispose<List<Tournament>>((ref) async {
  ref.watch(currentUserIdProvider);
  final page = await ref.watch(tournamentRepositoryProvider).mine();
  return [
    for (final item in page.items)
      if (!item.tournament.status.isOver && item.tournament.entered) item.tournament,
  ]..sort((a, b) => a.startsAt.compareTo(b.startsAt));
}, retry: _noAutoRetry);

/// The tournament Home shows: the viewer's next or live one, otherwise the soonest open one
/// (the biggest pool among those starting the same day). Null when there is none.
final nextTournamentProvider = FutureProvider.autoDispose<Tournament?>((ref) async {
  final mine = await ref.watch(activeEntriesProvider.future);
  final live = mine.where((t) => t.status.isLive).firstOrNull;
  if (live != null) return live;
  if (mine.isNotEmpty) return mine.first;
  final open = await ref
      .watch(tournamentRepositoryProvider)
      .list(ArenaFilter.open, goal: _goal(ref));
  final candidates = open.items.where((t) => !t.isFull).toList()
    ..sort((a, b) => a.startsAt.compareTo(b.startsAt));
  if (candidates.isEmpty) return null;
  final soonest = candidates.first.startsAt;
  final sameDay = candidates.where(
    (t) => t.startsAt.difference(soonest) < const Duration(hours: 24),
  );
  return sameDay.reduce((a, b) => b.prizePool > a.prizePool ? b : a);
}, retry: _noAutoRetry);

/// `GET /v1/tournaments/{id}`.
final tournamentDetailProvider = FutureProvider.autoDispose.family<TournamentDetail, String>((
  ref,
  id,
) {
  ref.watch(currentUserIdProvider);
  return ref.watch(tournamentRepositoryProvider).detail(id);
}, retry: _noAutoRetry);

/// `GET /v1/tournaments/{id}/me`.
final myGamesProvider = FutureProvider.autoDispose.family<MyGames, String>((ref, id) {
  ref.watch(currentUserIdProvider);
  return ref.watch(tournamentRepositoryProvider).myGames(id);
}, retry: _noAutoRetry);

/// The REST standings loaded so far, with the viewer's own row.
@immutable
class StandingsView {
  const StandingsView({
    this.rows = const [],
    this.me,
    this.round,
    this.nextCursor,
    this.loadingMore = false,
    this.moreError,
  });

  final List<StandingRow> rows;
  final StandingRow? me;
  final int? round;
  final String? nextCursor;
  final bool loadingMore;
  final Object? moreError;

  bool get hasMore => nextCursor != null;

  /// Whether the viewer's row is among [rows] (else it sticks to the bottom).
  bool get meListed => me != null && rows.any((row) => row.user.id == me!.user.id);

  StandingsView copyWith({
    List<StandingRow>? rows,
    String? Function()? nextCursor,
    bool? loadingMore,
    Object? Function()? moreError,
  }) => StandingsView(
    rows: rows ?? this.rows,
    me: me,
    round: round,
    nextCursor: nextCursor == null ? this.nextCursor : nextCursor(),
    loadingMore: loadingMore ?? this.loadingMore,
    moreError: moreError == null ? this.moreError : moreError(),
  );
}

/// `GET /v1/tournaments/{id}/standings`, paged: the fallback while the live feed isn't there.
final standingsProvider = AsyncNotifierProvider.autoDispose
    .family<StandingsNotifier, StandingsView, String>(StandingsNotifier.new, retry: _noAutoRetry);

class StandingsNotifier extends AsyncNotifier<StandingsView> {
  StandingsNotifier(this.id);

  final String id;

  @override
  Future<StandingsView> build() async {
    ref.watch(currentUserIdProvider);
    final page = await ref.watch(tournamentRepositoryProvider).standings(id);
    return StandingsView(
      rows: page.items,
      me: page.me,
      round: page.round,
      nextCursor: page.nextCursor,
    );
  }

  Future<void> loadMore() async {
    final view = state.value;
    if (view == null || !view.hasMore || view.loadingMore) return;
    state = AsyncData(view.copyWith(loadingMore: true, moreError: () => null));
    try {
      final page = await ref
          .read(tournamentRepositoryProvider)
          .standings(id, cursor: view.nextCursor);
      if (!ref.mounted) return;
      final seen = {for (final row in view.rows) row.user.id};
      state = AsyncData(
        view.copyWith(
          rows: [...view.rows, ...page.items.where((row) => !seen.contains(row.user.id))],
          nextCursor: () => page.nextCursor,
          loadingMore: false,
        ),
      );
    } on Object catch (error) {
      if (!ref.mounted) return;
      state = AsyncData(view.copyWith(loadingMore: false, moreError: () => error));
    }
  }
}

/// What a registration did about reminders.
enum ReminderOutcome { scheduled, notificationsOff, unavailable }

/// Registering, withdrawing and checking in, with everything that follows: reminders set or
/// removed, and every list and screen that shows the tournament brought up to date.
class TournamentActions {
  TournamentActions(this._ref);

  final Ref _ref;

  TournamentRepository get _repo => _ref.read(tournamentRepositoryProvider);

  TournamentReminders get _reminders => _ref.read(tournamentRemindersProvider);

  /// Registers with [idempotencyKey] (one per confirmation sheet, so a retry never holds the fee
  /// twice), then schedules the reminders. Throws the server's [AppFailure]; see
  /// [arenaErrorMessage].
  Future<(Tournament, ReminderOutcome)> register(
    Tournament tournament, {
    required String idempotencyKey,
  }) async {
    final updated = await _repo.register(tournament.id, idempotencyKey: idempotencyKey);
    _changed(updated);
    final permission = await _reminders.scheduleFor(updated);
    return (
      updated,
      switch (permission) {
        ReminderPermission.granted => ReminderOutcome.scheduled,
        ReminderPermission.denied => ReminderOutcome.notificationsOff,
        ReminderPermission.unsupported => ReminderOutcome.unavailable,
      },
    );
  }

  /// Withdraws ("Can't make it" too) and removes the reminders.
  Future<Withdrawal> withdraw(String id) async {
    final withdrawal = await _repo.withdraw(id);
    await _reminders.cancelFor(id);
    _changed(withdrawal.tournament);
    _ref.read(liveHubProvider.notifier).dismiss(TournamentAlertIds.checkIn(id));
    return withdrawal;
  }

  Future<Tournament> checkIn(String id) async {
    final updated = await _repo.checkIn(id);
    _changed(updated);
    _ref.read(liveHubProvider.notifier).dismiss(TournamentAlertIds.checkIn(id));
    return updated;
  }

  /// Something about [tournament] changed: patch the lists, reload what depends on it.
  void _changed(Tournament tournament) {
    for (final filter in ArenaFilter.values) {
      if (_ref.exists(arenaListProvider(filter))) {
        _ref.read(arenaListProvider(filter).notifier).replace(tournament);
      }
    }
    refresh(tournament.id);
    _ref
      ..invalidate(walletProvider)
      ..invalidate(myTournamentsProvider);
  }

  /// Reloads everything that shows tournament [id] and the viewer's entries.
  void refresh(String id) {
    _ref
      ..invalidate(tournamentDetailProvider(id))
      ..invalidate(myGamesProvider(id))
      ..invalidate(standingsProvider(id))
      ..invalidate(activeEntriesProvider)
      ..invalidate(nextTournamentProvider);
  }

  /// Reloads the Arena's lists (a tournament moved between filters).
  void refreshLists() => _ref.invalidate(arenaListProvider);
}

final tournamentActionsProvider = Provider<TournamentActions>(TournamentActions.new);

/// Ids of the alerts the Arena puts on the live layer.
abstract final class TournamentAlertIds {
  static const prefix = 'arena.';

  static String checkIn(String id) => '${prefix}check-in-$id';

  static String atRisk(String id) => '${prefix}at-risk-$id';

  static String pairing(String id, int round) => '${prefix}pairing-$id-$round';

  static String bye(String id, int round) => '${prefix}bye-$id-$round';

  static String finished(String id) => '${prefix}finished-$id';

  static String cancelled(String id) => '${prefix}cancelled-$id';
}
