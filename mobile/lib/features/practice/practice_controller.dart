import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/app_failure.dart';
import '../learn/data/learn_repository.dart';
import '../learn/learn_providers.dart';
import 'data/answer_queue.dart';
import 'data/practice_models.dart';
import 'data/session_store.dart';

/// Makes the stopwatch that times each question. Tests swap in a fake one.
final practiceStopwatchProvider = Provider<Stopwatch Function()>((ref) => Stopwatch.new);

/// Everything the practice screen shows.
@immutable
class PracticeState {
  const PracticeState({
    required this.session,
    required this.index,
    this.answers = const {},
    this.selection,
    this.selectionChanges = 0,
    this.bookmarks = const {},
    this.settings,
    this.finishing = false,
    this.summary,
    this.syncing = false,
    this.refusals = const [],
  });

  final PracticeSession session;

  /// The question on screen.
  final int index;

  /// Answers by position: from the server, saved on this device, waiting in
  /// the upload queue, or given on this screen.
  final Map<int, SessionAnswer> answers;

  /// End-of-session feedback only: the pick not submitted yet.
  final int? selection;

  /// How often the pick changed before it was submitted.
  final int selectionChanges;

  /// Refs of bookmarked questions, as the user last set them.
  final Set<String> bookmarks;

  /// How the session was created, for "Practise again". Unknown for a
  /// session started elsewhere.
  final SessionSettings? settings;
  final bool finishing;
  final SessionSummary? summary;

  /// The summary was worked out on this device and the finish is still
  /// being retried in the background.
  final bool syncing;

  /// Why answers the server refused couldn't be saved (see
  /// [AnswerQueue.refusals]).
  final List<String> refusals;

  PracticeQuestion get question => session.questions[index];

  SessionAnswer? get answer => answers[question.position];

  int get total => session.questions.length;

  bool get isLast => index == total - 1;

  bool get bookmarked => bookmarks.contains(question.ref);

  bool get done => summary != null;

  /// The current question's answer and explanation are showing.
  bool get revealed => session.instantFeedback && answer != null;

  static const _keep = Object();

  PracticeState copyWith({
    int? index,
    Map<int, SessionAnswer>? answers,
    Object? selection = _keep,
    int? selectionChanges,
    Set<String>? bookmarks,
    bool? finishing,
    SessionSummary? summary,
    bool? syncing,
    List<String>? refusals,
  }) => PracticeState(
    session: session,
    index: index ?? this.index,
    answers: answers ?? this.answers,
    selection: identical(selection, _keep) ? this.selection : selection as int?,
    selectionChanges: selectionChanges ?? this.selectionChanges,
    bookmarks: bookmarks ?? this.bookmarks,
    settings: settings,
    finishing: finishing ?? this.finishing,
    summary: summary ?? this.summary,
    syncing: syncing ?? this.syncing,
    refusals: refusals ?? this.refusals,
  );
}

final practiceControllerProvider = AsyncNotifierProvider.autoDispose
    .family<PracticeController, PracticeState, String>(
      PracticeController.new,
      // The screen offers a retry; the session doesn't change by waiting.
      retry: (_, _) => null,
    );

/// One practice session: loads (or resumes) it, records answers into the
/// [AnswerQueue] as they're given, keeps the session saved on the device
/// until it's finished, and finishes it.
class PracticeController extends AsyncNotifier<PracticeState> {
  PracticeController(this.sessionId);

  final String sessionId;

  /// Bookmark writes go out one at a time, so the last tap always wins.
  Future<void> _bookmarkWrites = Future.value();

  // The queue and store of the user who opened the session. They are read
  // once, not watched: rebuilding would lose answers given on this screen.
  late AnswerQueue _queue;
  late PracticeSessionStore _store;

  /// The result screen has been shown, so refused answers were reported.
  bool _resultShown = false;

  @override
  Future<PracticeState> build() async {
    final store = _store = ref.read(practiceSessionStoreProvider);
    final queue = _queue = ref.read(answerQueueProvider);
    // The session in progress is on the device, with its answers. Any other
    // is loaded from the server, which has its answers.
    final saved = store.activeFor(sessionId);
    final session = saved?.session ?? await _fetch(store);
    // Saved so it can be continued even if the app is killed offline.
    if (saved == null) unawaited(store.saveActive(session));

    queue.addListener(_onQueueChanged);
    ref.onDispose(() {
      queue.removeListener(_onQueueChanged);
      if (_resultShown) unawaited(queue.clearRefusals(sessionId));
    });

    // Resume at the first question without an answer. Answers saved on this
    // device or still waiting in the queue count as answered.
    final answers = {
      for (final answer in session.answers) answer.position: answer,
      ...?saved?.answers,
    };
    for (final upload in queue.pending(sessionId)) {
      final question = session.questions.where((q) => q.position == upload.position).firstOrNull;
      if (question != null) answers.putIfAbsent(upload.position, () => _record(question, upload));
    }
    final open = session.questions.indexWhere((q) => !answers.containsKey(q.position));
    final summary = queue.summaryFor(sessionId);
    _resultShown = summary != null;
    return PracticeState(
      session: session,
      index: open == -1 ? session.questions.length - 1 : open,
      answers: answers,
      bookmarks:
          saved?.bookmarks ??
          {
            for (final question in session.questions)
              if (question.bookmarked) question.ref,
          },
      settings: store.settings(sessionId),
      summary: summary,
      refusals: queue.refusals(sessionId),
    );
  }

