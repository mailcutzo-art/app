import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/session.dart';
import '../../../core/auth/user.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/app_failure.dart';
import '../../learn/data/learn_repository.dart' show demoDataProvider;
import 'fake_leaderboard_repository.dart';
import 'leaderboard_models.dart';

/// The leaderboards REST contract (`docs/api-play.md` "Leaderboards").
abstract interface class LeaderboardRepository {
  /// `GET /v1/leaderboards?goal=`. A null [goal] is All India.
  Future<LeaderboardHub> hub({Goal? goal});

  /// `GET /v1/leaderboards/{board}?goal=&cursor=&limit=`.
  Future<BoardPage> board(String board, {Goal? goal, String? cursor, int? limit});
}

class ApiLeaderboardRepository implements LeaderboardRepository {
  ApiLeaderboardRepository(this._api);

  final ApiClient _api;

  @override
  Future<LeaderboardHub> hub({Goal? goal}) async {
    final data = await _api.get('/v1/leaderboards', query: {'goal': ?goal?.name});
    return _parse(() => LeaderboardHub.fromJson(data));
  }

  @override
  Future<BoardPage> board(String board, {Goal? goal, String? cursor, int? limit}) async {
    final data = await _api.get(
      // Board ids contain `:` (`rating:physics`), so the segment is encoded.
      '/v1/leaderboards/${Uri.encodeComponent(board)}',
      query: {'goal': ?goal?.name, 'cursor': ?cursor, 'limit': ?limit},
    );
    return _parse(() => BoardPage.fromJson(data));
  }

  static T _parse<T>(T Function() parse) {
    try {
      return parse();
    } on FormatException catch (e) {
      debugPrint('Unexpected response: $e');
      throw const UnexpectedFailure();
    }
  }
}

/// The sample boards behind the debug "Demo data" switch.
final demoLeaderboardRepositoryProvider = Provider<FakeLeaderboardRepository>((ref) {
  final user = switch (ref.read(sessionProvider).value) {
    SignedIn(:final user) => user,
    _ => null,
  };
  ref.watch(currentUserIdProvider);
  return FakeLeaderboardRepository.seeded(me: user, latency: const Duration(milliseconds: 300));
});

final leaderboardRepositoryProvider = Provider<LeaderboardRepository>((ref) {
  // The constant keeps the demo out of release builds entirely.
  if (!kReleaseMode && ref.watch(demoDataProvider)) {
    return ref.watch(demoLeaderboardRepositoryProvider);
  }
  return ApiLeaderboardRepository(ref.watch(apiClientProvider));
});
