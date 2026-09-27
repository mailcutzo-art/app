import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_app/core/auth/token_store.dart';
import 'package:quiz_app/core/network/api_client.dart';
import 'package:quiz_app/core/network/app_failure.dart';

import '../support/fakes.dart';

void main() {
  late TokenStore tokens;
  late int expiredSignals;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    tokens = TokenStore(const FlutterSecureStorage());
    expiredSignals = 0;
  });

  /// API client whose server accepts only `Bearer fresh`, and whose refresh
  /// endpoint answers with [refreshStatus].
  (ApiClient, FakeAdapter) build({int refreshStatus = 200}) {
    var refreshCount = 0;
    final adapter = FakeAdapter((options) async {
      if (options.path == '/v1/auth/refresh') {
        refreshCount++;
        await Future<void>.delayed(const Duration(milliseconds: 10));
        if (refreshStatus != 200) return jsonBody(null, status: refreshStatus);
        return jsonBody({
          'access_token': 'fresh',
          'access_expires_in': 900,
          'refresh_token': 'refresh-$refreshCount',
        });
      }
      final auth = options.headers['Authorization'];
      if (auth != 'Bearer fresh') {
        return jsonBody(<String, Object?>{'error': <String, Object?>{}}, status: 401);
      }
      return jsonBody({'ok': options.path});
    });
    final plain = Dio(BaseOptions(baseUrl: 'http://api.test'))..httpClientAdapter = adapter;
    final dio = Dio(BaseOptions(baseUrl: 'http://api.test'))
      ..httpClientAdapter = adapter
      ..interceptors.add(
        AuthInterceptor(
          tokens: tokens,
          refreshDio: plain,
          retryDio: plain,
          onSessionExpired: () => expiredSignals++,
        ),
      );
    return (ApiClient(dio), adapter);
  }

  test('an expiring access token is refreshed before the request', () async {
    await tokens.save(accessToken: 'old', accessTtl: Duration.zero, refreshToken: 'r0');
    final (api, adapter) = build();

    expect(await api.get('/v1/me'), {'ok': '/v1/me'});
    expect(adapter.requests.map((r) => r.path), ['/v1/auth/refresh', '/v1/me']);
    expect(await tokens.readRefreshToken(), 'refresh-1', reason: 'rotated token stored');
  });

  test('a 401 triggers one refresh and a retry', () async {
    await tokens.save(
      accessToken: 'stale',
      accessTtl: const Duration(hours: 1),
      refreshToken: 'r0',
    );
    final (api, adapter) = build();

    expect(await api.get('/v1/me'), {'ok': '/v1/me'});
    expect(adapter.requests.map((r) => r.path), ['/v1/me', '/v1/auth/refresh', '/v1/me']);
  });

  test('concurrent 401s share a single refresh', () async {
    await tokens.save(
      accessToken: 'stale',
      accessTtl: const Duration(hours: 1),
      refreshToken: 'r0',
    );
    final (api, adapter) = build();

    final results = await Future.wait([api.get('/a'), api.get('/b'), api.get('/c')]);
    expect(results, [
      {'ok': '/a'},
      {'ok': '/b'},
      {'ok': '/c'},
    ]);
    expect(adapter.requests.where((r) => r.path == '/v1/auth/refresh'), hasLength(1));
  });

  test('a rejected refresh token ends the session', () async {
    await tokens.save(accessToken: 'old', accessTtl: Duration.zero, refreshToken: 'r0');
    final (api, _) = build(refreshStatus: 401);

    await expectLater(api.get('/v1/me'), throwsA(isA<UnauthorizedFailure>()));
    expect(await tokens.readRefreshToken(), isNull);
    expect(expiredSignals, 1);
  });

  test('requests marked auth: false never carry a token', () async {
    await tokens.save(
      accessToken: 'fresh',
      accessTtl: const Duration(hours: 1),
      refreshToken: 'r0',
    );
    final (api, adapter) = build();

    await expectLater(
      api.post('/v1/auth/google', body: {}, auth: false),
      throwsA(isA<UnauthorizedFailure>()),
    );
    expect(adapter.requests.single.headers['Authorization'], isNull);
  });
}
