import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Access and refresh tokens. The refresh token lives in the platform
/// keystore-backed secure storage; the short-lived access token stays in
/// memory only.
class TokenStore {
  TokenStore(this._storage);

  final FlutterSecureStorage _storage;

  static const _refreshKey = 'auth.refresh_token';

  String? _accessToken;
  DateTime? _accessExpiresAt;

  String? get accessToken => _accessToken;

  /// True when the access token is missing or expires within [margin].
  bool accessTokenExpiring({Duration margin = const Duration(seconds: 60)}) {
    final expires = _accessExpiresAt;
    return _accessToken == null || expires == null || DateTime.now().add(margin).isAfter(expires);
  }

  Future<String?> readRefreshToken() => _storage.read(key: _refreshKey);

  Future<void> save({
    required String accessToken,
    required Duration accessTtl,
    required String refreshToken,
  }) async {
    _accessToken = accessToken;
    _accessExpiresAt = DateTime.now().add(accessTtl);
    await _storage.write(key: _refreshKey, value: refreshToken);
  }

  Future<void> clear() async {
    _accessToken = null;
    _accessExpiresAt = null;
    await _storage.delete(key: _refreshKey);
  }
}

final secureStorageProvider = Provider<FlutterSecureStorage>(
  (ref) => const FlutterSecureStorage(aOptions: AndroidOptions(storageNamespace: 'quiz_secure')),
);

final tokenStoreProvider = Provider<TokenStore>(
  (ref) => TokenStore(ref.watch(secureStorageProvider)),
);
