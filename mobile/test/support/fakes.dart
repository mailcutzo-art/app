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
import 'package:quiz_app/core/network/api_client.dart';
import 'package:quiz_app/core/network/connectivity.dart';
import 'package:quiz_app/core/storage/prefs.dart';
import 'package:quiz_app/features/learn/data/fake_learn_repository.dart';
import 'package:quiz_app/features/learn/data/learn_repository.dart';
import 'package:quiz_app/features/onboarding/onboarding_repository.dart';
import 'package:quiz_app/features/practice/practice_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

/// Everything the app reads at startup, faked. [learn] defaults to the
/// sample data and [online] to a device that stays online.
List<Override> testOverrides({
  required Session session,
  required SharedPreferences prefs,
  LearnRepository? learn,
  Stream<bool>? online,
}) => [
  appEnvProvider.overrideWithValue(testEnv),
  sessionProvider.overrideWith(() => FakeSessionController(session)),
  onboardingRepositoryProvider.overrideWithValue(FakeOnboardingRepository()),
  sharedPrefsProvider.overrideWithValue(prefs),
  learnRepositoryProvider.overrideWithValue(learn ?? FakeLearnRepository.seeded()),
  connectivityProvider.overrideWith((ref) => online ?? Stream.value(true)),
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
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ...testOverrides(session: SignedIn(fakeUser()), prefs: prefs, learn: learn, online: online),
        if (stopwatch != null) practiceStopwatchProvider.overrideWithValue(stopwatch),
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
