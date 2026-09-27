import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../../core/auth/user.dart';
import '../../../core/network/app_failure.dart';
import '../../practice/data/practice_models.dart';
import 'learn_models.dart';
import 'learn_repository.dart';

/// Calls of [FakeLearnRepository] that tests can make fail.
enum FakeLearnOp {
  catalog,
  progress,
  createSession,
  session,
  uploadAnswers,
  finish,
  tips,
  dismissTip,
  bookmark,
  reviews,
}

/// In-memory stand-in for the Learn API, seeded with sample questions from
/// `content/questions`. Used by tests and by the debug "Demo data" switch.
///
/// It follows the contract where the app can notice: options come shuffled
/// with their authored ids, session creation is idempotent per key, answers
/// are de-duplicated by `client_answer_id` and only the first per position
/// counts, wrong answers go to review, and progress, labels and tips are
/// worked out from the answers.
class FakeLearnRepository implements LearnRepository {
  FakeLearnRepository({
    required this._subjects,
    this.latency = Duration.zero,
    this.tipsUnlockAt = 5,
    int seed = 7,
    DateTime Function()? now,
  }) : _random = Random(seed),
       _now = now ?? DateTime.now;

  /// The sample content: Physics (NEET and JEE) and Biology (NEET).
  factory FakeLearnRepository.seeded({Duration latency = Duration.zero}) =>
      FakeLearnRepository(subjects: sampleSubjects, latency: latency);

  final List<FakeSubject> _subjects;
  final Random _random;
  final DateTime Function() _now;

  /// Delay before every response, to see loading states.
  Duration latency;

  /// Answers needed before tips appear. Lower than the server's 20 so the
  /// demo shows tips sooner.
  final int tipsUnlockAt;

  /// Calls that fail until removed from the map.
  final Map<FakeLearnOp, AppFailure> failures = {};

  /// When set, [progress] returns this instead of working it out.
  Progress? progressOverride;

  /// Today's practice XP limit has been reached: XP updates say so.
  bool xpCapped = false;

  /// Every `createSession` call: the settings and the idempotency key.
  final List<(SessionSettings, String)> createCalls = [];

  /// Every `uploadAnswers` batch, in order.
  final List<List<AnswerUpload>> uploadCalls = [];

  /// Session ids passed to `finishSession`, in order.
  final List<String> finishCalls = [];

  /// Every `setBookmark` call.
  final List<(String, bool)> bookmarkCalls = [];

  final _sessions = <String, _FakeSession>{};
  final _sessionByKey = <String, String>{};
  final _answerIds = <String>{};
  final _attempts = <String, List<_Attempt>>{};
  final _bookmarks = <String>{};
  final _reviewDue = <String>{};
  final _dismissedTips = <String>{};
  var _xpTotal = 1200;
  var _sessionCounter = 0;

  List<AnswerUpload> get uploadedAnswers => [for (final batch in uploadCalls) ...batch];

  /// Ends [sessionId]'s lifetime early: later answers come back `rejected`
  /// with `session_expired`.
  void expireSession(String sessionId) => _find(sessionId).expired = true;

  Set<String> get bookmarks => Set.unmodifiable(_bookmarks);

  // ---------------------------------------------------------------- catalog

  @override
  Future<Catalog> catalog(Goal goal) async {
    await _call(FakeLearnOp.catalog);
    return Catalog(
      goal: goal.name,
      version: 'demo',
      subjects: [
        for (final subject in _subjectsFor(goal))
          CatalogSubject(
            slug: subject.slug,
            name: subject.name,
            tone: subject.tone,
            icon: subject.icon,
            questionCount: subject.questions.length,
            chapters: [
              for (final chapter in subject.chapters)
                CatalogChapter(
                  slug: chapter.slug,
                  name: chapter.name,
                  order: chapter.order,
                  questionCount: chapter.questions.length,
                  battleReady: chapter.questions.length >= 7,
                  topics: [
                    for (final (slug, name) in chapter.topics)
                      CatalogTopic(
                        slug: slug,
                        name: name,
                        questionCount: chapter.questions.where((q) => q.topic == slug).length,
                      ),
                  ],
                ),
            ],
          ),
      ],
    );
  }

