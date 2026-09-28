import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/user.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/app_failure.dart';
import '../../../core/network/paging.dart';
import '../../battle/data/battle_repository.dart' show parseResponse;
import '../../learn/data/learn_repository.dart' show demoDataProvider;
import '../demo/demo_arena.dart';
import 'tournament_models.dart';

/// The Arena's REST contract (`docs/api-play.md` "Tournaments").
abstract interface class TournamentRepository {
  /// `GET /v1/tournaments?status=&goal=&cursor=`.
  Future<CursorPage<Tournament>> list(ArenaFilter filter, {Goal? goal, String? cursor});

  /// `GET /v1/me/tournaments?cursor=`: upcoming and live first, then past ones with results.
  Future<CursorPage<MyTournament>> mine({String? cursor});

  /// `GET /v1/tournaments/{id}`.
  Future<TournamentDetail> detail(String id);

  /// `POST /v1/tournaments/{id}/register`: holds the entry fee. The same [idempotencyKey]
  /// retried never holds twice.
  Future<Tournament> register(String id, {required String idempotencyKey});

  /// `DELETE /v1/tournaments/{id}/register`: withdraw (a full refund before the start).
  Future<Withdrawal> withdraw(String id);

  /// `POST /v1/tournaments/{id}/check-in`, allowed from 15 to 2 minutes before the start.
  Future<Tournament> checkIn(String id);

  /// `GET /v1/tournaments/{id}/standings?cursor=`.
  Future<StandingsPage> standings(String id, {String? cursor});

  /// `GET /v1/tournaments/{id}/me`: the viewer's games by round.
  Future<MyGames> myGames(String id);
}

class ApiTournamentRepository implements TournamentRepository {
  ApiTournamentRepository(this._api);

  final ApiClient _api;

  static String _path(String id, [String rest = '']) =>
      '/v1/tournaments/${Uri.encodeComponent(id)}$rest';

  @override
  Future<CursorPage<Tournament>> list(ArenaFilter filter, {Goal? goal, String? cursor}) async {
    final data = await _api.get(
      '/v1/tournaments',
      query: {'status': filter.wire, 'goal': ?goal?.name, 'cursor': ?cursor},
    );
    return parseResponse(() => CursorPage.fromJson(data, Tournament.fromJson, what: 'tournaments'));
  }

  @override
  Future<CursorPage<MyTournament>> mine({String? cursor}) async {
    final data = await _api.get('/v1/me/tournaments', query: {'cursor': ?cursor});
    return parseResponse(
      () => CursorPage.fromJson(data, MyTournament.fromJson, what: 'my tournaments'),
    );
  }

  @override
  Future<TournamentDetail> detail(String id) async {
    final data = await _api.get(_path(id));
    return parseResponse(() => TournamentDetail.fromJson(data));
  }

  @override
  Future<Tournament> register(String id, {required String idempotencyKey}) async {
    final data = await _api.post(_path(id, '/register'), idempotencyKey: idempotencyKey);
    return parseResponse(() => Tournament.fromJson(data));
  }

  @override
  Future<Withdrawal> withdraw(String id) async {
    final data = await _api.delete(_path(id, '/register'));
    return parseResponse(() => Withdrawal.fromJson(data));
  }

  @override
  Future<Tournament> checkIn(String id) async {
    final data = await _api.post(_path(id, '/check-in'));
    return parseResponse(() => Tournament.fromJson(data));
  }

  @override
  Future<StandingsPage> standings(String id, {String? cursor}) async {
    final data = await _api.get(_path(id, '/standings'), query: {'cursor': ?cursor});
    return parseResponse(() => StandingsPage.fromJson(data));
  }

  @override
  Future<MyGames> myGames(String id) async {
    final data = await _api.get(_path(id, '/me'));
    return parseResponse(() => MyGames.fromJson(data));
  }
}

/// Error codes of the tournament endpoints.
abstract final class ArenaErrors {
  static const full = 'TOURNAMENT_FULL';
  static const registrationClosed = 'REGISTRATION_CLOSED';
  static const insufficientCoins = 'INSUFFICIENT_COINS';
  static const scheduleConflict = 'SCHEDULE_CONFLICT';
  static const notAllowed = 'NOT_ALLOWED';
  static const checkInClosed = 'CHECK_IN_CLOSED';
  static const notRegistered = 'NOT_REGISTERED';
}

/// What to tell the player when a tournament action fails. [tournament] fills in the fee and
/// exam when the server doesn't say.
String arenaErrorMessage(Object error, {Tournament? tournament}) {
  if (error is! AppFailure) return 'Something went wrong. Please try again.';
  final details = error.details;
  String? detail(String key) => details[key] is String ? details[key]! as String : null;
  int? number(String key) => details[key] is num ? (details[key]! as num).toInt() : null;
  switch (error.code) {
    case ArenaErrors.full:
      return 'This tournament is full.';
    case ArenaErrors.registrationClosed:
      return 'Registration has closed for this tournament.';
    case ArenaErrors.insufficientCoins:
      final fee = number('needed') ?? number('entry_fee') ?? tournament?.entryFee;
      return fee == null || fee == 0
          ? 'You don\'t have enough coins for this entry.'
          : 'You need $fee coins to enter. Win battles and missions to earn more.';
    case ArenaErrors.scheduleConflict:
      final other = detail('title');
      return other == null
          ? 'It overlaps another tournament you entered.'
          : 'It overlaps $other, which you already entered.';
    case ArenaErrors.notAllowed:
      return switch (detail('reason')) {
        'no_shows' =>
          'You missed check-in 3 times in 30 days, so paid tournaments are paused for 7 days. '
              'Free ones are still open.',
        'exam' => switch (tournament?.goal) {
          final goal? when goal != TournamentGoal.any =>
            'This tournament is for ${goal.label} players.',
          _ => 'This tournament is for the other exam.',
        },
        _ => 'You can\'t join this tournament.',
      };
    case ArenaErrors.checkInClosed:
      return 'Check-in is closed. It\'s open from 15 to 2 minutes before the start.';
    case ArenaErrors.notRegistered:
      return 'You\'re not registered for this tournament.';
  }
  return error.message;
}

/// The Arena in the debug "Demo data" mode.
final demoTournamentRepositoryProvider = Provider<TournamentRepository>(
  (ref) => ref.watch(demoArenaProvider).repository,
);

final tournamentRepositoryProvider = Provider<TournamentRepository>((ref) {
  // The constant keeps the demo out of release builds entirely.
  if (!kReleaseMode && ref.watch(demoDataProvider)) {
    return ref.watch(demoTournamentRepositoryProvider);
  }
  return ApiTournamentRepository(ref.watch(apiClientProvider));
});
