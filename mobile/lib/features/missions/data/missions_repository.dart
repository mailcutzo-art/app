import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/session.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/app_failure.dart';
import '../../learn/data/learn_repository.dart' show demoDataProvider;
import 'fake_missions_repository.dart';
import 'missions_models.dart';

/// Missions, streaks and achievements (`docs/api-play.md`).
abstract interface class MissionsRepository {
  /// `GET /v1/me/missions`.
  Future<MissionsDay> missions();

  /// `POST /v1/me/missions/{id}/swap`: one free swap a day. Returns the
  /// updated day. Throws [ConflictFailure] (`SWAP_USED`, `MISSION_DONE`)
  /// when the swap isn't allowed.
  Future<MissionsDay> swap(String missionId);

  /// `POST /v1/me/streak/freezes`. A retry with the same [idempotencyKey]
  /// buys only once. Throws [ConflictFailure] with `INSUFFICIENT_COINS` or
  /// `LIMIT_REACHED` (at most 2 held).
  Future<FreezePurchase> buyFreeze({required String idempotencyKey});

  /// `GET /v1/me/streak?days=`.
  Future<StreakCalendar> streak({int days = 30});

  /// `GET /v1/me/achievements`.
  Future<Achievements> achievements();
}

class ApiMissionsRepository implements MissionsRepository {
  ApiMissionsRepository(this._api);

  final ApiClient _api;

  @override
  Future<MissionsDay> missions() async {
    final data = await _api.get('/v1/me/missions');
    return _parse(() => MissionsDay.fromJson(data));
  }

  @override
  Future<MissionsDay> swap(String missionId) async {
    final data = await _api.post('/v1/me/missions/${Uri.encodeComponent(missionId)}/swap');
    try {
      return MissionsDay.fromJson(data);
    } on FormatException {
      // The swap went through but the answer isn't the whole day: read it.
      return missions();
    }
  }

  @override
  Future<FreezePurchase> buyFreeze({required String idempotencyKey}) async {
    final data = await _api.post('/v1/me/streak/freezes', idempotencyKey: idempotencyKey);
    return _parse(() => FreezePurchase.fromJson(data));
  }

  @override
  Future<StreakCalendar> streak({int days = 30}) async {
    final data = await _api.get('/v1/me/streak', query: {'days': days});
    return _parse(() => StreakCalendar.fromJson(data));
  }

  @override
  Future<Achievements> achievements() async {
    final data = await _api.get('/v1/me/achievements');
    return _parse(() => Achievements.fromJson(data));
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

/// Sample missions, streak and achievements behind the debug "Demo data" switch.
final demoMissionsRepositoryProvider = Provider<FakeMissionsRepository>((ref) {
  ref.watch(currentUserIdProvider);
  return FakeMissionsRepository.seeded(latency: const Duration(milliseconds: 300));
});

final missionsRepositoryProvider = Provider<MissionsRepository>((ref) {
  // The constant keeps the demo out of release builds entirely.
  if (!kReleaseMode && ref.watch(demoDataProvider)) {
    return ref.watch(demoMissionsRepositoryProvider);
  }
  return ApiMissionsRepository(ref.watch(apiClientProvider));
});
