import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_app/app/app.dart';
import 'package:quiz_app/app/env.dart';
import 'package:quiz_app/app/router.dart';
import 'package:quiz_app/core/auth/session.dart';
import 'package:quiz_app/core/auth/user.dart';
import 'package:quiz_app/core/config/app_config.dart';
import 'package:quiz_app/core/network/api_client.dart';
import 'package:quiz_app/core/network/connectivity.dart';
import 'package:quiz_app/core/notifications/local_reminders.dart';
import 'package:quiz_app/core/realtime/realtime_providers.dart';
import 'package:quiz_app/core/storage/prefs.dart';
import 'package:quiz_app/features/arena/data/fake_tournament_repository.dart';
import 'package:quiz_app/features/arena/data/tournament_repository.dart';
import 'package:quiz_app/features/battle/data/battle_repository.dart';
import 'package:quiz_app/features/battle/data/fake_battle_repository.dart';
import 'package:quiz_app/features/battle/demo/demo_server.dart';
import 'package:quiz_app/features/battle/match/screen_guard.dart';
import 'package:quiz_app/features/inbox/data/fake_inbox_repository.dart';
import 'package:quiz_app/features/inbox/data/inbox_repository.dart';
import 'package:quiz_app/features/leaderboards/data/fake_leaderboard_repository.dart';
import 'package:quiz_app/features/leaderboards/data/leaderboard_models.dart' show PlayerCard;
import 'package:quiz_app/features/leaderboards/data/leaderboard_repository.dart';
import 'package:quiz_app/features/learn/data/fake_learn_repository.dart';
import 'package:quiz_app/features/learn/data/learn_repository.dart';
import 'package:quiz_app/features/missions/data/fake_missions_repository.dart';
import 'package:quiz_app/features/missions/data/missions_repository.dart';
import 'package:quiz_app/features/onboarding/onboarding_repository.dart';
import 'package:quiz_app/features/practice/practice_controller.dart';
import 'package:quiz_app/features/profile/data/fake_profile_repository.dart';
import 'package:quiz_app/features/profile/data/profile_repository.dart';
import 'package:quiz_app/features/rooms/data/fake_rooms_repository.dart';
import 'package:quiz_app/features/rooms/data/rooms_repository.dart';
import 'package:quiz_app/features/settings/data/fake_settings_repository.dart';
import 'package:quiz_app/features/settings/data/settings_repository.dart';
import 'package:quiz_app/features/social/data/fake_social_repository.dart';
import 'package:quiz_app/features/social/data/social_repository.dart';
import 'package:quiz_app/features/wallet/data/wallet_repository.dart';
import 'package:realtime_client/realtime_client.dart' hide PlayerCard;
import 'package:shared_preferences/shared_preferences.dart';

import 'rt_server.dart';

const testEnv = AppEnv(flavor: Flavor.dev, apiBaseUrl: 'http://api.test', googleServerClientId: '');

Me fakeUser({bool onboarded = true}) => Me(
  id: 'u1',
  displayName: 'Aarav Sharma',
  handle: onboarded ? 'aarav' : null,
  avatar: const Avatar(tone: 'lime', symbol: 'rocket'),
  goal: onboarded ? Goal.neet : null,
  birthYear: onboarded ? 2008 : null,
  isMinor: true,
  onboardingCompleted: onboarded,
);

/// Session controller that starts in a fixed state.
class FakeSessionController extends SessionController {
  FakeSessionController(this.initial);

  final Session initial;

  @override
  Future<Session> build() async => initial;

  @override
  Future<void> signOut() async => state = const AsyncData(SignedOut());
}

/// Like [FakeSessionController], and it also ends the session when the app is told it's over
/// (`sessionExpiredProvider`), as the real controller does.
class ExpiringSessionController extends FakeSessionController {
  ExpiringSessionController(super.initial);

  @override
  Future<Session> build() async {
    ref.listen(sessionExpiredProvider, (_, _) {
      final end = ref.read(sessionExpiredProvider.notifier).last;
      state = AsyncData(SignedOut(message: signedOutMessage(end.reason)));
    });
    return initial;
  }
}