  Future<PracticeSession> _fetch(PracticeSessionStore store) async {
    try {
      return await ref.read(learnRepositoryProvider).session(sessionId);
    } on AppFailure {
      // Offline: a session created in this run still works.
      final recent = store.recent(sessionId);
      if (recent == null) rethrow;
      return recent;
    }
  }

  /// A tap on an option. With instant feedback it locks the answer and
  /// reveals it; with end-of-session feedback it selects, and can change.
  void choose(int optionId, {required int timeMs}) {
    final s = _open();
    if (s == null) return;
    if (!s.session.instantFeedback) {
      if (s.selection == optionId) return;
      state = AsyncData(
        s.copyWith(
          selection: optionId,
          selectionChanges: s.selection == null ? s.selectionChanges : s.selectionChanges + 1,
        ),
      );
      return;
    }
    _submit(s, selectedOption: optionId, timeMs: timeMs);
  }

  void skip({required int timeMs}) {
    final s = _open();
    if (s != null) _submit(s, skipped: true, timeMs: timeMs);
  }

  /// The per-question limit ran out. A timeout records the full limit.
  void timeOut() {
    final s = _open();
    if (s != null) _submit(s, timedOut: true, timeMs: s.session.perQuestionMs ?? 0);
  }

  /// Shows the next question. With end-of-session feedback this first
  /// submits the pick (or a skip when nothing is picked).
  void next({int timeMs = 0}) {
    var s = state.value;
    if (s == null || s.done || s.finishing || s.isLast) return;
    if (s.answer == null) {
      if (s.session.instantFeedback) return;
      s = _submitSelection(s, timeMs);
    }
    state = AsyncData(s.copyWith(index: s.index + 1, selection: null, selectionChanges: 0));
  }

  /// Uploads what's left, then ends the session. If that can't happen now
  /// (offline), the summary is worked out here and the queue keeps retrying
  /// the finish in the background.
  Future<void> finish({int timeMs = 0}) async {
    var s = state.value;
    if (s == null || s.done || s.finishing) return;
    if (s.answer == null) {
      if (s.session.instantFeedback) return;
      s = _submitSelection(s, timeMs);
    }
    state = AsyncData(s.copyWith(finishing: true));
    final queue = _queue;
    SessionSummary summary;
    var syncing = false;
    try {
      summary = await queue.finish(sessionId);
    } on AppFailure {
      summary = localSummary(s.session, s.answers);
      syncing = queue.isFinishPending(sessionId);
    }
    // Finished on this device: nothing left to continue.
    unawaited(_store.clearActive(sessionId));
    if (!ref.mounted) return;
    _resultShown = true;
    final current = state.value ?? s;
    state = AsyncData(
      current.copyWith(
        finishing: false,
        summary: summary,
        syncing: syncing,
        refusals: queue.refusals(sessionId),
      ),
    );
    ref.invalidate(progressProvider);
  }

  /// Flips the bookmark straight away, then saves it. On failure the
  /// bookmark is put back and the failure returned for a toast.
  Future<AppFailure?> toggleBookmark() async {
    final s = state.value;
    if (s == null) return null;
    final questionRef = s.question.ref;
    final bookmarked = !s.bookmarks.contains(questionRef);
    _setBookmark(questionRef, on: bookmarked);
    final repository = ref.read(learnRepositoryProvider);
    final write = _bookmarkWrites.then(
      (_) => repository.setBookmark(questionRef, bookmarked: bookmarked),
    );
    _bookmarkWrites = write.then((_) {}, onError: (Object _) {});
    try {
      await write;
      return null;
    } on AppFailure catch (failure) {
      // Put it back, unless it has been flipped again since.
      if (ref.mounted && state.value?.bookmarks.contains(questionRef) == bookmarked) {
        _setBookmark(questionRef, on: !bookmarked);
      }
      return failure;
    }
  }

  /// The current state, if its question can still be answered.
  PracticeState? _open() {
    final s = state.value;
    if (s == null || s.done || s.finishing || s.answer != null) return null;
    return s;
  }

  PracticeState _submitSelection(PracticeState s, int timeMs) =>
      _submit(s, selectedOption: s.selection, skipped: s.selection == null, timeMs: timeMs);

