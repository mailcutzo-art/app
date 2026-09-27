import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/auth/session.dart';
import '../../../core/network/app_failure.dart';
import '../../../core/network/connectivity.dart';
import '../../../core/storage/prefs.dart';
import '../../learn/data/learn_repository.dart';
import 'practice_models.dart';

typedef AnswerUploader = Future<AnswersResponse> Function(
  String sessionId,
  List<AnswerUpload> answers,
);
typedef SessionFinisher = Future<SessionSummary> Function(String sessionId);

/// 2 s, 4 s, 8 s … up to a minute, with ±20% jitter so phones that lost the
/// same server don't all come back at the same instant.
Duration defaultAnswerBackoff(int attempt, [Random? random]) {
  final seconds = min(60, 2 << min(attempt - 1, 5));
  final jitter = 0.8 + 0.4 * (random ?? Random()).nextDouble();
  return Duration(milliseconds: (seconds * 1000 * jitter).round());
}

/// Offline-first upload queue for one user's practice answers.
///
/// * An answer is written to shared preferences (one key per user and
///   session) the moment it is given, so it survives the app being killed.
///   Each user has their own queue: another user's answers are never loaded,
///   so they can't be sent with the wrong token; they wait until that user
///   signs in again.
/// * [flush] uploads in batches of [batchSize]. It runs after each answer,
///   when connectivity returns, on app start (sign-in) and before a session
///   finishes.
/// * `accepted`, `duplicate` and `rejected` answers leave the queue;
///   refusals are remembered per session so the result screen can say so.
///   Network, timeout and 5xx failures keep answers and retry with backoff.
///   A 401 keeps them too: the auth interceptor has already tried to
///   refresh, so the user is being signed out and their next sign-in sends
///   them.
/// * [finish] ends a session only after its answers are uploaded. If that
///   can't happen now, the request is kept and retried in the background.
class AnswerQueue extends ChangeNotifier {
  AnswerQueue({
    required this._prefs,
    required this.userId,
    required this._upload,
    required this._finish,
    Duration Function(int attempt)? backoff,
    DateTime Function()? now,
  }) : _backoff = backoff ?? defaultAnswerBackoff,
       _now = now ?? DateTime.now {
    _load();
  }

  static const batchSize = 50;

  /// The server accepts answers up to 7 days late (judged by `answered_at`),
  /// so older ones are dropped when the queue loads.
  static const maxAge = Duration(days: 7);

  /// Whose answers these are.
  final String userId;

  final SharedPreferences _prefs;
  final AnswerUploader _upload;
  final SessionFinisher _finish;
  final Duration Function(int attempt) _backoff;
  final DateTime Function() _now;

  final _pending = <String, List<AnswerUpload>>{};
  final _finishRequested = <String>{};
  final _summaries = <String, SessionSummary>{};
  final _finishFailures = <String, AppFailure>{};
  final _refusals = <String, List<String>>{};

  Future<void>? _running;
  var _again = false;
  Timer? _retryTimer;
  var _attempt = 0;
  var _online = true;
  var _disposed = false;
  AppFailure? _lastStop;

  String get _answersPrefix => 'practice.queue.$userId.';
  String get _finishKey => 'practice.finish_pending.$userId';
  String get _refusalsKey => 'practice.refused.$userId';

  /// Answers of [sessionId] the server doesn't have yet, oldest first.
  List<AnswerUpload> pending(String sessionId) =>
      List.unmodifiable(_pending[sessionId] ?? const []);

  int get pendingCount => _pending.values.fold(0, (sum, list) => sum + list.length);

  /// Whether a retry is scheduled.
  bool get retryScheduled => _retryTimer?.isActive ?? false;

  bool isFinishPending(String sessionId) => _finishRequested.contains(sessionId);

  /// The server's summary once [finish] (or a background retry of it) worked.
  SessionSummary? summaryFor(String sessionId) => _summaries[sessionId];

  /// Why answers of [sessionId] couldn't be saved: the `reason` of each
  /// `rejected` result (`session_expired`, `time_up`…), or the error code of
  /// a batch the server refused outright.
  List<String> refusals(String sessionId) => List.unmodifiable(_refusals[sessionId] ?? const []);

  /// Forgets [sessionId]'s refusals once the user has been told.
  Future<void> clearRefusals(String sessionId) async {
    if (_refusals.remove(sessionId) != null) await _saveRefusals();
  }

  /// Queues [answer] and starts an upload. Returns false, and changes
  /// nothing, when the queue already has this answer or another answer for
  /// the same position (the server only counts the first per position).
  Future<bool> add(String sessionId, AnswerUpload answer) async {
    final list = _pending.putIfAbsent(sessionId, () => []);
    if (list.any(
      (a) => a.clientAnswerId == answer.clientAnswerId || a.position == answer.position,
    )) {
      return false;
    }
    list.add(answer);
    _notify();
    await _saveAnswers(sessionId);
    unawaited(flush());
    return true;
  }

