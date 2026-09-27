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
  late SessionEnd? lastEnd;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    tokens = TokenStore(const FlutterSecureStorage());
    expiredSignals = 0;
    lastEnd = null;
  });

  /// API client whose server accepts only `Bearer fresh`, and whose refresh
  /// endpoint answers with [refreshStatus] (and [refreshBody] when it fails).
  /// [rejectWith] replaces the 401 body sent for other tokens.
  (ApiClient, FakeAdapter) build({
    int refreshStatus = 200,
    Object? refreshBody,
    Object? rejectWith,
    int rejectStatus = 401,
  }) {
    var refreshCount = 0;
    final adapter = FakeAdapter((options) async {
      if (options.path == '/v1/auth/refresh') {
        refreshCount++;
        await Future<void>.delayed(const Duration(milliseconds: 10));
        if (refreshStatus != 200) return jsonBody(refreshBody, status: refreshStatus);
        return jsonBody({
          'access_token': 'fresh',
          'access_expires_in': 900,
          'refresh_token': 'refresh-$refreshCount',
        });
      }
      final auth = options.headers['Authorization'];
      if (auth != 'Bearer fresh') {
        return jsonBody(
          rejectWith ?? <String, Object?>{'error': <String, Object?>{}},
          status: rejectStatus,
        );
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
          onSessionExpired: (end) {
            expiredSignals++;
            lastEnd = end;
          },
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

  test('a revoked session says why it ended', () async {
    await tokens.save(
      accessToken: 'stale',
      accessTtl: const Duration(hours: 1),
      refreshToken: 'r0',
    );
    final (api, _) = build(
      refreshStatus: 401,
      rejectWith: {
        'error': {
          'code': 'SESSION_REVOKED',
          'message': 'You have been signed out.',
          'details': {'reason': 'signed_out'},
        },
      },
    );

    await expectLater(api.get('/v1/me'), throwsA(isA<UnauthorizedFailure>()));
    expect(expiredSignals, 1);
    expect(lastEnd?.reason, 'signed_out');
    expect(lastEnd?.ban, isNull);
  });

  test('a suspended account ends the session with the ban details', () async {
    await tokens.save(
      accessToken: 'stale',
      accessTtl: const Duration(hours: 1),
      refreshToken: 'r0',
    );
    final (api, _) = build(
      rejectStatus: 403,
      rejectWith: {
        'error': {
          'code': 'ACCOUNT_BANNED',
          'message': 'This account has been suspended.',
          'details': {'reason': 'cheating', 'until': null, 'appeal': 'appeals@example.com'},
        },
      },
    );

    await expectLater(api.get('/v1/me'), throwsA(isA<ForbiddenFailure>()));
    expect(expiredSignals, 1);
    expect(lastEnd?.ban, {'reason': 'cheating', 'until': null, 'appeal': 'appeals@example.com'});
    expect(await tokens.readRefreshToken(), isNull, reason: 'tokens are cleared');
  });

  test('the build number goes out with every request once known', () async {
    final adapter = FakeAdapter((_) => jsonBody({'ok': true}));
    final dio = Dio(BaseOptions(baseUrl: 'http://api.test'))
      ..httpClientAdapter = adapter
      ..interceptors.add(BuildHeaderInterceptor(() async => 57));
    await dio.get<Object?>('/v1/config');
    expect(adapter.requests.single.headers['X-App-Build'], '57');

    final unknown = Dio(BaseOptions(baseUrl: 'http://api.test'))
      ..httpClientAdapter = adapter
      ..interceptors.add(BuildHeaderInterceptor(() async => throw StateError('no plugin')));
    await unknown.get<Object?>('/v1/config');
    expect(adapter.requests.last.headers.containsKey('X-App-Build'), isFalse);
  });
}