  PracticeState _submit(
    PracticeState s, {
    required int timeMs,
    int? selectedOption,
    bool skipped = false,
    bool timedOut = false,
  }) {
    final question = s.question;
    final upload = AnswerUpload.create(
      ref: question.ref,
      position: question.position,
      selectedOption: selectedOption,
      skipped: skipped,
      timedOut: timedOut,
      timeMs: timeMs,
      answerChanges: s.selectionChanges,
    );
    final next = s.copyWith(
      answers: {...s.answers, question.position: _record(question, upload)},
      selection: null,
      selectionChanges: 0,
    );
    state = AsyncData(next);
    // Saved on the device at once; the upload never holds up the next question.
    unawaited(_queue.add(sessionId, upload));
    unawaited(_saveProgress(next));
    return next;
  }

  void _setBookmark(String questionRef, {required bool on}) {
    final s = state.value;
    if (s == null) return;
    final next = s.copyWith(
      bookmarks: on ? {...s.bookmarks, questionRef} : ({...s.bookmarks}..remove(questionRef)),
    );
    state = AsyncData(next);
    unawaited(_saveProgress(next));
  }

  Future<void> _saveProgress(PracticeState s) {
    if (s.done) return Future.value();
    return _store.saveProgress(sessionId, answers: s.answers, bookmarks: s.bookmarks);
  }

  /// Picks up a finish or refusals the queue got to in the background.
  void _onQueueChanged() {
    final s = state.value;
    if (s == null || !s.done) return;
    final refusals = _queue.refusals(sessionId);
    final confirmed = s.syncing ? _queue.summaryFor(sessionId) : null;
    if (confirmed != null) {
      state = AsyncData(s.copyWith(summary: confirmed, syncing: false, refusals: refusals));
      ref.invalidate(progressProvider);
    } else if (s.syncing && !_queue.isFinishPending(sessionId)) {
      // The server refused the finish for good; keep the local numbers.
      state = AsyncData(s.copyWith(syncing: false, refusals: refusals));
    } else if (!listEquals(refusals, s.refusals)) {
      state = AsyncData(s.copyWith(refusals: refusals));
    }
  }

  static SessionAnswer _record(PracticeQuestion question, AnswerUpload upload) => SessionAnswer(
    position: upload.position,
    selectedOption: upload.selectedOption,
    outcome: upload.skipped
        ? AnswerOutcome.skipped
        : upload.timedOut
        ? AnswerOutcome.timeout
        : upload.selectedOption == question.answer
        ? AnswerOutcome.correct
        : AnswerOutcome.wrong,
    timeMs: upload.timeMs,
  );
}

/// The session's numbers worked out on the device, for when the server
/// can't be reached. Attempted means every answer except skips.
SessionSummary localSummary(PracticeSession session, Map<int, SessionAnswer> answers) {
  var correct = 0;
  var wrong = 0;
  var skipped = 0;
  var attempted = 0;
  var timeMs = 0;
  final topics = <String, TopicResult>{};
  for (final question in session.questions) {
    final answer = answers[question.position];
    if (answer == null) continue;
    timeMs += answer.timeMs;
    switch (answer.outcome) {
      case AnswerOutcome.correct:
        correct++;
      case AnswerOutcome.wrong:
        wrong++;
      case AnswerOutcome.skipped:
        skipped++;
        continue;
      case AnswerOutcome.timeout:
        break;
    }
    attempted++;
    final topic = question.topic ?? question.chapter;
    if (topic == null) continue;
    final so = topics[topic.slug];
    final right = answer.outcome == AnswerOutcome.correct ? 1 : 0;
    topics[topic.slug] = TopicResult(
      slug: topic.slug,
      name: topic.name,
      answered: (so?.answered ?? 0) + 1,
      correct: (so?.correct ?? 0) + right,
    );
  }
  final neet = session.marking == Marking.neet;
  return SessionSummary(
    sessionId: session.sessionId,
    answered: attempted,
    correct: correct,
    skipped: skipped,
    timeMs: timeMs,
    score: neet ? correct * 4 - wrong : null,
    maxScore: neet ? session.questions.length * 4 : null,
    topics: topics.values.toList(),
    local: true,
  );
}

/// The one line the result screen shows for answers the server refused,
/// e.g. "2 answers couldn't be saved: the session had expired".
String? refusalNotice(List<String> reasons) {
  if (reasons.isEmpty) return null;
  final count = reasons.length;
  final what = count == 1 ? '1 answer couldn\'t be saved' : '$count answers couldn\'t be saved';
  final kinds = reasons.toSet();
  final why = kinds.length != 1
      ? null
      : switch (kinds.single) {
          'session_expired' => 'the session had expired',
          'time_up' => 'the time limit had passed',
          'unknown_question' || 'position_mismatch' => 'they didn\'t match this session',
          'not_found' => 'the session no longer exists',
          _ => null,
        };
  return why == null ? '$what.' : '$what: $why';
}
