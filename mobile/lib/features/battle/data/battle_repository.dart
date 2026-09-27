import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/session.dart';
import '../../../core/auth/user.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/app_failure.dart';
import '../../learn/data/learn_repository.dart' show demoDataProvider;
import '../demo/demo_providers.dart';
import 'battle_models.dart';
import 'match_models.dart';

/// The Battle tab's REST contract (`docs/api-play.md`, "Battle setup").
abstract interface class BattleRepository {
  /// `GET /v1/battle/setup?goal=`.
  Future<BattleSetup> setup(Goal goal);
}

/// Results and reviews of finished games (`docs/api-play.md`, "Matches").
abstract interface class MatchRepository {
  /// `GET /v1/matches/{id}`: the result, its status and the settlement once committed.
  Future<MatchSummary> match(String matchId);

  /// `GET /v1/matches/{id}/review`: every question with the answers and explanations.
  Future<MatchReview> review(String matchId);
}

class ApiBattleRepository implements BattleRepository {
  ApiBattleRepository(this._api, {this.myId});

  final ApiClient _api;

  /// Recognises the signed-in user as a board leader.
  final String? myId;

  @override
  Future<BattleSetup> setup(Goal goal) async {
    final data = await _api.get('/v1/battle/setup', query: {'goal': goal.name});
    return parseResponse(() => BattleSetup.fromJson(data, myId: myId));
  }
}

class ApiMatchRepository implements MatchRepository {
  ApiMatchRepository(this._api);

  final ApiClient _api;

  @override
  Future<MatchSummary> match(String matchId) async {
    final data = await _api.get('/v1/matches/${Uri.encodeComponent(matchId)}');
    return parseResponse(() => MatchSummary.fromJson(data));
  }

  @override
  Future<MatchReview> review(String matchId) async {
    final data = await _api.get('/v1/matches/${Uri.encodeComponent(matchId)}/review');
    return parseResponse(() => MatchReview.fromJson(data));
  }
}

/// A payload the app can't read is logged and shown as a generic failure.
T parseResponse<T>(T Function() parse) {
  try {
    return parse();
  } on FormatException catch (e) {
    debugPrint('Unexpected response: $e');
    throw const UnexpectedFailure();
  }
}

final battleRepositoryProvider = Provider<BattleRepository>((ref) {
  // The constant keeps the demo out of release builds entirely.
  if (!kReleaseMode && ref.watch(demoDataProvider)) return ref.watch(demoBattleRepositoryProvider);
  return ApiBattleRepository(ref.watch(apiClientProvider), myId: ref.watch(currentUserIdProvider));
});

final matchRepositoryProvider = Provider<MatchRepository>((ref) {
  if (!kReleaseMode && ref.watch(demoDataProvider)) return ref.watch(demoMatchRepositoryProvider);
  return ApiMatchRepository(ref.watch(apiClientProvider));
});

/// The Battle tab's data for an exam. Sections offer their own retry, so there is no automatic
/// one.
final battleSetupProvider = FutureProvider.family<BattleSetup, Goal>((ref, goal) {
  // Someone else signing in on this phone gets their own coins and ratings.
  ref.watch(currentUserIdProvider);
  return ref.watch(battleRepositoryProvider).setup(goal);
}, retry: (_, _) => null);
