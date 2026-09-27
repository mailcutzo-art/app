import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_app/app/env.dart';
import 'package:quiz_app/core/auth/session.dart';
import 'package:quiz_app/core/device/app_build.dart';
import 'package:quiz_app/core/network/api_client.dart';
import 'package:quiz_app/core/network/app_failure.dart';
import 'package:quiz_app/core/realtime/realtime_providers.dart';
import 'package:quiz_app/core/storage/prefs.dart';
import 'package:quiz_app/features/battle/data/battle_repository.dart';
import 'package:quiz_app/features/battle/data/fake_battle_repository.dart';
import 'package:quiz_app/features/battle/demo/demo_providers.dart';
import 'package:quiz_app/features/battle/demo/demo_server.dart';
import 'package:quiz_app/features/learn/data/learn_repository.dart';
import 'package:realtime_client/realtime_client.dart';

import '../../support/fakes.dart';
import '../../support/rt_server.dart';

void main() {
  group('realtimeUri', () {
    test('http becomes ws and https becomes wss, with /v1/ws appended', () {
      expect(realtimeUri('http://10.0.2.2:8000').toString(), 'ws://10.0.2.2:8000/v1/ws');
      expect(realtimeUri('https://api.quiz.app').toString(), 'wss://api.quiz.app/v1/ws');
    });

    test('keeps a path prefix, drops a trailing slash, a query and a fragment', () {
      expect(realtimeUri('https://quiz.app/api/').toString(), 'wss://quiz.app/api/v1/ws');
      expect(realtimeUri('https://quiz.app?x=1#top').toString(), 'wss://quiz.app/v1/ws');
    });
  });

  test('realtimePlatform names the platform hello reports', () {
    expect(realtimePlatform(isWeb: true), 'web');
    expect(realtimePlatform(isWeb: false, platform: TargetPlatform.android), 'android');
    expect(realtimePlatform(isWeb: false, platform: TargetPlatform.iOS), 'ios');
    expect(realtimePlatform(isWeb: false, platform: TargetPlatform.macOS), 'macOS');
  });

  group('the connection', () {
    Future<ProviderContainer> container({Session? session, bool demo = false}) async {
      final prefs = await testPrefs({if (demo) DemoDataSetting.prefKey: true});
      final c = ProviderContainer(
        overrides: [...testOverrides(session: session ?? SignedIn(fakeUser()), prefs: prefs)],
      );
      addTearDown(c.dispose);
      await c.read(sessionProvider.future);
      await c.read(appBuildProvider.future);
      return c;
    }

    test('exists only while someone is signed in', () async {
      final c = await container(session: const SignedOut());
      expect(c.read(realtimeConnectionProvider), isNull);
    });

    test('is made once, for the signed-in user, and goes when they sign out', () async {
      final c = await container();
      final connection = c.read(realtimeConnectionProvider);
      expect(connection, isNotNull);
      expect(connection!.build, 1);
      expect(connection.platform, realtimePlatform());
      expect(c.read(realtimeConnectionProvider), same(connection));

      await c.read(sessionProvider.notifier).signOut();
      expect(c.read(realtimeConnectionProvider), isNull);
      // Disposed: a lease on it is released at once.
      expect(connection.acquire('late').isReleased, isTrue);
    });
  });

  group('tickets', () {
    ProviderContainer withApi(Object? Function(RequestOptions options) respond) {
      final adapter = FakeAdapter((options) async {
        final body = respond(options);
        return body is ResponseBody ? body : jsonBody(body);
      });
      final c = ProviderContainer(
        overrides: [
          appEnvProvider.overrideWithValue(testEnv),
          apiClientProvider.overrideWithValue(
            ApiClient(Dio(BaseOptions(baseUrl: 'http://api.test'))..httpClientAdapter = adapter),
          ),
          demoDataProvider.overrideWith(_DemoOff.new),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    test('come from POST /v1/rt/tickets', () async {
      String? path;
      String? method;
      final c = withApi((options) {
        path = options.path;
        method = options.method;
        return {'ticket': 'q3Jd', 'expires_in': 30};
      });
      expect(await c.read(realtimeTicketsProvider)(), 'q3Jd');
      expect(path, '/v1/rt/tickets');
      expect(method, 'POST');
    });

    test('a reply without a ticket is a failure the connection backs off from', () async {
      final c = withApi((_) => {'expires_in': 30});
      await expectLater(c.read(realtimeTicketsProvider)(), throwsA(isA<UnexpectedFailure>()));
    });
  });

  group('the Demo data switch', () {
    test('serves battles and the live connection from the in-app demo server', () async {
      final prefs = await testPrefs({DemoDataSetting.prefKey: true});
      final c = ProviderContainer(
        overrides: [
          appEnvProvider.overrideWithValue(testEnv),
          sharedPrefsProvider.overrideWithValue(prefs),
          sessionProvider.overrideWith(() => FakeSessionController(SignedIn(fakeUser()))),
        ],
      );
      addTearDown(c.dispose);
      await c.read(sessionProvider.future);
      expect(c.read(realtimeConnectorProvider), isA<DemoRealtimeServer>());
      expect(await c.read(realtimeTicketsProvider)(), 'demo-ticket');
      expect(c.read(battleRepositoryProvider), isA<FakeBattleRepository>());
      expect(c.read(matchRepositoryProvider), isA<DemoMatchRepository>());
      expect(c.read(demoRealtimeServerProvider).me.uid, 'u1');
    });

    test('is ignored outside dev builds', () async {
      final prefs = await testPrefs({DemoDataSetting.prefKey: true});
      final c = ProviderContainer(
        overrides: [
          appEnvProvider.overrideWithValue(
            const AppEnv(
              flavor: Flavor.prod,
              apiBaseUrl: 'https://api.test',
              googleServerClientId: '',
            ),
          ),
          sharedPrefsProvider.overrideWithValue(prefs),
          sessionProvider.overrideWith(() => FakeSessionController(SignedIn(fakeUser()))),
        ],
      );
      addTearDown(c.dispose);
      final connector = c.read(realtimeConnectorProvider);
      expect(connector, isA<WebSocketChannelConnector>());
      expect((connector as WebSocketChannelConnector).uri.toString(), 'wss://api.test/v1/ws');
      expect(c.read(battleRepositoryProvider), isA<ApiBattleRepository>());
      expect(c.read(matchRepositoryProvider), isA<ApiMatchRepository>());
    });
  });

  test('the test server answers hello and clock pings', () async {
    // Keeps the shared test server honest; everything else builds on it.
    final server = TestRealtimeServer();
    final socket = await server.connect() as TestSocket;
    final frames = <Object?>[];
    socket.frames.listen(frames.add);
    socket.send('{"v":1,"t":"hello","id":"c1","d":{"ticket":"t"}}');
    await Future<void>.delayed(Duration.zero);
    expect(frames.single, contains('"welcome"'));
    await socket.close();
  });
}

class _DemoOff extends DemoDataSetting {
  @override
  bool build() => false;
}
