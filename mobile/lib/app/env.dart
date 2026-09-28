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
    this.legalBaseUrl = '',
    this.shareBaseUrl = '',
  });

  factory AppEnv.fromDefines() {
    const flavor = String.fromEnvironment('FLAVOR', defaultValue: 'dev');
    return const AppEnv(
      flavor: flavor == 'prod' ? Flavor.prod : Flavor.dev,
      // 10.0.2.2 is the host machine from the Android emulator.
      apiBaseUrl: String.fromEnvironment('API_BASE_URL', defaultValue: 'http://10.0.2.2:8000'),
      googleServerClientId: String.fromEnvironment(
        'GOOGLE_SERVER_CLIENT_ID',
        defaultValue: '229263281230-8n5u3f3dgrpelo98ibsb4mnhiaf8poi1.apps.googleusercontent.com',
      ),
      // Read from --dart-define; the analyzer only sees the empty default.
      // ignore: avoid_redundant_argument_values
      legalBaseUrl: String.fromEnvironment('LEGAL_BASE_URL'),
      // ignore: avoid_redundant_argument_values
      shareBaseUrl: String.fromEnvironment('SHARE_BASE_URL'),
    );
  }

  final Flavor flavor;
  final String apiBaseUrl;

  /// OAuth *web* client id; Google puts it in the ID token's audience.
  final String googleServerClientId;

  /// Where the Terms (`/terms`) and Privacy policy (`/privacy`) live. Empty
  /// until they're published, and then the links stay hidden.
  final String legalBaseUrl;

  /// A link added to the caption of cards shared to other apps (the app's
  /// page). Empty until there is one, and then captions carry no link.
  final String shareBaseUrl;

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
    legalBaseUrl: legalBaseUrl,
    shareBaseUrl: shareBaseUrl,
  );
}

/// Overridden in `bootstrap()`.
final appEnvProvider = Provider<AppEnv>((ref) => throw StateError('AppEnv not provided'));
