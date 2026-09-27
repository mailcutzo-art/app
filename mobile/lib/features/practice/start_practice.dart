import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/app_failure.dart';
import '../learn/data/learn_repository.dart';
import '../learn/learn_providers.dart';
import 'data/practice_models.dart';
import 'data/session_store.dart';

/// Creates practice sessions and remembers them for the practice screen.
class PracticeStarter {
  PracticeStarter(this._ref);

  final Ref _ref;

  /// Creates a session for [settings]. Retrying with the same
  /// [idempotencyKey] returns the same session instead of a second one, so
  /// a new key is needed whenever the settings change.
  Future<PracticeSession> start(SessionSettings settings, {required String idempotencyKey}) async {
    final session = await _ref
        .read(learnRepositoryProvider)
        .createSession(settings, idempotencyKey: idempotencyKey);
    await _ref.read(practiceSessionStoreProvider).save(session, settings);
    // "Continue practice" now points at this session.
    _ref.invalidate(progressProvider);
    return session;
  }
}

final practiceStarterProvider = Provider<PracticeStarter>(PracticeStarter.new);

/// What to tell the user when a session couldn't be created. [noQuestions]
/// replaces the generic text for `409 NO_QUESTIONS` (e.g. an empty review).
String practiceStartError(AppFailure failure, {String? noQuestions}) => switch (failure) {
  ConflictFailure(code: 'NO_QUESTIONS') => noQuestions ?? 'No questions match these settings yet.',
  RateLimitedFailure() => 'You\'ve started a lot of sessions. Take a short break and try again.',
  _ => failure.message,
};
