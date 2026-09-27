import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../device/device_info.dart';
import '../network/api_client.dart';
import '../network/app_failure.dart';
import 'token_store.dart';
import 'user.dart';

/// Talks to `/v1/auth/*` and `/v1/me`, and keeps [TokenStore] in sync.
class AuthRepository {
  AuthRepository({required this.api, required this.tokens, required this.device});

  final ApiClient api;
  final TokenStore tokens;
  final Future<DeviceInfo> Function() device;

  Future<Me> signInWithGoogle(String idToken) async {
    final body = {'id_token': idToken, 'device': (await device()).toJson()};
    return _completeSignIn(await api.post('/v1/auth/google', body: body, auth: false));
  }

  /// Development-only login (the server rejects it outside dev).
  Future<Me> devLogin({required String email, String? displayName}) async {
    final body = {
      'email': email,
      'display_name': ?displayName,
      'device': (await device()).toJson(),
    };
    return _completeSignIn(await api.post('/v1/auth/dev-login', body: body, auth: false));
  }

  Future<Me> fetchMe() async => Me.fromJson(await api.get('/v1/me'));

  /// Whether a stored session exists (the refresh token may still be rejected).
  Future<bool> hasStoredSession() async => await tokens.readRefreshToken() != null;

  Future<void> signOut() async {
    try {
      await api.post('/v1/auth/logout');
    } on AppFailure {
      // The local session ends regardless; the server session expires on its own.
    } finally {
      await tokens.clear();
    }
  }

  Future<Me> _completeSignIn(Object? data) async {
    if (data case {
      'access_token': final String access,
      'access_expires_in': final num ttl,
      'refresh_token': final String refresh,
      'user': final Object user,
    }) {
      await tokens.save(
        accessToken: access,
        accessTtl: Duration(seconds: ttl.toInt()),
        refreshToken: refresh,
      );
      return Me.fromJson(user);
    }
    throw const UnexpectedFailure();
  }
}

final authRepositoryProvider = Provider<AuthRepository>(
  (ref) => AuthRepository(
    api: ref.watch(apiClientProvider),
    tokens: ref.watch(tokenStoreProvider),
    device: () => ref.read(deviceInfoProvider.future),
  ),
);