  /// Uploads everything queued, then finishes sessions waiting for it.
  /// Completes when there is nothing more to do right now; failures are
  /// retried later. Concurrent calls share one run.
  Future<void> flush() {
    if (_disposed) return Future.value();
    _retryTimer?.cancel();
    _retryTimer = null;
    _again = true;
    return _running ??= _drain().whenComplete(() => _running = null);
  }

  /// Uploads [sessionId]'s remaining answers, then ends the session.
  ///
  /// Throws the [AppFailure] that stopped it (e.g. offline). The request is
  /// kept and retried in the background; listen to this queue and read
  /// [summaryFor] to learn when it went through.
  Future<SessionSummary> finish(String sessionId) async {
    if (_summaries[sessionId] case final done?) return done;
    _finishRequested.add(sessionId);
    _finishFailures.remove(sessionId);
    await _saveFinishes();
    await flush();
    if (_summaries[sessionId] case final summary?) return summary;
    throw _finishFailures[sessionId] ?? _lastStop ?? const NetworkFailure();
  }

  /// Connectivity changes: coming back online flushes straight away.
  void setOnline({required bool online}) {
    final cameBack = online && !_online;
    _online = online;
    if (cameBack) {
      _attempt = 0;
      unawaited(flush());
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _retryTimer?.cancel();
    super.dispose();
  }

  Future<void> _drain() async {
    while (_again && !_disposed) {
      _again = false;
      await _pass();
    }
  }

  /// One pass over the queue: uploads per session, oldest session first,
  /// then pending finishes. Stops at the first failure that isn't about the
  /// request itself (offline, server down, signed out).
  Future<void> _pass() async {
    AppFailure? stop;
    sessions:
    for (final sessionId in _sessionsOldestFirst()) {
      while (!_disposed) {
        final queued = _pending[sessionId];
        if (queued == null || queued.isEmpty) break;
        final batch = queued.take(batchSize).toList();
        try {
          final response = await _upload(sessionId, batch);
          final settled = <String>{};
          final refused = <String>[];
          for (final result in response.results) {
            if (!result.settled) continue;
            settled.add(result.clientAnswerId);
            if (result.status == AnswerStatus.rejected) refused.add(result.reason ?? 'rejected');
          }
          await _refuse(sessionId, refused);
          final removed = await _remove(sessionId, (a) => settled.contains(a.clientAnswerId));
          if (removed == 0) {
            // The server settled nothing in this batch; try again later
            // rather than spinning.
            stop = const UnexpectedFailure();
            break sessions;
          }
        } on AppFailure catch (failure) {
          if (_isPermanent(failure)) {
            // The request itself can never succeed (e.g. the session is
            // gone); drop the batch so it can't block the queue, and say so.
            debugPrint('Dropping ${batch.length} answers of $sessionId: $failure');
            final reason = failure.code?.toLowerCase() ?? 'refused';
            await _refuse(sessionId, [for (final _ in batch) reason]);
            final ids = {for (final a in batch) a.clientAnswerId};
            await _remove(sessionId, (a) => ids.contains(a.clientAnswerId));
            continue;
          }
          stop = failure;
          break sessions;
        } on Object catch (error) {
          debugPrint('Answer upload failed: $error');
          stop = const UnexpectedFailure();
          break sessions;
        }
      }
    }

    if (stop == null) {
      for (final sessionId in [..._finishRequested]) {
        if (_disposed) return;
        if (_pending[sessionId]?.isNotEmpty ?? false) continue;
        try {
          _summaries[sessionId] = await _finish(sessionId);
          _finishRequested.remove(sessionId);
          _finishFailures.remove(sessionId);
          await _saveFinishes();
          _notify();
        } on AppFailure catch (failure) {
          _finishFailures[sessionId] = failure;
          if (_isPermanent(failure)) {
            debugPrint('Giving up finishing $sessionId: $failure');
            _finishRequested.remove(sessionId);
            await _saveFinishes();
            _notify();
            continue;
          }
          stop = failure;
          break;
        }
      }
    }

    _lastStop = stop;
    if (stop == null) {
      _attempt = 0;
    } else {
      _scheduleRetry(stop);
    }
  }

  void _scheduleRetry(AppFailure failure) {
    if (_disposed || !failure.isRetryable) return;
    _attempt++;
    var delay = _backoff(_attempt);
    if (failure case RateLimitedFailure(:final retryAfter?) when retryAfter > delay) {
      delay = retryAfter;
    }
    _retryTimer?.cancel();
    _retryTimer = Timer(delay, () {
      _retryTimer = null;
      unawaited(flush());
    });
  }

  /// 4xx answers that no retry can fix. 401 (signed out), 403, 426 and 429
  /// are not in this list: those answers wait for a later flush.
  static bool _isPermanent(AppFailure failure) =>
      failure is ValidationFailure || failure is NotFoundFailure || failure is ConflictFailure;

  Iterable<String> _sessionsOldestFirst() {
    final sessions = _pending.entries.where((e) => e.value.isNotEmpty).toList()
      ..sort((a, b) => a.value.first.answeredAt.compareTo(b.value.first.answeredAt));
    return sessions.map((e) => e.key);
  }

  Future<int> _remove(String sessionId, bool Function(AnswerUpload answer) test) async {
    final list = _pending[sessionId];
    if (list == null) return 0;
    final before = list.length;
    list.removeWhere(test);
    final removed = before - list.length;
    if (list.isEmpty) _pending.remove(sessionId);
    if (removed > 0) {
      _notify();
      await _saveAnswers(sessionId);
    }
    return removed;
  }

  Future<void> _refuse(String sessionId, List<String> reasons) async {
    if (reasons.isEmpty) return;
    _refusals.putIfAbsent(sessionId, () => []).addAll(reasons);
    _notify();
    await _saveRefusals();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  // ------------------------------------------------------------- persistence

  void _load() {
    final oldest = _now().subtract(maxAge);
    for (final key in _prefs.getKeys()) {
      if (!key.startsWith(_answersPrefix)) continue;
      final sessionId = key.substring(_answersPrefix.length);
      try {
        final decoded = jsonDecode(_prefs.getString(key) ?? '[]') as List<Object?>;
        final answers = [for (final item in decoded) AnswerUpload.fromJson(item)];
        final fresh = [
          for (final answer in answers)
            if (answer.answeredAt.isAfter(oldest)) answer,
        ];
        if (fresh.length < answers.length) {
          debugPrint('Dropping ${answers.length - fresh.length} answers older than 7 days');
          unawaited(_writeList(key, fresh));
        }
        if (fresh.isNotEmpty) _pending[sessionId] = fresh;
      } on Object catch (e) {
        debugPrint('Discarding unreadable queued answers for $sessionId: $e');
        unawaited(_prefs.remove(key));
      }
    }
    try {
      final decoded = jsonDecode(_prefs.getString(_finishKey) ?? '[]') as List<Object?>;
      _finishRequested.addAll(decoded.whereType<String>());
    } on Object catch (e) {
      debugPrint('Discarding unreadable finish requests: $e');
    }
    try {
      final decoded = jsonDecode(_prefs.getString(_refusalsKey) ?? '{}') as Map<String, Object?>;
      for (final MapEntry(:key, :value) in decoded.entries) {
        if (value is List) _refusals[key] = [...value.whereType<String>()];
      }
    } on Object catch (e) {
      debugPrint('Discarding unreadable refusals: $e');
    }
  }

  // A disposed queue (its user signed out) never writes, so it can't
  // overwrite what a newer queue for the same user saved.

  Future<void> _saveAnswers(String sessionId) async {
    if (_disposed) return;
    await _writeList('$_answersPrefix$sessionId', _pending[sessionId] ?? const []);
  }

  Future<void> _writeList(String key, List<AnswerUpload> answers) async {
    try {
      if (answers.isEmpty) {
        await _prefs.remove(key);
      } else {
        await _prefs.setString(key, jsonEncode([for (final a in answers) a.toJson()]));
      }
    } on Object catch (e) {
      // Still queued in memory; the next change writes it again.
      debugPrint('Couldn\'t save queued answers: $e');
    }
  }

  Future<void> _saveFinishes() async {
    if (_disposed) return;
    try {
      if (_finishRequested.isEmpty) {
        await _prefs.remove(_finishKey);
      } else {
        await _prefs.setString(_finishKey, jsonEncode(_finishRequested.toList()));
      }
    } on Object catch (e) {
      debugPrint('Couldn\'t save finish requests: $e');
    }
  }

  Future<void> _saveRefusals() async {
    if (_disposed) return;
    try {
      if (_refusals.isEmpty) {
        await _prefs.remove(_refusalsKey);
      } else {
        await _prefs.setString(_refusalsKey, jsonEncode(_refusals));
      }
    } on Object catch (e) {
      debugPrint('Couldn\'t save refusals: $e');
    }
  }
}

/// Stands in for the user id while nobody is signed in; nothing is queued
/// under it.
const _nobody = '_';

/// The signed-in user's answer queue, wired to the Learn API and to
/// connectivity. Signing in as someone else gives a new queue; the previous
/// user's answers stay on disk, untouched, until they sign in again.
final answerQueueProvider = Provider<AnswerQueue>((ref) {
  final queue = AnswerQueue(
    prefs: ref.watch(sharedPrefsProvider),
    userId: ref.watch(currentUserIdProvider) ?? _nobody,
    // Read when used, so switching to demo data keeps the same queue.
    upload: (sessionId, answers) =>
        ref.read(learnRepositoryProvider).uploadAnswers(sessionId, answers),
    finish: (sessionId) => ref.read(learnRepositoryProvider).finishSession(sessionId),
  );
  ref
    ..listen(isOnlineProvider, (_, online) => queue.setOnline(online: online))
    ..onDispose(queue.dispose);
  return queue;
});

/// Sends answers left over from an earlier run once a user is signed in
/// (app start, or that user's next sign-in).
final answerSyncProvider = Provider<void>((ref) {
  if (ref.watch(currentUserIdProvider) == null) return;
  unawaited(ref.watch(answerQueueProvider).flush());
});