  @override
  Future<Progress> progress(Goal goal) async {
    await _call(FakeLearnOp.progress);
    if (progressOverride case final fixed?) return fixed;
    final subjects = _subjectsFor(goal);
    final latest = _sessions.values.where((s) => !s.finished).toList()
      ..sort((a, b) => b.number.compareTo(a.number));
    return Progress(
      subjects: [
        for (final subject in subjects)
          SubjectProgress(
            slug: subject.slug,
            answered: _count(subject.questions),
            correct: _count(subject.questions, correct: true),
            chapters: [
              for (final chapter in subject.chapters)
                ChapterProgress(
                  slug: chapter.slug,
                  answered: _count(chapter.questions),
                  correct: _count(chapter.questions, correct: true),
                  seen: chapter.questions.where((q) => _attempts.containsKey(q.ref)).length,
                  label: _label(chapter.questions),
                ),
            ],
          ),
      ],
      reviewsDue: _reviewDue.length,
      continuePractice: latest.isEmpty
          ? null
          : ContinuePractice(
              sessionId: latest.first.id,
              title: latest.first.title,
              answered: latest.first.answers.length,
              count: latest.first.questions.length,
            ),
      tip: _tips(subjects).firstOrNull,
    );
  }

  // --------------------------------------------------------------- sessions

  @override
  Future<PracticeSession> createSession(
    SessionSettings settings, {
    required String idempotencyKey,
  }) async {
    createCalls.add((settings, idempotencyKey));
    await _call(FakeLearnOp.createSession);
    if (_sessionByKey[idempotencyKey] case final id?) return _sessions[id]!.toSession(_bookmarks);

    final pool = _pool(settings);
    if (pool.isEmpty) {
      throw const ConflictFailure('No questions match these settings.', code: 'NO_QUESTIONS');
    }
    // Unseen questions first, then those seen longest ago.
    final ordered = [...pool]..sort((a, b) => (_lastSeen(a) ?? -1).compareTo(_lastSeen(b) ?? -1));
    final picked = ordered.take(settings.count).toList();
    final now = _now().toUtc();
    final id = 'demo-${++_sessionCounter}-${_random.nextInt(1 << 30).toRadixString(16)}';
    final session = _FakeSession(
      id: id,
      number: _sessionCounter,
      settings: settings,
      title: _title(settings),
      createdAt: now,
      short: picked.length < settings.count,
      questions: [
        for (final (i, q) in picked.indexed)
          (
            q,
            PracticeQuestion(
              ref: q.ref,
              position: i + 1,
              stem: q.stem,
              options: [
                for (final index in List.generate(q.options.length, (k) => k)..shuffle(_random))
                  PracticeOption(id: index, text: q.options[index]),
              ],
              answer: q.answer,
              explanation: q.explanation,
              difficulty: q.difficulty,
              category: q.category,
              chapter: NamedRef(slug: q.chapter.slug, name: q.chapter.name),
              topic: NamedRef(slug: q.topic, name: q.chapter.topicName(q.topic)),
            ),
          ),
      ],
    );
    _sessions[id] = session;
    _sessionByKey[idempotencyKey] = id;
    return session.toSession(_bookmarks);
  }

  @override
  Future<PracticeSession> session(String sessionId) async {
    await _call(FakeLearnOp.session);
    return _find(sessionId).toSession(_bookmarks);
  }

