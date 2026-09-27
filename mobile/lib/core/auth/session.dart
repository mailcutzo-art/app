import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../network/api_client.dart';
import '../network/app_failure.dart';
import 'auth_repository.dart';
import 'google_auth.dart';
import 'token_store.dart';
import 'user.dart';

sealed class Session {
  const Session();
}

final class SignedOut extends Session {
  const SignedOut({this.message});

  /// Why the user was signed out, if it wasn't their choice.
  final String? message;
}

final class SignedIn extends Session {
  const SignedIn(this.user, {this.offline = false});

  final Me user;

  /// Restored from the local snapshot because the server was unreachable.
  final bool offline;

  bool get needsOnboarding => !user.onboardingCompleted;
}

/// Owns the signed-in state. Restores a stored session on start, signs in
/// with Google (or dev login), keeps the user fresh, and signs out.
class SessionController extends AsyncNotifier<Session> {
  static const _snapshotKey = 'auth.user_snapshot';

  AuthRepository get _repo => ref.read(authRepositoryProvider);

  @override
  Future<Session> build() async {
    ref.listen(sessionExpiredProvider, (_, _) {
      _clearSnapshot();
      state = const AsyncData(SignedOut(message: 'Your session has ended. Please sign in again.'));
    });

    if (!await _repo.hasStoredSession()) return const SignedOut();
    try {
      final me = await _repo.fetchMe();
      await _saveSnapshot(me);
      return SignedIn(me);
    } on UnauthorizedFailure {
      await ref.read(tokenStoreProvider).clear();
      await _clearSnapshot();
      return const SignedOut();
    } on AppFailure catch (failure) {
      // Offline or server trouble: keep the user in with their cached profile.
      final cached = await _readSnapshot();
      if (cached != null && failure.isRetryable) return SignedIn(cached, offline: true);
      rethrow;
    }
  }

  Future<void> signInWithGoogle() async {
    final token = await ref.read(googleAuthProvider).idToken();
    await _signIn(() => _repo.signInWithGoogle(token));
  }

  Future<void> devLogin(String email, {String? displayName}) =>
      _signIn(() => _repo.devLogin(email: email, displayName: displayName));

  /// Re-reads `/v1/me` (e.g. after onboarding or a profile edit).
  Future<void> refreshUser() async {
    final me = await _repo.fetchMe();
    await _saveSnapshot(me);
    state = AsyncData(SignedIn(me));
  }

  /// Applies a profile the server already returned.
  Future<void> updateUser(Me me) async {
    await _saveSnapshot(me);
    state = AsyncData(SignedIn(me));
  }

  Future<void> signOut() async {
    await _repo.signOut();
    await ref.read(googleAuthProvider).signOut();
    await _clearSnapshot();
    state = const AsyncData(SignedOut());
  }

  Future<void> _signIn(Future<Me> Function() request) async {
    final me = await request();
    await _saveSnapshot(me);
    state = AsyncData(SignedIn(me));
  }

  Future<void> _saveSnapshot(Me me) =>
      ref.read(secureStorageProvider).write(key: _snapshotKey, value: jsonEncode(me.toJson()));

  Future<void> _clearSnapshot() => ref.read(secureStorageProvider).delete(key: _snapshotKey);

  Future<Me?> _readSnapshot() async {
    try {
      final raw = await ref.read(secureStorageProvider).read(key: _snapshotKey);
      return raw == null ? null : Me.fromJson(jsonDecode(raw));
    } on FormatException catch (e) {
      debugPrint('Discarding unreadable user snapshot: $e');
      return null;
    }
  }
}

final sessionProvider = AsyncNotifierProvider<SessionController, Session>(
  SessionController.new,
  // Session restore has its own offline handling; don't auto-retry.
  retry: (_, _) => null,
);

/// The signed-in user's id, or null while signed out. Per-user storage on the
/// device (e.g. queued practice answers) is keyed by it, because phones get
/// shared.
final currentUserIdProvider = Provider<String?>(
  (ref) => switch (ref.watch(sessionProvider).value) {
    SignedIn(:final user) => user.id,
    _ => null,
  },
);

/// The signed-in user; only valid below the auth gate.
final meProvider = Provider<Me>((ref) {
  final session = ref.watch(sessionProvider).value;
  if (session is SignedIn) return session.user;
  throw StateError('meProvider read while signed out');
});
