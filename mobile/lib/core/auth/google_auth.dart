import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../../app/env.dart';
import '../network/app_failure.dart';

/// Thrown when the user closes the Google account picker; not an error.
class SignInCancelled implements Exception {
  const SignInCancelled();
}

/// Obtains a Google ID token via Credential Manager (google_sign_in 7).
///
/// The plugin may be initialized only once per process, so the nonce is fixed
/// for the process; the server additionally rejects stale or reused tokens.
class GoogleAuth {
  GoogleAuth(this._env);

  final AppEnv _env;
  Future<void>? _init;

  bool get isConfigured => _env.googleSignInConfigured;

  Future<String> idToken() async {
    if (!isConfigured) {
      throw const ValidationFailure('Google sign-in isn\'t configured for this build yet.');
    }
    final google = GoogleSignIn.instance;
    await (_init ??= google.initialize(serverClientId: _env.googleServerClientId, nonce: _nonce()));
    try {
      await google.signOut(); // always show the account picker
      final account = await google.authenticate();
      final token = account.authentication.idToken;
      if (token == null) {
        throw const ValidationFailure('Google sign-in succeeded but returned no ID token.');
      }
      return token;
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled ||
          e.code == GoogleSignInExceptionCode.interrupted) {
        throw const SignInCancelled();
      }
      final detail = e.description ?? e.code.name;
      throw ValidationFailure('Google sign-in error: $detail');
    } catch (e) {
      throw ValidationFailure('Google sign-in error: $e');
    }
  }

  Future<void> signOut() async {
    if (_init == null) return;
    await GoogleSignIn.instance.signOut();
  }

  static String _nonce() {
    final random = Random.secure();
    return List.generate(24, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }
}

final googleAuthProvider = Provider<GoogleAuth>((ref) => GoogleAuth(ref.watch(appEnvProvider)));