  @override
  Future<AnswersResponse> uploadAnswers(String sessionId, List<AnswerUpload> answers) async {
    uploadCalls.add(List.unmodifiable(answers));
    await _call(FakeLearnOp.uploadAnswers);
    final session = _find(sessionId);
    var delta = 0;
    final results = <AnswerResult>[];
    for (final answer in answers) {
      if (!_answerIds.add(answer.clientAnswerId)) {
        results.add(
          AnswerResult(clientAnswerId: answer.clientAnswerId, status: AnswerStatus.duplicate),
        );
        continue;
      }
      final entry = session.questions.where((e) => e.$2.position == answer.position).firstOrNull;
      final String? rejection;
      if (!session.questions.any((e) => e.$1.ref == answer.ref)) {
        rejection = 'unknown_question';
      } else if (entry == null || entry.$1.ref != answer.ref) {
        rejection = 'position_mismatch';
      } else if (session.finished || session.expired) {
        rejection = 'session_expired';
      } else {
        rejection = null;
      }
      if (rejection != null) {
        results.add(
          AnswerResult(
            clientAnswerId: answer.clientAnswerId,
            status: AnswerStatus.rejected,
            reason: rejection,
          ),
        );
        continue;
      }
      if (session.answers.containsKey(answer.position)) {
        // Only the first answer per position counts.
        results.add(
          AnswerResult(clientAnswerId: answer.clientAnswerId, status: AnswerStatus.duplicate),
        );
        continue;
      }
      final question = entry!.$1;
      final outcome = answer.skipped
          ? AnswerOutcome.skipped
          : answer.timedOut
          ? AnswerOutcome.timeout
          : answer.selectedOption == question.answer
          ? AnswerOutcome.correct
          : AnswerOutcome.wrong;
      final limit = session.perQuestionMs;
      final timeMs = min(answer.timeMs, limit ?? 10 * 60 * 1000);
      session.answers[answer.position] = SessionAnswer(
        position: answer.position,
        selectedOption: answer.selectedOption,
        outcome: outcome,
        timeMs: timeMs,
      );
      _attempts
          .putIfAbsent(question.ref, () => [])
          .add(_Attempt(correct: outcome == AnswerOutcome.correct, at: _attemptClock++));
      if (outcome == AnswerOutcome.correct) {
        if (session.settings.mode == PracticeMode.review) _reviewDue.remove(question.ref);
      } else if (outcome != AnswerOutcome.skipped) {
        _reviewDue.add(question.ref);
      }
      final xp = outcome == AnswerOutcome.correct ? 2 : 1;
      delta += xp;
      session.xp += xp;
      results.add(
        AnswerResult(
          clientAnswerId: answer.clientAnswerId,
          status: AnswerStatus.accepted,
          outcome: outcome,
        ),
      );
    }
    _xpTotal += delta;
    return AnswersResponse(results: results, xp: _xp(delta));
  }

  var _attemptClock = 0;

  @override
  Future<SessionSummary> finishSession(String sessionId) async {
    finishCalls.add(sessionId);
    await _call(FakeLearnOp.finish);
    final session = _find(sessionId)..finished = true;
    final counted = session.answers.values;
    final correct = counted.where((a) => a.outcome == AnswerOutcome.correct).length;
    final wrong = counted.where((a) => a.outcome == AnswerOutcome.wrong).length;
    final skipped = counted.where((a) => a.outcome == AnswerOutcome.skipped).length;
    final topics = <String, (String, int, int)>{};
    for (final (question, practice) in session.questions) {
      final answer = session.answers[practice.position];
      if (answer == null || answer.outcome == AnswerOutcome.skipped) continue;
      final (name, answered, right) = topics[question.topic] ?? (practice.topic!.name, 0, 0);
      topics[question.topic] = (
        name,
        answered + 1,
        right + (answer.outcome == AnswerOutcome.correct ? 1 : 0),
      );
    }
    final subject = _subjects.where((s) => s.slug == session.subjectSlug).firstOrNull;
    final neet = session.settings.marking == Marking.neet;
    return SessionSummary(
      sessionId: session.id,
      answered: counted.length - skipped,
      correct: correct,
      skipped: skipped,
      timeMs: counted.fold(0, (sum, a) => sum + a.timeMs),
      score: neet ? correct * 4 - wrong : null,
      maxScore: neet ? session.questions.length * 4 : null,
      topics: [
        for (final MapEntry(key: slug, value: (name, answered, right)) in topics.entries)
          TopicResult(slug: slug, name: name, answered: answered, correct: right),
      ],
      xp: _xp(session.xp),
      tip: _tips([?subject]).firstOrNull,
    );
  }

