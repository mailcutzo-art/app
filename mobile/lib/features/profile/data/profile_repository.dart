import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/paging.dart';
import '../../battle/data/battle_repository.dart' show parseResponse;
import '../../learn/data/learn_repository.dart' show demoDataProvider;
import 'fake_profile_repository.dart';
import 'profile_models.dart';

/// The Profile's REST contract: stats (`docs/api-play.md`, "Profiles and stats"), match history
/// ("Matches"), recent opponents ("Social") and practice history (`docs/api-learn.md`).
abstract interface class ProfileRepository {
  /// `GET /v1/me/stats?range=`.
  Future<PlayerStats> stats(StatsRange range);

  /// `GET /v1/me/matches?cursor=`, newest first.
  Future<CursorPage<MatchHistoryItem>> matches({String? cursor});

  /// `GET /v1/me/practice/sessions?cursor=`, newest first.
  Future<CursorPage<PracticeHistoryItem>> practiceSessions({String? cursor});

  /// `GET /v1/me/opponents?days=`: people (not bots) played recently.
  Future<List<RecentOpponent>> opponents({int days = 30});
}

class ApiProfileRepository implements ProfileRepository {
  ApiProfileRepository(this._api);

  final ApiClient _api;

  @override
  Future<PlayerStats> stats(StatsRange range) async {
    final data = await _api.get('/v1/me/stats', query: {'range': range.wire});
    return parseResponse(() => PlayerStats.fromJson(data));
  }

  @override
  Future<CursorPage<MatchHistoryItem>> matches({String? cursor}) async {
    final data = await _api.get('/v1/me/matches', query: {'cursor': ?cursor});
    return parseResponse(
      () => CursorPage.fromJson(data, MatchHistoryItem.fromJson, what: 'match history'),
    );
  }

  @override
  Future<CursorPage<PracticeHistoryItem>> practiceSessions({String? cursor}) async {
    final data = await _api.get('/v1/me/practice/sessions', query: {'cursor': ?cursor});
    return parseResponse(
      () => CursorPage.fromJson(data, PracticeHistoryItem.fromJson, what: 'practice history'),
    );
  }

  @override
  Future<List<RecentOpponent>> opponents({int days = 30}) async {
    final data = await _api.get('/v1/me/opponents', query: {'days': days});
    // A list envelope (`{"items": [...]}`) or a bare list.
    final items = data is List ? {'items': data} : data;
    return parseResponse(
      () => CursorPage.fromJson(items, RecentOpponent.fromJson, what: 'opponents').items,
    );
  }
}

/// The Profile in the debug "Demo data" mode.
final demoProfileRepositoryProvider = Provider<FakeProfileRepository>(
  (ref) => FakeProfileRepository.seeded(latency: const Duration(milliseconds: 300)),
);

final profileRepositoryProvider = Provider<ProfileRepository>((ref) {
  // The constant keeps the demo out of release builds entirely.
  if (!kReleaseMode && ref.watch(demoDataProvider)) {
    return ref.watch(demoProfileRepositoryProvider);
  }
  return ApiProfileRepository(ref.watch(apiClientProvider));
});
