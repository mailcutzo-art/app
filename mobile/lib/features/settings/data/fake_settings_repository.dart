import '../../../core/auth/user.dart';
import '../../../core/network/app_failure.dart';
import 'settings_models.dart';
import 'settings_repository.dart';

/// Calls of [FakeSettingsRepository] and [FakeAccountRepository] that tests can make fail.
enum FakeSettingsOp {
  notifications,
  saveNotifications,
  privacy,
  savePrivacy,
  app,
  saveApp,
  sessions,
  endSession,
  updateProfile,
  feedback,
  delete,
  restore,
}

mixin _Failing {
  Duration get latency;
  Map<FakeSettingsOp, AppFailure> get failures;

  Future<void> wait(FakeSettingsOp op) async {
    if (latency > Duration.zero) await Future<void>.delayed(latency);
    if (failures[op] case final failure?) throw failure;
  }
}

/// In-memory server settings and devices, for tests and the debug "Demo data" mode.
class FakeSettingsRepository with _Failing implements SettingsRepository {
  FakeSettingsRepository({
    this.notificationSettings = const NotificationSettings(),
    this.privacySettings = const PrivacySettings(),
    this.appSettings = const AppSettings(),
    List<DeviceSession>? devices,
    this.latency = Duration.zero,
  }) : devices = devices ?? sampleDevices(DateTime.now());

  NotificationSettings notificationSettings;
  PrivacySettings privacySettings;
  AppSettings appSettings;
  List<DeviceSession> devices;

  @override
  Duration latency;

  @override
  final Map<FakeSettingsOp, AppFailure> failures = {};

  /// Bodies saved, in order.
  final List<Map<String, Object?>> saved = [];

  /// Session ids signed out, in order.
  final List<String> ended = [];
  int endOthersCalls = 0;

  @override
  Future<NotificationSettings> notifications() async {
    await wait(FakeSettingsOp.notifications);
    return notificationSettings;
  }

  @override
  Future<NotificationSettings> saveNotifications(NotificationSettings settings) async {
    saved.add(settings.toJson());
    await wait(FakeSettingsOp.saveNotifications);
    return notificationSettings = settings;
  }

  @override
  Future<PrivacySettings> privacy() async {
    await wait(FakeSettingsOp.privacy);
    return privacySettings;
  }

  @override
  Future<PrivacySettings> savePrivacy(PrivacySettings settings) async {
    saved.add(settings.toJson());
    await wait(FakeSettingsOp.savePrivacy);
    return privacySettings = settings;
  }

  @override
  Future<AppSettings> app() async {
    await wait(FakeSettingsOp.app);
    return appSettings;
  }

  @override
  Future<AppSettings> saveApp(AppSettings settings) async {
    saved.add(settings.toJson());
    await wait(FakeSettingsOp.saveApp);
    return appSettings = settings;
  }

  @override
  Future<List<DeviceSession>> sessions() async {
    await wait(FakeSettingsOp.sessions);
    return List.unmodifiable(devices);
  }

  @override
  Future<void> endSession(String sessionId) async {
    ended.add(sessionId);
    await wait(FakeSettingsOp.endSession);
    devices = [
      for (final d in devices)
        if (d.id != sessionId) d,
    ];
  }

  @override
  Future<void> endOtherSessions() async {
    endOthersCalls++;
    await wait(FakeSettingsOp.endSession);
    devices = [
      for (final d in devices)
        if (d.current) d,
    ];
  }
}

/// This phone and one other.
List<DeviceSession> sampleDevices(DateTime now) => [
  DeviceSession(
    id: 's-this',
    platform: 'android',
    appVersion: '1.0.0',
    createdAt: now.subtract(const Duration(days: 12)),
    lastSeenAt: now,
    current: true,
  ),
  DeviceSession(
    id: 's-tablet',
    platform: 'android',
    appVersion: '0.9.4',
    createdAt: now.subtract(const Duration(days: 40)),
    lastSeenAt: now.subtract(const Duration(days: 3)),
  ),
];

/// In-memory account API for tests: applies profile edits to [me].
class FakeAccountRepository with _Failing implements AccountRepository {
  FakeAccountRepository(this.me, {this.latency = Duration.zero});

  Me me;

  @override
  Duration latency;

  @override
  final Map<FakeSettingsOp, AppFailure> failures = {};

  final List<Map<String, Object?>> patches = [];
  final List<Map<String, Object?>> feedback = [];
  final List<SignInProof> deletions = [];
  int restoreCalls = 0;

  /// What `restore` answers with; null is a body-less answer.
  Me? restored;

  @override
  Future<Me> updateProfile(ProfilePatch patch) async {
    patches.add(patch.toJson());
    await wait(FakeSettingsOp.updateProfile);
    return me = me.copyWith(
      displayName: patch.displayName,
      handle: patch.handle,
      avatar: patch.avatar,
      goal: patch.goal,
    );
  }

  @override
  Future<void> sendFeedback({
    required FeedbackKind kind,
    required String message,
    required String idempotencyKey,
    String? requestId,
  }) async {
    feedback.add({
      'kind': kind.wire,
      'message': message,
      'request_id': requestId,
      'idempotency_key': idempotencyKey,
    });
    await wait(FakeSettingsOp.feedback);
  }

  @override
  Future<void> deleteAccount(SignInProof proof) async {
    deletions.add(proof);
    await wait(FakeSettingsOp.delete);
  }

  @override
  Future<Me?> restore() async {
    restoreCalls++;
    await wait(FakeSettingsOp.restore);
    return restored;
  }
}
