import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_app/core/config/app_config.dart';
import 'package:quiz_app/core/network/api_client.dart';
import 'package:quiz_app/core/network/server_signals.dart';
import 'package:quiz_app/features/debug/debug_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fakes.dart';

void main() {
  group('AppConfig.fromJson', () {
    test('reads every field', () {
      final config = AppConfig.fromJson(const {
        'min_build': 12,
        'maintenance': true,
        'maintenance_message': '  Back soon.  ',
        'features': {'tournaments': true, 'words': false},
        'server_time': '2026-09-27T16:00:00Z',
      });
      expect(config.minBuild, 12);
      expect(config.maintenance, isTrue);
      expect(config.maintenanceMessage, 'Back soon.');
      expect(config.feature('tournaments'), isTrue);
      expect(config.feature('words'), isFalse);
      expect(config.feature('unknown'), isFalse);
    });

    test('tolerates missing optional fields and odd flags', () {
      final config = AppConfig.fromJson(const {
        'min_build': 1,
        'maintenance': false,
        'maintenance_message': ' ',
        'features': {'a': 'yes', 'b': true},
      });
      expect(config.maintenanceMessage, isNull);
      expect(config.features, {'b': true});
    });

    test('rejects a response without the required fields', () {
      expect(() => AppConfig.fromJson(const {'maintenance': false}), throwsFormatException);
      expect(() => AppConfig.fromJson('nope'), throwsFormatException);
    });

    test('round-trips through its cache format', () {
      const config = AppConfig(minBuild: 3, maintenanceMessage: 'x', features: {'f': true});
      expect(AppConfig.fromJson(config.toJson()), config);
    });
  });

  group('decideGate', () {
    const none = ServerSignals();

    test('open by default, and while the config is unknown', () {
      expect(decideGate(signals: none, build: 7), AppGate.open);
      expect(
        decideGate(signals: none, config: const AppConfig(minBuild: 5), build: 7),
        AppGate.open,
      );
    });

    test('an older build must update; an unknown build number never blocks', () {
      const config = AppConfig(minBuild: 8);
      expect(decideGate(signals: none, config: config, build: 7), AppGate.updateRequired);
      expect(decideGate(signals: none, config: config, build: 8), AppGate.open);
      expect(decideGate(signals: none, config: config, build: 0), AppGate.open);
    });

    test('maintenance comes from the config or a 503 signal', () {
      expect(
        decideGate(signals: none, config: const AppConfig(maintenance: true), build: 1),
        AppGate.maintenance,
      );
      expect(
        decideGate(signals: const ServerSignals(maintenance: true), build: 1),
        AppGate.maintenance,
      );
    });

    test('an update beats maintenance', () {
      expect(
        decideGate(signals: const ServerSignals(updateRequired: true, maintenance: true), build: 1),
        AppGate.updateRequired,
      );
    });
  });

  group('ConfigController', () {
    late SharedPreferences prefs;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
    });

    ProviderContainer containerWith(FakeAdapter adapter) {
      final dio = Dio(BaseOptions(baseUrl: 'http://api.test'))..httpClientAdapter = adapter;
      final container = ProviderContainer(
        overrides: [
          sharedPrefsProvider.overrideWithValue(prefs),
          apiClientProvider.overrideWithValue(ApiClient(dio)),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('loads the config without auth and caches it', () async {
      final adapter = FakeAdapter((_) => jsonBody({'min_build': 4, 'maintenance': false}));
      final container = containerWith(adapter);
      final config = await container.read(configProvider.future);
      expect(config.minBuild, 4);
      expect(adapter.requests.single.path, '/v1/config');
      expect(adapter.requests.single.headers.containsKey('Authorization'), isFalse);
      expect(prefs.getString('config.last'), contains('"min_build":4'));
    });

    test('offline, it falls back to the cached config', () async {
      await prefs.setString('config.last', '{"min_build":9,"maintenance":false}');
      final container = containerWith(
        FakeAdapter(
          (options) =>
              throw DioException.connectionError(requestOptions: options, reason: 'offline'),
        ),
      );
      expect((await container.read(configProvider.future)).minBuild, 9);
    });

    test('offline with nothing cached, it never blocks the app', () async {
      final container = containerWith(
        FakeAdapter(
          (options) =>
              throw DioException.connectionError(requestOptions: options, reason: 'offline'),
        ),
      );
      expect(await container.read(configProvider.future), const AppConfig());
    });

    test('only a fresh answer ends a maintenance signal', () async {
      var online = false;
      final container = containerWith(
        FakeAdapter((options) {
          if (!online) {
            throw DioException.connectionError(requestOptions: options, reason: 'offline');
          }
          return jsonBody({'min_build': 1, 'maintenance': false});
        }),
      );
      await container.read(configProvider.future);
      container.read(serverSignalsProvider.notifier).maintenance();

      await container.read(configProvider.notifier).recheck();
      expect(container.read(serverSignalsProvider).maintenance, isTrue);

      online = true;
      await container.read(configProvider.notifier).recheck();
      expect(container.read(serverSignalsProvider).maintenance, isFalse);
    });
  });

  group('ServerSignalInterceptor', () {
    Future<(bool, bool)> send(ResponseBody Function() response) async {
      var update = false;
      var maintenance = false;
      final dio = Dio(BaseOptions(baseUrl: 'http://api.test'))
        ..httpClientAdapter = FakeAdapter((_) => response())
        ..interceptors.add(
          ServerSignalInterceptor(
            onUpdateRequired: () => update = true,
            onMaintenance: () => maintenance = true,
          ),
        );
      await expectLater(dio.get<Object?>('/v1/anything'), throwsA(isA<DioException>()));
      return (update, maintenance);
    }

    test('426 means this build must update', () async {
      expect(await send(() => jsonBody({}, status: 426)), (true, false));
    });

    test('503 MAINTENANCE starts maintenance; other errors do nothing', () async {
      final envelope = {
        'error': {'code': 'MAINTENANCE', 'message': 'Maintenance', 'request_id': 'r'},
      };
      expect(await send(() => jsonBody(envelope, status: 503)), (false, true));
      expect(await send(() => jsonBody({}, status: 503)), (false, false));
      expect(await send(() => jsonBody({}, status: 500)), (false, false));
    });
  });
}
