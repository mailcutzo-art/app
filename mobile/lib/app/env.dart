import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

enum Flavor { dev, prod }

/// Build-time configuration, passed with `--dart-define`:
///
/// ```
/// flutter run --dart-define=API_BASE_URL=http://192.168.1.20:8000 \
///             --dart-define=GOOGLE_SERVER_CLIENT_ID=<web client id>
/// ```
@immutable
class AppEnv {
  const AppEnv({
    required this.flavor,
    required this.apiBaseUrl,
    required this.googleServerClientId,
  });

  factory AppEnv.fromDefines() {
    const flavor = String.fromEnvironment('FLAVOR', defaultValue: 'dev');
    return const AppEnv(
      flavor: flavor == 'prod' ? Flavor.prod : Flavor.dev,
      // 10.0.2.2 is the host machine from the Android emulator.
      apiBaseUrl: String.fromEnvironment('API_BASE_URL', defaultValue: 'http://10.0.2.2:8000'),
      googleServerClientId: String.fromEnvironment('GOOGLE_SERVER_CLIENT_ID'),
    );
  }

  final Flavor flavor;
  final String apiBaseUrl;

  /// OAuth *web* client id; Google puts it in the ID token's audience.
  final String googleServerClientId;

  bool get isDev => flavor == Flavor.dev;

  /// Dev-only password-less login for local testing. Never in release builds.
  bool get devLoginAvailable => isDev && !kReleaseMode;

  /// Dev-only sample data for Learn and practice. Never in release builds.
  bool get demoDataAvailable => isDev && !kReleaseMode;

  bool get googleSignInConfigured => googleServerClientId.isNotEmpty;

  AppEnv copyWith({String? apiBaseUrl}) => AppEnv(
    flavor: flavor,
    apiBaseUrl: apiBaseUrl ?? this.apiBaseUrl,
    googleServerClientId: googleServerClientId,
  );
}

/// Overridden in `bootstrap()`.
final appEnvProvider = Provider<AppEnv>((ref) => throw StateError('AppEnv not provided'));