/// Onboarding API stand-in: every well-formed handle is available.
class FakeOnboardingRepository extends OnboardingRepository {
  FakeOnboardingRepository() : super(ApiClient(Dio()));

  @override
  Future<HandleStatus> checkHandle(String handle) async =>
      handlePattern.hasMatch(handle) ? HandleStatus.available : HandleStatus.invalid;
}

/// Fresh in-memory shared preferences holding [values].
Future<SharedPreferences> testPrefs([Map<String, Object> values = const {}]) {
  SharedPreferences.setMockInitialValues(values);
  return SharedPreferences.getInstance();
}

/// Config stand-in: a fixed answer, no network.
class FakeConfigController extends ConfigController {
  FakeConfigController([this.config = const AppConfig()]);

  final AppConfig config;

  @override
  Future<AppConfig> build() async => config;

  @override
  Future<void> recheck() async {}
}

/// Everything the app reads at startup, faked. [learn] defaults to the
/// sample data, [online] to a device that stays online, and [config] and
/// [build] to an open app on a current build. The realtime connection talks
/// to [realtime] (a quiet [TestRealtimeServer] by default) on the test's fake
/// time, battles read [battle] and [matches], and the Social tab reads
/// [social] (the sample world by default).
List<Override> testOverrides({
  required Session session,
  required SharedPreferences prefs,
  LearnRepository? learn,
  Stream<bool>? online,
  AppConfig config = const AppConfig(),
  int build = 1,
  WebSocketConnector? realtime,
  BattleRepository? battle,
  MatchRepository? matches,
  ScreenGuard? screenGuard,
  SessionController Function()? sessionController,
  InboxRepository? inbox,
  WalletRepository? wallet,
  ProfileRepository? profile,
  SettingsRepository? settings,
  AccountRepository? account,
  SocialRepository? social,
  LeaderboardRepository? leaderboards,
  MissionsRepository? missions,
  TournamentRepository? arena,
  ReminderScheduler? reminders,
  CalendarExporter? calendar,
  RoomsRepository? rooms,
}) => [
  appEnvProvider.overrideWithValue(testEnv),
  sessionProvider.overrideWith(sessionController ?? () => FakeSessionController(session)),
  onboardingRepositoryProvider.overrideWithValue(FakeOnboardingRepository()),
  sharedPrefsProvider.overrideWithValue(prefs),
  learnRepositoryProvider.overrideWithValue(learn ?? FakeLearnRepository.seeded()),
  connectivityProvider.overrideWith((ref) => online ?? Stream.value(true)),
  configProvider.overrideWith(() => FakeConfigController(config)),
  appBuildProvider.overrideWith((ref) async => build),
  realtimeConnectorProvider.overrideWith((ref) {
    final connector = realtime ?? TestRealtimeServer();
    // The demo server's timers stop with the widget tree, before the test checks for timers.
    if (connector is DemoRealtimeServer) ref.onDispose(connector.dispose);
    return connector;
  }),
  realtimeTicketsProvider.overrideWithValue(() async => 'test-ticket'),
  realtimeClockProvider.overrideWithValue(ClockRealtimeClock()),
  realtimeLogProvider.overrideWithValue(null),
  battleRepositoryProvider.overrideWithValue(battle ?? FakeBattleRepository()),
  matchRepositoryProvider.overrideWithValue(matches ?? FakeMatchRepository()),
  screenGuardProvider.overrideWithValue(screenGuard ?? FakeScreenGuard()),
  inboxRepositoryProvider.overrideWithValue(inbox ?? FakeInboxRepository()),
  walletRepositoryProvider.overrideWithValue(wallet ?? FakeWalletRepository()),
  profileRepositoryProvider.overrideWithValue(profile ?? FakeProfileRepository()),
  settingsRepositoryProvider.overrideWithValue(settings ?? FakeSettingsRepository()),
  accountRepositoryProvider.overrideWithValue(account ?? FakeAccountRepository(fakeUser())),
  socialRepositoryProvider.overrideWithValue(social ?? FakeSocialRepository.seeded()),
  leaderboardRepositoryProvider.overrideWithValue(
    leaderboards ?? FakeLeaderboardRepository.seeded(me: fakeUser()),
  ),
  missionsRepositoryProvider.overrideWithValue(missions ?? FakeMissionsRepository.seeded()),
  tournamentRepositoryProvider.overrideWithValue(
    arena ??
        FakeTournamentRepository(
          me: const PlayerCard(id: 'u1', displayName: 'Aarav'),
        ),
  ),
  reminderSchedulerProvider.overrideWithValue(reminders ?? MemoryReminderScheduler()),
  calendarExporterProvider.overrideWithValue(calendar ?? MemoryCalendarExporter()),
  roomsRepositoryProvider.overrideWithValue(rooms ?? FakeRoomsRepository()),
];

