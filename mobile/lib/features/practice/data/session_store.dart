import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/auth/session.dart';
import '../../../core/network/json.dart';
import '../../../core/storage/prefs.dart';
import 'practice_models.dart';

/// The unfinished practice session saved on this device, with the answers
/// given so far, so "Continue practice" works even if the app was killed
/// while offline.
@immutable
class ActivePractice {
  const ActivePractice({required this.session, this.answers = const {}, this.bookmarks = const {}});

  final PracticeSession session;

  /// Answers given on this device, by position.
  final Map<int, SessionAnswer> answers;

  /// Refs bookmarked, as last set on this device.
  final Set<String> bookmarks;
}

/// One user's practice sessions on this device (keys include the user id,
/// because phones get shared).
///
/// * The active (unfinished) session is saved to disk: its questions once,
///   and its answers and bookmarks as they change. Opening it needs no
///   request. It is cleared when the session finishes, and ignored once it
///   has expired.
/// * Sessions created in this run also stay in memory, as a fallback for
///   when the server can't be reached.
/// * The settings of the last [maxSaved] sessions are saved too, so
///   "Practise again" works after a restart; the server doesn't repeat them.
class PracticeSessionStore {
  PracticeSessionStore(this._prefs, {required this.userId, DateTime Function()? now})
    : _now = now ?? DateTime.now;

  static const maxSaved = 20;

  final String userId;
  final SharedPreferences _prefs;
  final DateTime Function() _now;
  final _sessions = <String, PracticeSession>{};
  ActivePractice? _active;
  var _activeRead = false;

  String get _settingsKey => 'practice.settings.$userId';
  String get _activeKey => 'practice.active.$userId';
  String get _activeProgressKey => 'practice.active_progress.$userId';

  /// The active session, with its saved answers, if it is [sessionId].
  ActivePractice? activeFor(String sessionId) {
    final active = this.active();
    return active?.session.sessionId == sessionId ? active : null;
  }

  /// A session created in this run (without answers given since).
  PracticeSession? recent(String sessionId) => _sessions[sessionId];

  /// The unfinished session saved on this device, unless it has expired.
  ActivePractice? active() {
    if (!_activeRead) {
      _activeRead = true;
      _active = _readActive();
    }
    final active = _active;
    if (active != null && active.session.isExpired(_now())) {
      _active = null;
      unawaited(_clearActiveKeys());
      return null;
    }
    return active;
  }

  SessionSettings? settings(String sessionId) {
    final json = _readSettings()[sessionId];
    if (json == null) return null;
    try {
      return SessionSettings.fromJson(json);
    } on FormatException catch (e) {
      debugPrint('Ignoring unreadable settings for $sessionId: $e');
      return null;
    }
  }

  /// Remembers a session just created with [settings]; it becomes the
  /// active one.
  Future<void> save(PracticeSession session, SessionSettings settings) async {
    _sessions[session.sessionId] = session;
    // Insertion order is recency: re-adding moves a session to the end.
    final all = _readSettings()
      ..remove(session.sessionId)
      ..[session.sessionId] = settings.toJson();
    while (all.length > maxSaved) {
      all.remove(all.keys.first);
    }
    await _prefs.setString(_settingsKey, jsonEncode(all));
    await saveActive(session);
  }

  /// Makes [session] the active one (its questions are written once).
  Future<void> saveActive(PracticeSession session) async {
    if (session.finished) return;
    final keep = active()?.session.sessionId == session.sessionId ? _active : null;
    _active = ActivePractice(
      session: session,
      answers: keep?.answers ?? const {},
      bookmarks:
          keep?.bookmarks ??
          {
            for (final q in session.questions)
              if (q.bookmarked) q.ref,
          },
    );
    _activeRead = true;
    await _prefs.setString(_activeKey, jsonEncode(session.toJson()));
    await _writeActiveProgress();
  }

  /// Saves the answers and bookmarks of the active session.
  Future<void> saveProgress(
    String sessionId, {
    required Map<int, SessionAnswer> answers,
    required Set<String> bookmarks,
  }) async {
    final active = this.active();
    if (active == null || active.session.sessionId != sessionId) return;
    _active = ActivePractice(session: active.session, answers: answers, bookmarks: bookmarks);
    await _writeActiveProgress();
  }

  /// Forgets [sessionId] as the active session once it has finished.
  Future<void> clearActive(String sessionId) async {
    if (active()?.session.sessionId != sessionId) return;
    _active = null;
    await _clearActiveKeys();
  }

  Future<void> _writeActiveProgress() async {
    final active = _active;
    if (active == null) return;
    await _prefs.setString(
      _activeProgressKey,
      jsonEncode({
        'session_id': active.session.sessionId,
        'answers': [for (final answer in active.answers.values) answer.toJson()],
        'bookmarks': active.bookmarks.toList(),
      }),
    );
  }

  Future<void> _clearActiveKeys() async {
    await _prefs.remove(_activeKey);
    await _prefs.remove(_activeProgressKey);
  }

  ActivePractice? _readActive() {
    final raw = _prefs.getString(_activeKey);
    if (raw == null) return null;
    try {
      final session = PracticeSession.fromJson(jsonDecode(raw));
      final progressRaw = _prefs.getString(_activeProgressKey);
      final progress = progressRaw == null
          ? null
          : JsonReader(jsonDecode(progressRaw), 'active practice');
      if (progress == null || progress.string('session_id') != session.sessionId) {
        return ActivePractice(session: session);
      }
      return ActivePractice(
        session: session,
        answers: {
          for (final answer in progress.list('answers', SessionAnswer.fromJson))
            answer.position: answer,
        },
        bookmarks: {...progress.optList('bookmarks', _string)},
      );
    } on FormatException catch (e) {
      debugPrint('Discarding unreadable active practice: $e');
      unawaited(_clearActiveKeys());
      return null;
    }
  }

  Map<String, Object?> _readSettings() {
    try {
      final decoded = jsonDecode(_prefs.getString(_settingsKey) ?? '{}');
      if (decoded is Map<String, Object?>) return decoded;
    } on FormatException catch (e) {
      debugPrint('Discarding unreadable practice settings: $e');
    }
    return {};
  }
}

String _string(Object? value) => switch (value) {
  final String s => s,
  _ => throw const FormatException('active practice: "bookmarks" must be strings'),
};

final practiceSessionStoreProvider = Provider<PracticeSessionStore>(
  (ref) => PracticeSessionStore(
    ref.watch(sharedPrefsProvider),
    userId: ref.watch(currentUserIdProvider) ?? '_',
  ),
);