  // ------------------------------------------------------ tips and bookmarks

  @override
  Future<TipsOverview> tips() async {
    await _call(FakeLearnOp.tips);
    final total = _attempts.values.fold(0, (sum, list) => sum + list.length);
    final unlocked = total >= tipsUnlockAt;
    return TipsOverview(
      unlocked: unlocked,
      answersNeeded: unlocked ? 0 : tipsUnlockAt - total,
      tips: unlocked ? _tips(_subjects).take(5).toList() : const [],
    );
  }

  @override
  Future<void> dismissTip(String key) async {
    await _call(FakeLearnOp.dismissTip);
    _dismissedTips.add(key);
  }

  @override
  Future<void> setBookmark(String ref, {required bool bookmarked}) async {
    bookmarkCalls.add((ref, bookmarked));
    await _call(FakeLearnOp.bookmark);
    bookmarked ? _bookmarks.add(ref) : _bookmarks.remove(ref);
  }

  @override
  Future<ReviewsSummary> reviewsSummary() async {
    await _call(FakeLearnOp.reviews);
    final everWrong = _attempts.entries.where((e) => e.value.any((a) => !a.correct)).length;
    return ReviewsSummary(due: _reviewDue.length, total: everWrong);
  }

  // ---------------------------------------------------------------- helpers

  Future<void> _call(FakeLearnOp op) async {
    if (latency > Duration.zero) await Future<void>.delayed(latency);
    if (failures[op] case final failure?) throw failure;
  }

  _FakeSession _find(String id) =>
      _sessions[id] ??
      (throw const NotFoundFailure('That practice session doesn\'t exist.', code: 'NOT_FOUND'));

  Iterable<FakeSubject> _subjectsFor(Goal goal) =>
      _subjects.where((s) => s.goals.contains(goal.name));

  List<FakeQuestion> _pool(SessionSettings s) {
    final subjects = s.subject == null
        ? _subjects
        : _subjects.where((subject) => subject.slug == s.subject);
    Iterable<FakeQuestion> pool = [for (final subject in subjects) ...subject.questions];
    pool = switch (s.mode) {
      PracticeMode.chapter || PracticeMode.challenge =>
        s.chapters.isEmpty ? pool : pool.where((q) => s.chapters.contains(q.chapter.slug)),
      PracticeMode.topic => pool.where((q) => q.topic == s.topic),
      PracticeMode.category => pool.where((q) => q.category == s.category),
      PracticeMode.review => pool.where((q) => _reviewDue.contains(q.ref)),
      PracticeMode.bookmarks => pool.where((q) => _bookmarks.contains(q.ref)),
      PracticeMode.passage => const <FakeQuestion>[],
    };
    pool = switch (s.difficulty) {
      Difficulty.mixed => pool,
      Difficulty.easy => pool.where((q) => q.difficulty <= 2),
      Difficulty.medium => pool.where((q) => q.difficulty == 3),
      Difficulty.hard => pool.where((q) => q.difficulty >= 4),
    };
    if (s.unseenOnly) pool = pool.where((q) => !_attempts.containsKey(q.ref));
    return pool.toList();
  }

  int? _lastSeen(FakeQuestion q) => _attempts[q.ref]?.last.at;