/// A phone-sized, tall viewport so screens need little scrolling.
void usePhoneViewport(WidgetTester tester, {double height = 1000}) {
  tester.view
    ..physicalSize = Size(400 * 3, height * 3)
    ..devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

/// Pumps the whole app signed in (and onboarded), opens [location], and
/// returns the provider container.
Future<ProviderContainer> pumpApp(
  WidgetTester tester, {
  required SharedPreferences prefs,
  LearnRepository? learn,
  Stream<bool>? online,
  Stopwatch Function()? stopwatch,
  String location = Routes.home,
  bool settle = true,
  WebSocketConnector? realtime,
  BattleRepository? battle,
  MatchRepository? matches,
  ScreenGuard? screenGuard,
  SessionController Function()? sessionController,
  InboxRepository? inbox,
  WalletRepository? wallet,
  ProfileRepository? profile,
  SettingsRepository? settings,
  AccountRepository? account,
  SocialRepository? social,
  LeaderboardRepository? leaderboards,
  MissionsRepository? missions,
  TournamentRepository? arena,
  ReminderScheduler? reminders,
  CalendarExporter? calendar,
  RoomsRepository? rooms,
  List<Override> overrides = const [],
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ...testOverrides(
          session: SignedIn(fakeUser()),
          prefs: prefs,
          learn: learn,
          online: online,
          realtime: realtime,
          battle: battle,
          matches: matches,
          screenGuard: screenGuard,
          sessionController: sessionController,
          inbox: inbox,
          wallet: wallet,
          profile: profile,
          settings: settings,
          account: account,
          social: social,
          leaderboards: leaderboards,
          missions: missions,
          arena: arena,
          reminders: reminders,
          calendar: calendar,
          rooms: rooms,
        ),
        if (stopwatch != null) practiceStopwatchProvider.overrideWithValue(stopwatch),
        ...overrides,
      ],
      child: const QuizApp(),
    ),
  );
  await tester.pump();
  final container = ProviderScope.containerOf(tester.element(find.byType(QuizApp)));
  container.read(routerProvider).go(location);
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
  return container;
}

/// A stopwatch whose time only moves when a test says so (and only while
/// it's running), so timing is deterministic.
class FakeStopwatch implements Stopwatch {
  Duration _elapsed = Duration.zero;
  bool _running = false;

  /// Moves time forward by [by] if the stopwatch is running.
  void advance(Duration by) {
    if (_running) _elapsed += by;
  }

  @override
  int get frequency => 1000000;

  @override
  void start() => _running = true;

  @override
  void stop() => _running = false;

  @override
  void reset() => _elapsed = Duration.zero;

  @override
  bool get isRunning => _running;

  @override
  Duration get elapsed => _elapsed;

  @override
  int get elapsedTicks => _elapsed.inMicroseconds;

  @override
  int get elapsedMicroseconds => _elapsed.inMicroseconds;

  @override
  int get elapsedMilliseconds => _elapsed.inMilliseconds;
}

/// Scripted HTTP responses for Dio, recorded for assertions.
class FakeAdapter implements HttpClientAdapter {
  FakeAdapter(this.handler);

  final FutureOr<ResponseBody> Function(RequestOptions options) handler;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody jsonBody(Object? body, {int status = 200, Map<String, List<String>>? headers}) =>
    ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
        ...?headers,
      },
    );
