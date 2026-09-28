import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/app_failure.dart';
import '../../learn/data/learn_repository.dart' show demoDataProvider;
import '../../share/share_models.dart';
import 'fake_social_repository.dart';
import 'social_models.dart';

/// The social REST contract ("Social" and "Profiles and stats" in `docs/api-play.md`).
abstract interface class SocialRepository {
  /// `GET /v1/me/friends?cursor=`: friends with their presence.
  Future<CursorPage<Friend>> friends({String? cursor});

  /// `GET /v1/users/search?q=`: handles starting with [query] (at least 3
  /// characters). [cancelToken] drops a search the user has typed past.
  Future<List<SearchResult>> search(String query, {CancelToken? cancelToken});

  /// `POST /v1/friend-requests`. Throws [ForbiddenFailure] or
  /// [ConflictFailure] with code `NOT_ALLOWED` (their privacy settings;
  /// `details.reason` says which) or `LIMIT_REACHED` (20 a day, 100 pending).
  Future<SentRequest> sendRequest(String userId);

  /// `GET /v1/me/friend-requests`.
  Future<FriendRequests> requests();

  /// `POST /v1/friend-requests/{id}/accept`.
  Future<void> acceptRequest(String requestId);

  /// `POST /v1/friend-requests/{id}/decline`.
  Future<void> declineRequest(String requestId);

  /// `DELETE /v1/friend-requests/{id}`: cancels the user's own request.
  Future<void> cancelRequest(String requestId);

  /// `DELETE /v1/me/friends/{user_id}`.
  Future<void> removeFriend(String userId);

  /// `GET /v1/me/rivals`: opponents met 3+ times in 60 days.
  Future<List<Opponent>> rivals();

  /// `GET /v1/me/opponents?days=`: recent opponents (people, not bots).
  Future<List<Opponent>> opponents({int days = 30});

  /// `GET /v1/me/activity?cursor=`: friends' events, and the user's own
  /// shares, from the last 7 days.
  Future<CursorPage<ActivityItem>> activity({String? cursor});

  /// `POST /v1/me/activity/shares`: posts a battle result or the user's
  /// progress to their friends' activity, and returns the new item. Throws
  /// [NotFoundFailure] (the battle can't be shared), or [ConflictFailure]
  /// with code `ALREADY_SHARED` (a battle is posted once) or `LIMIT_REACHED`
  /// (progress 3 times a day).
  Future<ActivityItem> share(ShareTarget target, {required String idempotencyKey});

  /// `POST /v1/blocks`.
  Future<void> block(String userId);

  /// `DELETE /v1/blocks/{user_id}`.
  Future<void> unblock(String userId);

  /// `GET /v1/me/blocks`.
  Future<List<UserCard>> blocks();

  /// `POST /v1/reports` → `202`.
  Future<void> report({
    required String userId,
    required ReportReason reason,
    String? matchId,
    String? note,
  });

  /// `GET /v1/users/{handle}`. Throws [NotFoundFailure] for an unknown
  /// handle, or when either player has blocked the other.
  Future<PublicProfile> profile(String handle);
}

/// Talks to the API through [ApiClient].
class ApiSocialRepository implements SocialRepository {
  ApiSocialRepository(this._api);

  final ApiClient _api;

  @override
  Future<CursorPage<Friend>> friends({String? cursor}) async {
    final data = await _api.get('/v1/me/friends', query: {'cursor': ?cursor});
    return _parse(() => CursorPage.fromJson(data, Friend.fromJson));
  }

  @override
  Future<List<SearchResult>> search(String query, {CancelToken? cancelToken}) async {
    // Straight through Dio so the request can be cancelled; errors map the same way.
    final Object? data;
    try {
      final response = await _api.dio.get<Object?>(
        '/v1/users/search',
        queryParameters: {'q': query},
        cancelToken: cancelToken,
      );
      data = response.data;
    } on DioException catch (e) {
      throw failureFromDio(e);
    }
    return _parse(() => CursorPage.fromJson(data, SearchResult.fromJson).items);
  }

