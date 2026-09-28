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

/// The account was deleted less than 7 days ago. The session is restricted: only the Restore
/// screen (Restore my account, or Sign out) is reachable, and nothing else talks to the server.
final class PendingDeletion extends Session {
  const PendingDeletion(this.user);

  final Me user;

  DateTime? get restoreUntil => user.restoreUntil;
}

/// The account is suspended. Only the Suspended screen (with Sign out) is
/// reachable.
final class Suspended extends Session {
  const Suspended({this.reason, this.until, this.appeal});

  factory Suspended.fromDetails(Map<String, Object?> details) => Suspended(
    reason: details['reason'] is String ? details['reason']! as String : null,
    until: details['until'] is String ? DateTime.tryParse(details['until']! as String) : null,
    appeal: details['appeal'] is String ? details['appeal']! as String : null,
  );

  /// `cheating`, `abuse`, `offensive_name` or `other`.
  final String? reason;

  /// When a temporary suspension ends; null when it's permanent or unknown.
  final DateTime? until;

  /// Where to appeal (an email address or a web page).
  final String? appeal;
}

/// A signed-in session for [me]: restricted while the account awaits deletion.
Session sessionFor(Me me, {bool offline = false}) =>
    me.isPendingDeletion ? PendingDeletion(me) : SignedIn(me, offline: offline);

/// Shown when signing in to an account deleted more than 7 days ago.
const closedAccountMessage =
    'This account was deleted and can no longer be restored. '
    'You can sign in again with a new account after 30 days.';

/// What to tell a user whose session ended without them asking.
String signedOutMessage(String? reason) => switch (reason) {
  'signed_out' => 'You were signed out from another device.',
  'session_limit' => 'You signed in on too many devices, so this one was signed out.',
  'refresh_reuse' => 'For your safety, please sign in again.',
  accountClosed => closedAccountMessage,
  _ => 'Your session has ended. Please sign in again.',
};

/// Owns the signed-in state. Restores a stored session on start, signs in
/// with Google (or dev login), keeps the user fresh, and signs out.
class SessionController extends AsyncNotifier<Session> {
  static const _snapshotKey = 'auth.user_snapshot';

  AuthRepository get _repo => ref.read(authRepositoryProvider);

  @override
  Future<Session> build() async {
    ref.listen(sessionExpiredProvider, (_, _) {
      final end = ref.read(sessionExpiredProvider.notifier).last;
      if (end.reason == accountClosed && end.ban == null && state.value is SignedIn) {
        if (_recheckingClosed) return;
        // Tokens are still good for restore: re-read the account to show the restore screen.
        unawaited(_recheckClosed());
        return;
      }
      _clearSnapshot();
      final ban = end.ban;
      state = AsyncData(
        ban != null ? Suspended.fromDetails(ban) : SignedOut(message: signedOutMessage(end.reason)),
      );
    });

    if (!await _repo.hasStoredSession()) return const SignedOut();
    try {
      final me = await _repo.fetchMe();
      await _saveSnapshot(me);
      return sessionFor(me);
    } on UnauthorizedFailure {
      await ref.read(tokenStoreProvider).clear();
      await _clearSnapshot();
      return const SignedOut();
    } on ForbiddenFailure catch (failure) {
      if (failure.code != 'ACCOUNT_BANNED') rethrow;
      await ref.read(tokenStoreProvider).clear();
      await _clearSnapshot();
      return Suspended.fromDetails(failure.details);
    } on AppFailure catch (failure) {
      // Offline or server trouble: keep the user in with their cached profile.
      final cached = await _readSnapshot();
      if (cached != null && failure.isRetryable) return sessionFor(cached, offline: true);
      rethrow;
    }
  }

  bool _recheckingClosed = false;

  Future<void> _recheckClosed() async {
    _recheckingClosed = true;
    try {
      await refreshUser();
    } on AppFailure catch (failure) {
      if (failure is UnauthorizedFailure) await endLocally(message: closedAccountMessage);
    } finally {
      _recheckingClosed = false;
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
    state = AsyncData(sessionFor(me));
  }

  /// Applies a profile the server already returned.
  Future<void> updateUser(Me me) async {
    await _saveSnapshot(me);
    state = AsyncData(sessionFor(me));
  }

  /// Leaves the Suspended screen. The server session is already over.
  Future<void> leaveSuspended() => endLocally();

  /// Ends the session on this phone only, when the server has already ended it (a suspension,
  /// or the account was just deleted). [message] is shown on the sign-in screen.
  Future<void> endLocally({String? message}) async {
    await ref.read(tokenStoreProvider).clear();
    await ref.read(googleAuthProvider).signOut();
    await _clearSnapshot();
    state = AsyncData(SignedOut(message: message));
  }

  Future<void> signOut() async {
    await _repo.signOut();
    await ref.read(googleAuthProvider).signOut();
    await _clearSnapshot();
    state = const AsyncData(SignedOut());
  }

  Future<void> _signIn(Future<Me> Function() request) async {
    final Me me;
    try {
      me = await request();
    } on ForbiddenFailure catch (failure) {
      // A suspended account gets the Suspended screen (reason, end date,
      // appeal), not a one-line error on the sign-in screen.
      if (failure.code == accountClosed) {
        throw ForbiddenFailure(closedAccountMessage, code: failure.code);
      }
      if (failure.code != 'ACCOUNT_BANNED') rethrow;
      state = AsyncData(Suspended.fromDetails(failure.details));
      return;
    }
    await _saveSnapshot(me);
    state = AsyncData(sessionFor(me));
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
final meProvider = NotifierProvider<MeController, Me>(MeController.new);

class MeController extends Notifier<Me> {
  Me? _last;

  @override
  Me build() {
    final session = ref.watch(sessionProvider).value;
    if (session is SignedIn) return _last = session.user;
    // Signing out: screens below the gate still rebuild while the router
    // animates them away. They keep the last user for those frames.
    if (_last case final last?) return last;
    throw StateError('meProvider read while signed out');
  }
}
