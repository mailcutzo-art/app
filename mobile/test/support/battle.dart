import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_app/app/router.dart';
import 'package:quiz_app/features/battle/data/fake_battle_repository.dart';
import 'package:quiz_app/features/battle/demo/demo_providers.dart';
import 'package:quiz_app/features/battle/demo/demo_server.dart';
import 'package:quiz_app/features/battle/demo/demo_world.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes.dart';
import 'rt_server.dart';

/// Moves fake time forward by [total] in [step]s, so timers, stream events and frames
/// interleave as they would on a phone.
Future<void> advance(
  WidgetTester tester,
  Duration total, {
  Duration step = const Duration(milliseconds: 100),
}) async {
  var left = total;
  while (left > Duration.zero) {
    final next = left < step ? left : step;
    await tester.pump(next);
    left -= next;
  }
}

/// Pumps until [finder] finds something, for at most [timeout] of fake time.
Future<void> pumpUntil(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 30),
  Duration step = const Duration(milliseconds: 100),
}) async {
  var waited = Duration.zero;
  while (finder.evaluate().isEmpty) {
    if (waited >= timeout) fail('Nothing matched $finder after ${timeout.inSeconds} s');
    await tester.pump(step);
    waited += step;
  }
}

/// Turns on the OS "reduce motion" setting, so pulses and rings don't keep animating.
void reduceMotion(WidgetTester tester) {
  tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(
    disableAnimations: true,
  );
  addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
}

/// A demo server playing as the test user (`u1`), quick to answer.
DemoRealtimeServer demoServer({int seed = 3}) => DemoRealtimeServer(
  me: const DemoPlayer(uid: 'u1', name: 'Aarav', handle: 'aarav'),
  seed: seed,
)..latency = const Duration(milliseconds: 10);

/// Pumps the app signed in, talking to [server] for everything live and for match results.
Future<ProviderContainer> pumpDemo(
  WidgetTester tester,
  DemoRealtimeServer server, {
  SharedPreferences? prefs,
  String location = Routes.battle,
  FakeScreenGuard? screenGuard,
}) async {
  final container = await pumpApp(
    tester,
    prefs: prefs ?? await testPrefs(),
    realtime: server,
    battle: FakeBattleRepository(setup: server.world.setup),
    matches: DemoMatchRepository(server, latency: Duration.zero),
    screenGuard: screenGuard,
    location: location,
    settle: false,
  );
  await advance(tester, const Duration(milliseconds: 500));
  return container;
}

/// The top-most route, pushed or not.
String location(ProviderContainer container) => container.read(routerProvider).state.uri.toString();