  @override
  Future<SentRequest> sendRequest(String userId) async {
    final data = await _api.post('/v1/friend-requests', body: {'user_id': userId});
    return SentRequest.fromJson(data);
  }

  @override
  Future<FriendRequests> requests() async {
    final data = await _api.get('/v1/me/friend-requests');
    return _parse(() => FriendRequests.fromJson(data));
  }

  @override
  Future<void> acceptRequest(String requestId) =>
      _api.post('/v1/friend-requests/${_segment(requestId)}/accept');

  @override
  Future<void> declineRequest(String requestId) =>
      _api.post('/v1/friend-requests/${_segment(requestId)}/decline');

  @override
  Future<void> cancelRequest(String requestId) =>
      _api.delete('/v1/friend-requests/${_segment(requestId)}');

  @override
  Future<void> removeFriend(String userId) => _api.delete('/v1/me/friends/${_segment(userId)}');

  @override
  Future<List<Opponent>> rivals() async {
    final data = await _api.get('/v1/me/rivals');
    return _parse(() => CursorPage.fromJson(data, Opponent.fromJson).items);
  }

  @override
  Future<List<Opponent>> opponents({int days = 30}) async {
    final data = await _api.get('/v1/me/opponents', query: {'days': days});
    return _parse(() => CursorPage.fromJson(data, Opponent.fromJson).items);
  }

  @override
  Future<CursorPage<ActivityItem>> activity({String? cursor}) async {
    final data = await _api.get('/v1/me/activity', query: {'cursor': ?cursor});
    return _parse(() => CursorPage.fromJson(data, ActivityItem.fromJson));
  }

  @override
  Future<ActivityItem> share(ShareTarget target, {required String idempotencyKey}) async {
    final data = await _api.post(
      '/v1/me/activity/shares',
      body: target.toJson(),
      idempotencyKey: idempotencyKey,
    );
    return _parse(() => ActivityItem.fromJson(data));
  }

  @override
  Future<void> block(String userId) => _api.post('/v1/blocks', body: {'user_id': userId});

  @override
  Future<void> unblock(String userId) => _api.delete('/v1/blocks/${_segment(userId)}');

  @override
  Future<List<UserCard>> blocks() async {
    final data = await _api.get('/v1/me/blocks');
    return _parse(() => CursorPage.fromJson(data, UserCard.fromItem).items);
  }

  @override
  Future<void> report({
    required String userId,
    required ReportReason reason,
    String? matchId,
    String? note,
  }) => _api.post(
    '/v1/reports',
    body: {
      'user_id': userId,
      'reason': reason.wire,
      'match_id': ?matchId,
      if (note != null && note.trim().isNotEmpty) 'note': note.trim(),
    },
  );

  @override
  Future<PublicProfile> profile(String handle) async {
    final data = await _api.get('/v1/users/${_segment(handle)}');
    return _parse(() => PublicProfile.fromJson(data));
  }

  static String _segment(String value) => Uri.encodeComponent(value);

  /// A payload the app can't read is logged and shown as a generic failure.
  static T _parse<T>(T Function() parse) {
    try {
      return parse();
    } on FormatException catch (e) {
      debugPrint('Unexpected response: $e');
      throw const UnexpectedFailure();
    }
  }
}

/// The in-memory sample server behind the debug "Demo data" switch.
final demoSocialRepositoryProvider = Provider<FakeSocialRepository>(
  (ref) => FakeSocialRepository.seeded(latency: const Duration(milliseconds: 300)),
);

final socialRepositoryProvider = Provider<SocialRepository>((ref) {
  // The constant keeps the demo out of release builds entirely.
  if (!kReleaseMode && ref.watch(demoDataProvider)) return ref.watch(demoSocialRepositoryProvider);
  return ApiSocialRepository(ref.watch(apiClientProvider));
});
