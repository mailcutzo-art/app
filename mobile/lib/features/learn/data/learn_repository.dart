import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../app/env.dart';
import '../../../core/auth/user.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/app_failure.dart';
import '../../../core/storage/prefs.dart';
import '../../practice/data/practice_models.dart';
import 'fake_learn_repository.dart';
import 'learn_models.dart';

/// The Learn and practice REST contract (`docs/api-learn.md`).
abstract interface class LearnRepository {
  /// `GET /v1/catalog?goal=`.
  Future<Catalog> catalog(Goal goal);

  /// `GET /v1/me/progress?goal=`.
  Future<Progress> progress(Goal goal);

  /// `POST /v1/practice/sessions`. A retry with the same [idempotencyKey]
  /// returns the same session. Throws [ConflictFailure] with code
  /// `NO_QUESTIONS` when nothing matches.
  Future<PracticeSession> createSession(SessionSettings settings, {required String idempotencyKey});

  /// `GET /v1/practice/sessions/{id}`, used to resume a session.
  Future<PracticeSession> session(String sessionId);

  /// `POST /v1/practice/sessions/{id}/answers`, at most 50 at a time.
  Future<AnswersResponse> uploadAnswers(String sessionId, List<AnswerUpload> answers);

  /// `POST /v1/practice/sessions/{id}/finish`. Idempotent.
  Future<SessionSummary> finishSession(String sessionId);

  /// `GET /v1/me/tips`.
  Future<TipsOverview> tips();

  /// `POST /v1/me/tips/{key}/dismiss`: hides the tip for 7 days.
  Future<void> dismissTip(String key);

  /// `PUT` or `DELETE /v1/me/bookmarks/{ref}`. Both are idempotent.
  Future<void> setBookmark(String ref, {required bool bookmarked});

  /// `GET /v1/me/reviews/summary`.
  Future<ReviewsSummary> reviewsSummary();
}

/// Talks to the API through [ApiClient]. The catalog (the same for every
/// player of an exam) is kept on the device so the Learn tab still shows
/// subjects and chapters when the server can't be reached.
class ApiLearnRepository implements LearnRepository {
  ApiLearnRepository(this._api, {this._cache});

  final ApiClient _api;
  final SharedPreferences? _cache;

  static String catalogCacheKey(Goal goal) => 'learn.catalog.${goal.name}';

  @override
  Future<Catalog> catalog(Goal goal) async {
    final key = catalogCacheKey(goal);
    final Object? data;
    try {
      data = await _api.get('/v1/catalog', query: {'goal': goal.name});
    } on AppFailure catch (failure) {
      final cached = failure.isRetryable ? _cachedCatalog(key) : null;
      if (cached == null) rethrow;
      return cached;
    }
    final catalog = _parse(() => Catalog.fromJson(data));
    await _cache?.setString(key, jsonEncode(data));
    return catalog;
  }

  Catalog? _cachedCatalog(String key) {
    final raw = _cache?.getString(key);
    if (raw == null) return null;
    try {
      return Catalog.fromJson(jsonDecode(raw), fromCache: true);
    } on FormatException catch (e) {
      debugPrint('Ignoring unreadable cached catalog: $e');
      return null;
    }
  }

  @override
  Future<Progress> progress(Goal goal) async {
    final data = await _api.get('/v1/me/progress', query: {'goal': goal.name});
    return _parse(() => Progress.fromJson(data));
  }

  @override
  Future<PracticeSession> createSession(
    SessionSettings settings, {
    required String idempotencyKey,
  }) async {
    final data = await _api.post(
      '/v1/practice/sessions',
      body: settings.toJson(),
      idempotencyKey: idempotencyKey,
    );
    return _parse(() => PracticeSession.fromJson(data));
  }

  @override
  Future<PracticeSession> session(String sessionId) async {
    final data = await _api.get('/v1/practice/sessions/${_segment(sessionId)}');
    return _parse(() => PracticeSession.fromJson(data));
  }

  @override
  Future<AnswersResponse> uploadAnswers(String sessionId, List<AnswerUpload> answers) async {
    final data = await _api.post(
      '/v1/practice/sessions/${_segment(sessionId)}/answers',
      body: {
        'answers': [for (final answer in answers) answer.toJson()],
      },
    );
    return _parse(() => AnswersResponse.fromJson(data));
  }

  @override
  Future<SessionSummary> finishSession(String sessionId) async {
    final data = await _api.post('/v1/practice/sessions/${_segment(sessionId)}/finish');
    return _parse(() => SessionSummary.fromJson(data));
  }

  @override
  Future<TipsOverview> tips() async {
    final data = await _api.get('/v1/me/tips');
    return _parse(() => TipsOverview.fromJson(data));
  }

  @override
  Future<void> dismissTip(String key) => _api.post('/v1/me/tips/${_segment(key)}/dismiss');

  @override
  Future<void> setBookmark(String ref, {required bool bookmarked}) {
    final path = '/v1/me/bookmarks/${_segment(ref)}';
    return bookmarked ? _api.put(path) : _api.delete(path);
  }

  @override
  Future<ReviewsSummary> reviewsSummary() async {
    final data = await _api.get('/v1/me/reviews/summary');
    return _parse(() => ReviewsSummary.fromJson(data));
  }

  /// Ids are opaque (tip keys contain `:`), so every path segment is encoded.
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

/// Debug builds only: serve Learn and practice from built-in sample data, so
/// the flow can be tried before the backend has these endpoints.
final demoDataProvider = NotifierProvider<DemoDataSetting, bool>(DemoDataSetting.new);

class DemoDataSetting extends Notifier<bool> {
  static const prefKey = 'debug.demo_data';

  @override
  bool build() {
    if (!ref.watch(appEnvProvider).demoDataAvailable) return false;
    return ref.watch(sharedPrefsProvider).getBool(prefKey) ?? false;
  }

  Future<void> set({required bool enabled}) async {
    await ref.read(sharedPrefsProvider).setBool(prefKey, enabled);
    state = enabled && ref.read(appEnvProvider).demoDataAvailable;
  }
}

/// The in-memory sample server behind the "Demo data" switch.
final demoLearnRepositoryProvider = Provider<FakeLearnRepository>(
  (ref) => FakeLearnRepository.seeded(),
);

final learnRepositoryProvider = Provider<LearnRepository>((ref) {
  if (ref.watch(demoDataProvider)) return ref.watch(demoLearnRepositoryProvider);
  return ApiLearnRepository(ref.watch(apiClientProvider), cache: ref.watch(sharedPrefsProvider));
});
