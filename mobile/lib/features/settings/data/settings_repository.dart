import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/user.dart';
import '../../../core/network/api_client.dart';
import '../../battle/data/battle_repository.dart' show parseResponse;
import '../../learn/data/learn_repository.dart' show demoDataProvider;
import 'fake_settings_repository.dart';
import 'settings_models.dart';

/// Settings kept on the server (`docs/api-play.md`, "Inbox and push", "Social") and signed-in
/// devices (`/v1/me/sessions`).
abstract interface class SettingsRepository {
  /// `GET /v1/me/settings/notifications`.
  Future<NotificationSettings> notifications();

  /// `PUT /v1/me/settings/notifications`; returns what the server stored.
  Future<NotificationSettings> saveNotifications(NotificationSettings settings);

  /// `GET /v1/me/settings/privacy`.
  Future<PrivacySettings> privacy();

  /// `PUT /v1/me/settings/privacy`.
  Future<PrivacySettings> savePrivacy(PrivacySettings settings);

  /// `GET /v1/me/settings/app`.
  Future<AppSettings> app();

  /// `PUT /v1/me/settings/app`.
  Future<AppSettings> saveApp(AppSettings settings);

  /// `GET /v1/me/sessions`, most recently active first.
  Future<List<DeviceSession>> sessions();

  /// `DELETE /v1/me/sessions/{id}`: signs that device out.
  Future<void> endSession(String sessionId);

  /// `POST /v1/me/sessions/revoke-others`: signs out every other device.
  Future<void> endOtherSessions();
}

/// The account itself (`docs/api-play.md`, "Account"): profile edits, feedback, deletion and
/// restore.
abstract interface class AccountRepository {
  /// `PATCH /v1/me` with the changed fields. A handle change is allowed once every 30 days:
  /// sooner, it fails with code `HANDLE_CHANGE_TOO_SOON` and `details.next_change_at`.
  Future<Me> updateProfile(ProfilePatch patch);

  /// `POST /v1/feedback` → 202.
  Future<void> sendFeedback({
    required FeedbackKind kind,
    required String message,
    required String idempotencyKey,
    String? requestId,
  });

  /// `POST /v1/me/delete` with `{"confirm": "DELETE", "proof": {...}}` → 202. Every session
  /// ends, this one included.
  Future<void> deleteAccount(SignInProof proof);

  /// `POST /v1/me/restore`, within 7 days of a delete. Returns the restored profile when the
  /// server sends it back, or null when it answers without a body.
  Future<Me?> restore();
}

class ApiSettingsRepository implements SettingsRepository {
  ApiSettingsRepository(this._api);

  final ApiClient _api;

  static const _notifications = '/v1/me/settings/notifications';
  static const _privacy = '/v1/me/settings/privacy';
  static const _app = '/v1/me/settings/app';

  @override
  Future<NotificationSettings> notifications() async {
    final data = await _api.get(_notifications);
    return parseResponse(() => NotificationSettings.fromJson(data));
  }

  @override
  Future<NotificationSettings> saveNotifications(NotificationSettings settings) async {
    final data = await _api.put(_notifications, body: settings.toJson());
    return data is Map ? parseResponse(() => NotificationSettings.fromJson(data)) : settings;
  }

  @override
  Future<PrivacySettings> privacy() async {
    final data = await _api.get(_privacy);
    return parseResponse(() => PrivacySettings.fromJson(data));
  }

  @override
  Future<PrivacySettings> savePrivacy(PrivacySettings settings) async {
    final data = await _api.put(_privacy, body: settings.toJson());
    return data is Map ? parseResponse(() => PrivacySettings.fromJson(data)) : settings;
  }

  @override
  Future<AppSettings> app() async {
    final data = await _api.get(_app);
    return parseResponse(() => AppSettings.fromJson(data));
  }

  @override
  Future<AppSettings> saveApp(AppSettings settings) async {
    final data = await _api.put(_app, body: settings.toJson());
    return data is Map ? parseResponse(() => AppSettings.fromJson(data)) : settings;
  }

  @override
  Future<List<DeviceSession>> sessions() async {
    final data = await _api.get('/v1/me/sessions');
    return parseResponse(() {
      if (data is! List) throw const FormatException('sessions: expected a list');
      return List<DeviceSession>.unmodifiable(data.map(DeviceSession.fromJson));
    });
  }

  @override
  Future<void> endSession(String sessionId) =>
      _api.delete('/v1/me/sessions/${Uri.encodeComponent(sessionId)}');

  @override
  Future<void> endOtherSessions() => _api.post('/v1/me/sessions/revoke-others');
}

class ApiAccountRepository implements AccountRepository {
  ApiAccountRepository(this._api);

  final ApiClient _api;

  @override
  Future<Me> updateProfile(ProfilePatch patch) async {
    final data = await _api.patch('/v1/me', body: patch.toJson());
    return parseResponse(() => Me.fromJson(data));
  }

  @override
  Future<void> sendFeedback({
    required FeedbackKind kind,
    required String message,
    required String idempotencyKey,
    String? requestId,
  }) => _api.post(
    '/v1/feedback',
    body: {'kind': kind.wire, 'message': message, 'request_id': ?requestId},
    idempotencyKey: idempotencyKey,
  );

  @override
  Future<void> deleteAccount(SignInProof proof) =>
      _api.post('/v1/me/delete', body: {'confirm': 'DELETE', 'proof': proof.toJson()});

  @override
  Future<Me?> restore() async {
    final data = await _api.post('/v1/me/restore');
    if (data is! Map) return null;
    try {
      return Me.fromJson(data);
    } on FormatException catch (e) {
      debugPrint('Restore answered with an unreadable profile: $e');
      return null;
    }
  }
}

/// Server settings in the debug "Demo data" mode.
final demoSettingsRepositoryProvider = Provider<FakeSettingsRepository>(
  (ref) => FakeSettingsRepository(latency: const Duration(milliseconds: 300)),
);

final settingsRepositoryProvider = Provider<SettingsRepository>((ref) {
  // The constant keeps the demo out of release builds entirely.
  if (!kReleaseMode && ref.watch(demoDataProvider)) {
    return ref.watch(demoSettingsRepositoryProvider);
  }
  return ApiSettingsRepository(ref.watch(apiClientProvider));
});

/// The account API. Not faked in the demo: profile edits and deletion are real either way.
final accountRepositoryProvider = Provider<AccountRepository>(
  (ref) => ApiAccountRepository(ref.watch(apiClientProvider)),
);

/// The last failed request's id, attached to problem reports.
final lastErrorRequestIdProvider = Provider<String? Function()>((ref) {
  final api = ref.watch(apiClientProvider);
  return () => api.lastErrorRequestId;
});