  String _title(SessionSettings s) {
    final subject = _subjects.where((x) => x.slug == s.subject).firstOrNull;
    final chapter = s.chapters.length == 1 ? subject?.chapter(s.chapters.single) : null;
    return switch (s.mode) {
      PracticeMode.review => 'Review',
      PracticeMode.bookmarks => 'Bookmarks',
      PracticeMode.topic when subject != null =>
        '${subject.name} · ${subject.topicName(s.topic ?? '')}',
      PracticeMode.category when subject != null =>
        '${subject.name} · ${_categoryTitles[s.category] ?? s.category}',
      _ when chapter != null => '${subject!.name} · ${chapter.name}',
      _ => subject?.name ?? 'Practice',
    };
  }

  int _count(Iterable<FakeQuestion> questions, {bool correct = false}) => questions.fold(
    0,
    (sum, q) => sum + (_attempts[q.ref]?.where((a) => !correct || a.correct).length ?? 0),
  );

  /// The contract's rule: smoothed accuracy (c + 2) / (n + 4).
  ChapterLabel? _label(List<FakeQuestion> questions) {
    final n = _count(questions);
    final c = _count(questions, correct: true);
    final smoothed = (c + 2) / (n + 4);
    if (n >= 10 && smoothed >= 0.75) return ChapterLabel.strong;
    if (n >= 5 && smoothed <= 0.5) return ChapterLabel.needsWork;
    return null;
  }

  List<Tip> _tips(Iterable<FakeSubject> subjects) {
    final total = _attempts.values.fold(0, (sum, list) => sum + list.length);
    if (total < tipsUnlockAt) return const [];
    final tips = <Tip>[];
    for (final subject in subjects) {
      for (final chapter in subject.chapters) {
        for (final (topic, name) in chapter.topics) {
          final questions = chapter.questions.where((q) => q.topic == topic);
          final n = _count(questions);
          final c = _count(questions, correct: true);
          if (n >= 4 && (c + 2) / (n + 4) <= 0.5) {
            tips.add(
              Tip(
                key: 'weak_topic:${subject.slug}:$topic',
                rule: 'weak_topic',
                message: 'Focus on $name. You got $c of $n right.',
                action: TipAction.practice,
                params: {'subject': subject.slug, 'topic': topic, 'count': '10'},
              ),
            );
          }
        }
      }
    }
    if (_reviewDue.isNotEmpty) {
      final n = _reviewDue.length;
      tips.add(
        Tip(
          key: 'reviews_due',
          rule: 'reviews_due',
          message: n == 1
              ? '1 question is waiting for review.'
              : '$n questions are waiting for review.',
          action: TipAction.review,
        ),
      );
    }
    for (final subject in subjects) {
      for (final chapter in subject.chapters) {
        if (chapter.questions.any((q) => _attempts.containsKey(q.ref))) continue;
        tips.add(
          Tip(
            key: 'new_chapter:${subject.slug}:${chapter.slug}',
            rule: 'new_chapter',
            message: 'You haven\'t tried ${chapter.name} yet. Start with 10 easy questions.',
            action: TipAction.startChapter,
            params: {'subject': subject.slug, 'chapter': chapter.slug},
          ),
        );
      }
    }
    return [
      for (final tip in tips)
        if (!_dismissedTips.contains(tip.key)) tip,
    ];
  }

  XpUpdate _xp(int delta) {
    int floor(int level) => 25 * (level - 1) * (level + 2);
    var level = 1;
    while (level < 100 && floor(level + 1) <= _xpTotal) {
      level++;
    }
    final now = _now();
    return XpUpdate(
      delta: delta,
      total: _xpTotal,
      level: level,
      intoLevel: _xpTotal - floor(level),
      forNext: floor(level + 1) - floor(level),
      capped: xpCapped,
      resetsAt: xpCapped ? DateTime(now.year, now.month, now.day + 1).toUtc() : null,
    );
  }
}

const _categoryTitles = {
  'concept': 'Concepts',
  'numerical': 'Numericals',
  'factual': 'Facts',
  'application': 'Applications',
};

