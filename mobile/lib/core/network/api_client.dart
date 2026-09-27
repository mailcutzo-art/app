import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/env.dart';
import '../auth/token_store.dart';
import 'app_failure.dart';
import 'server_signals.dart';

/// Marks a request that must not carry or refresh the access token.
const skipAuth = 'skip_auth';

/// Called when the refresh token is rejected: the session is over.
typedef SessionExpiredCallback = void Function();

/// Thin wrapper over Dio that returns decoded JSON or throws [AppFailure].
class ApiClient {
  ApiClient(this._dio);

  final Dio _dio;

  Dio get dio => _dio;

  Future<Object?> get(String path, {Map<String, Object?>? query, bool auth = true}) =>
      _send(() => _dio.get<Object?>(path, queryParameters: query, options: _opts(auth)));

  Future<Object?> post(String path, {Object? body, bool auth = true, String? idempotencyKey}) =>
      _send(
        () => _dio.post<Object?>(
          path,
          data: body,
          options: _opts(auth, headers: {'Idempotency-Key': ?idempotencyKey}),
        ),
      );

  Future<Object?> patch(String path, {Object? body}) =>
      _send(() => _dio.patch<Object?>(path, data: body));

  Future<Object?> put(String path, {Object? body}) =>
      _send(() => _dio.put<Object?>(path, data: body));

  Future<Object?> delete(String path) => _send(() => _dio.delete<Object?>(path));

  Options _opts(bool auth, {Map<String, Object?>? headers}) =>
      Options(extra: {skipAuth: !auth}, headers: headers);

  Future<Object?> _send(Future<Response<Object?>> Function() request) async {
    try {
      final response = await request();
      return response.data;
    } on DioException catch (e) {
      throw failureFromDio(e);
    }
  }
}

/// Adds the bearer token, refreshes it shortly before expiry, and on a 401
/// refreshes once and retries. [QueuedInterceptor] serializes callers, so
/// concurrent requests share a single refresh.
class AuthInterceptor extends QueuedInterceptor {
  AuthInterceptor({
    required this.tokens,
    required this.refreshDio,
    required this.onSessionExpired,
    required this.retryDio,
  });

  final TokenStore tokens;

  /// Plain Dio (no interceptors) used for the refresh call itself.
  final Dio refreshDio;

  /// Dio used to replay a request after refreshing.
  final Dio retryDio;
  final SessionExpiredCallback onSessionExpired;

  @override
  Future<void> onRequest(RequestOptions options, RequestInterceptorHandler handler) async {
    if (options.extra[skipAuth] == true) return handler.next(options);
    if (tokens.accessTokenExpiring()) {
      try {
        await _refresh();
      } on AppFailure catch (failure) {
        if (failure is UnauthorizedFailure) {
          return handler.reject(DioException(requestOptions: options, error: failure));
        }
        // Offline or server trouble: send the request anyway; it will fail
        // with a clearer error, or succeed if the old token is still valid.
      }
    }
    final token = tokens.accessToken;
    if (token != null) options.headers['Authorization'] = 'Bearer $token';
    handler.next(options);
  }

  @override
  Future<void> onError(DioException err, ErrorInterceptorHandler handler) async {
    final options = err.requestOptions;
    final unauthorized = err.response?.statusCode == 401;
    if (!unauthorized || options.extra[skipAuth] == true || options.extra['retried'] == true) {
      return handler.next(err);
    }
    final sentWith = options.headers['Authorization'];
    try {
      // Another request may already have refreshed while this one waited.
      if (sentWith == 'Bearer ${tokens.accessToken}') await _refresh();
      options
        ..headers['Authorization'] = 'Bearer ${tokens.accessToken}'
        ..extra['retried'] = true;
      final response = await retryDio.fetch<Object?>(options);
      handler.resolve(response);
    } on AppFailure catch (failure) {
      handler.next(DioException(requestOptions: options, error: failure));
    } on DioException catch (e) {
      handler.next(e);
    }
  }

  Future<void> _refresh() async {
    final refreshToken = await tokens.readRefreshToken();
    if (refreshToken == null) throw const UnauthorizedFailure();
    try {
      final response = await refreshDio.post<Object?>(
        '/v1/auth/refresh',
        data: {'refresh_token': refreshToken},
      );
      final data = response.data;
      if (data case {
        'access_token': final String access,
        'access_expires_in': final num ttl,
        'refresh_token': final String refresh,
      }) {
        await tokens.save(
          accessToken: access,
          accessTtl: Duration(seconds: ttl.toInt()),
          refreshToken: refresh,
        );
        return;
      }
      throw const UnexpectedFailure();
    } on DioException catch (e) {
      final failure = failureFromDio(e);
      if (failure is UnauthorizedFailure || failure is ForbiddenFailure) {
        await tokens.clear();
        onSessionExpired();
        throw const UnauthorizedFailure();
      }
      throw failure;
    }
  }
}

/// Reports app-wide conditions seen on any response: this build is too old
/// (426) or the service is in maintenance (503 `MAINTENANCE`).
class ServerSignalInterceptor extends Interceptor {
  ServerSignalInterceptor({required this.onUpdateRequired, required this.onMaintenance});

  final void Function() onUpdateRequired;
  final void Function() onMaintenance;

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    switch (failureFromDio(err)) {
      case UpgradeRequiredFailure():
        onUpdateRequired();
      case MaintenanceFailure():
        onMaintenance();
      default:
        break;
    }
    handler.next(err);
  }
}

BaseOptions _baseOptions(String baseUrl) => BaseOptions(
  baseUrl: baseUrl,
  connectTimeout: const Duration(seconds: 10),
  sendTimeout: const Duration(seconds: 15),
  receiveTimeout: const Duration(seconds: 20),
  contentType: Headers.jsonContentType,
);

/// Fires when the server rejects the refresh token. The session controller
/// listens and signs the user out.
final sessionExpiredProvider = NotifierProvider<SessionExpiredSignal, int>(
  SessionExpiredSignal.new,
);

class SessionExpiredSignal extends Notifier<int> {
  @override
  int build() => 0;

  void fire() => state++;
}

final apiClientProvider = Provider<ApiClient>((ref) {
  final env = ref.watch(appEnvProvider);
  final tokens = ref.watch(tokenStoreProvider);
  final options = _baseOptions(env.apiBaseUrl);
  final plain = Dio(options);
  final dio = Dio(options);
  dio.interceptors
    ..add(
      ServerSignalInterceptor(
        onUpdateRequired: () => ref.read(serverSignalsProvider.notifier).updateRequired(),
        onMaintenance: () => ref.read(serverSignalsProvider.notifier).maintenance(),
      ),
    )
    ..add(
      AuthInterceptor(
        tokens: tokens,
        refreshDio: plain,
        retryDio: plain,
        onSessionExpired: () => ref.read(sessionExpiredProvider.notifier).fire(),
      ),
    );
  ref.onDispose(() {
    dio.close();
    plain.close();
  });
  return ApiClient(dio);
});