class _Attempt {
  const _Attempt({required this.correct, required this.at});

  final bool correct;
  final int at;
}

class _FakeSession {
  _FakeSession({
    required this.id,
    required this.number,
    required this.settings,
    required this.title,
    required this.createdAt,
    required this.short,
    required this.questions,
  });

  final String id;
  final int number;
  final SessionSettings settings;
  final String title;
  final DateTime createdAt;
  final bool short;
  final List<(FakeQuestion, PracticeQuestion)> questions;
  final answers = <int, SessionAnswer>{};
  var finished = false;
  var expired = false;
  var xp = 0;

  int? get perQuestionMs =>
      settings.timed ? (settings.perQuestionS ?? SessionSettings.defaultPerQuestionS) * 1000 : null;

  String? get subjectSlug => settings.subject ?? questions.firstOrNull?.$1.subject;

  PracticeSession toSession(Set<String> bookmarks) => PracticeSession(
    sessionId: id,
    mode: settings.mode,
    title: title,
    feedback: settings.mode == PracticeMode.challenge
        ? FeedbackTiming.atEnd
        : FeedbackTiming.instant,
    createdAt: createdAt,
    expiresAt: createdAt.add(const Duration(hours: 24)),
    perQuestionMs: perQuestionMs,
    timeLimitMs: settings.timeLimitS == null ? null : settings.timeLimitS! * 1000,
    marking: settings.marking,
    short: short,
    questions: [
      for (final (_, q) in questions)
        PracticeQuestion(
          ref: q.ref,
          position: q.position,
          stem: q.stem,
          options: q.options,
          answer: q.answer,
          explanation: q.explanation,
          difficulty: q.difficulty,
          category: q.category,
          chapter: q.chapter,
          topic: q.topic,
          bookmarked: bookmarks.contains(q.ref),
        ),
    ],
    answers: List.unmodifiable(answers.values),
    finished: finished,
  );
}

/// A subject of the sample content.
@immutable
class FakeSubject {
  const FakeSubject({
    required this.slug,
    required this.name,
    required this.tone,
    required this.icon,
    required this.goals,
    required this.chapters,
  });

  final String slug;
  final String name;
  final String tone;
  final String icon;

  /// Exams that include this subject.
  final Set<String> goals;
  final List<FakeChapter> chapters;

  List<FakeQuestion> get questions => [for (final c in chapters) ...c.questions];

  FakeChapter? chapter(String slug) => chapters.where((c) => c.slug == slug).firstOrNull;

  String topicName(String topic) => chapters
      .expand((c) => c.topics)
      .firstWhere((t) => t.$1 == topic, orElse: () => (topic, topic))
      .$2;
}

@immutable
class FakeChapter {
  const FakeChapter({
    required this.subject,
    required this.slug,
    required this.name,
    required this.order,
    required this.topics,
    required this.questions,
  });

  final String subject;
  final String slug;
  final String name;
  final int order;

  /// (slug, name) pairs.
  final List<(String, String)> topics;
  final List<FakeQuestion> questions;

  String topicName(String topic) =>
      topics.firstWhere((t) => t.$1 == topic, orElse: () => (topic, topic)).$2;
}

/// A question as authored: [answer] indexes [options] before shuffling.
@immutable
class FakeQuestion {
  const FakeQuestion({
    required this.ref,
    required this.chapter,
    required this.topic,
    required this.category,
    required this.difficulty,
    required this.stem,
    required this.options,
    required this.answer,
    required this.explanation,
  });

  final String ref;
  final FakeChapterRef chapter;
  final String topic;
  final String category;
  final int difficulty;
  final String stem;
  final List<String> options;
  final int answer;
  final String explanation;

  String get subject => chapter.subject;
}

/// Where a [FakeQuestion] lives (kept separate so questions can be const).
@immutable
class FakeChapterRef {
  const FakeChapterRef(this.subject, this.slug, this.name, this.topics);

  final String subject;
  final String slug;
  final String name;
  final List<(String, String)> topics;

  String topicName(String topic) =>
      topics.firstWhere((t) => t.$1 == topic, orElse: () => (topic, topic)).$2;
}

const _kinematics = FakeChapterRef('physics', 'kinematics', 'Motion in a Straight Line', [
  ('speed-velocity', 'Speed and velocity'),
  ('equations-of-motion', 'Equations of motion'),
]);

const _lawsOfMotion = FakeChapterRef('physics', 'laws-of-motion', 'Laws of Motion', [
  ('newtons-laws', 'Newton\'s laws'),
  ('friction', 'Friction'),
]);

const _cell = FakeChapterRef('biology', 'cell', 'Cell: The Unit of Life', [
  ('cell-types', 'Prokaryotic and eukaryotic cells'),
  ('organelles', 'Cell organelles'),
]);

FakeChapter _chapter(FakeChapterRef ref, int order, List<FakeQuestion> questions) => FakeChapter(
  subject: ref.subject,
  slug: ref.slug,
  name: ref.name,
  order: order,
  topics: ref.topics,
  questions: questions,
);

/// Ten questions copied from `content/questions/**`.
final sampleSubjects = [
  FakeSubject(
    slug: 'physics',
    name: 'Physics',
    tone: 'sky',
    icon: 'physics',
    goals: const {'neet', 'jee'},
    chapters: [
      _chapter(_kinematics, 1, const [
        FakeQuestion(
          ref: 'phy-kin-001',
          chapter: _kinematics,
          topic: 'speed-velocity',
          category: 'concept',
          difficulty: 1,
          stem:
              'A runner completes one full lap of a circular track and stops at the start. '
              'What is the runner\'s displacement?',
          options: [
            'Zero',
            'Equal to the circumference',
            'Equal to the diameter',
            'Equal to the radius',
          ],
          answer: 0,
          explanation:
              'Displacement is the straight-line change in position. The runner ends where they '
              'started, so the displacement is zero even though the distance covered is one full '
              'circumference.',
        ),
        FakeQuestion(
          ref: 'phy-kin-003',
          chapter: _kinematics,
          topic: 'speed-velocity',
          category: 'concept',
          difficulty: 2,
          stem: 'What does the slope of a position–time graph give at any instant?',
          options: ['Acceleration', 'Instantaneous velocity', 'Displacement', 'Distance travelled'],
          answer: 1,
          explanation:
              'The slope of a position–time graph is dx/dt, the velocity at that instant. The '
              'slope of a velocity–time graph gives the acceleration.',
        ),
        FakeQuestion(
          ref: 'phy-kin-005',
          chapter: _kinematics,
          topic: 'equations-of-motion',
          category: 'numerical',
          difficulty: 2,
          stem:
              'A car starts from rest and accelerates uniformly at 2 m s^{-2}. How far does it '
              'travel in 5 s?',
          options: ['10 m', '25 m', '50 m', '100 m'],
          answer: 1,
          explanation: 'Starting from rest (u = 0), s = ut + ½at^2 = ½ × 2 × 5^2 = 25 m.',
        ),
        FakeQuestion(
          ref: 'phy-kin-006',
          chapter: _kinematics,
          topic: 'equations-of-motion',
          category: 'numerical',
          difficulty: 3,
          stem:
              'A ball is thrown straight up at 20 m s^{-1}. Taking g = 10 m s^{-2}, how high does '
              'it rise?',
          options: ['10 m', '40 m', '2 m', '20 m'],
          answer: 3,
          explanation:
              'At the highest point v = 0, so v^2 = u^2 − 2gh gives h = u^2/2g = 400/20 = 20 m.',
        ),
      ]),
      _chapter(_lawsOfMotion, 2, const [
        FakeQuestion(
          ref: 'phy-lom-002',
          chapter: _lawsOfMotion,
          topic: 'newtons-laws',
          category: 'numerical',
          difficulty: 1,
          stem: 'A net force of 10 N acts on a 2 kg block. What is its acceleration?',
          options: ['5 m s^{-2}', '20 m s^{-2}', '0.2 m s^{-2}', '12 m s^{-2}'],
          answer: 0,
          explanation: 'From F = ma, a = F/m = 10 N ÷ 2 kg = 5 m s^{-2}.',
        ),
        FakeQuestion(
          ref: 'phy-lom-006',
          chapter: _lawsOfMotion,
          topic: 'friction',
          category: 'concept',
          difficulty: 2,
          stem: 'Why is it harder to start a heavy box sliding than to keep it sliding?',
          options: [
            'Kinetic friction is greater than static friction',
            'The box gets lighter once it moves',
            'Maximum static friction is greater than kinetic friction',
            'Air resistance acts only at the start',
          ],
          answer: 2,
          explanation:
              'Limiting static friction (μ_s N) is larger than kinetic friction (μ_k N) because '
              'μ_s > μ_k, so more force is needed to start the motion than to keep it going.',
        ),
      ]),
    ],
  ),
  FakeSubject(
    slug: 'biology',
    name: 'Biology',
    tone: 'mint',
    icon: 'biology',
    goals: const {'neet'},
    chapters: [
      _chapter(_cell, 1, const [
        FakeQuestion(
          ref: 'bio-cell-001',
          chapter: _cell,
          topic: 'organelles',
          category: 'factual',
          difficulty: 1,
          stem: 'Which organelle is known as the powerhouse of the cell?',
          options: ['Ribosome', 'Golgi apparatus', 'Lysosome', 'Mitochondrion'],
          answer: 3,
          explanation:
              'Mitochondria carry out aerobic respiration and make most of the cell\'s ATP, which '
              'is why they are called the powerhouse of the cell.',
        ),
        FakeQuestion(
          ref: 'bio-cell-002',
          chapter: _cell,
          topic: 'cell-types',
          category: 'factual',
          difficulty: 1,
          stem: 'Which of these organisms is a prokaryote?',
          options: ['*Escherichia coli*', '*Amoeba*', 'Yeast', '*Chlamydomonas*'],
          answer: 0,
          explanation:
              'Bacteria such as *Escherichia coli* are prokaryotes: they have no nuclear membrane '
              'and no membrane-bound organelles. *Amoeba*, yeast and *Chlamydomonas* are all '
              'eukaryotes.',
        ),
        FakeQuestion(
          ref: 'bio-cell-003',
          chapter: _cell,
          topic: 'cell-types',
          category: 'concept',
          difficulty: 2,
          stem: 'Which structure is found in both prokaryotic and eukaryotic cells?',
          options: [
            'A nucleus with a nuclear membrane',
            'Mitochondria',
            'Ribosomes',
            'Endoplasmic reticulum',
          ],
          answer: 2,
          explanation:
              'Every cell makes proteins, so every cell has ribosomes (70S in prokaryotes, 80S in '
              'the eukaryotic cytoplasm). A true nucleus and membrane-bound organelles such as '
              'mitochondria and ER occur only in eukaryotes.',
        ),
        FakeQuestion(
          ref: 'bio-cell-004',
          chapter: _cell,
          topic: 'organelles',
          category: 'factual',
          difficulty: 2,
          stem: 'Which organelle modifies, sorts and packages proteins for secretion?',
          options: ['Smooth endoplasmic reticulum', 'Golgi apparatus', 'Centriole', 'Nucleolus'],
          answer: 1,
          explanation:
              'Proteins made on the rough ER travel to the Golgi apparatus, which modifies them '
              '(for example by adding sugars), sorts them and packs them into vesicles for '
              'secretion.',
        ),
      ]),
    ],
  ),
];
