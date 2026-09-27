import 'package:flutter/foundation.dart';

import '../../../core/network/json.dart';
import '../../../core/utils/ids.dart';
import '../../learn/data/learn_models.dart';

enum PracticeMode {
  chapter,
  topic,
  category,
  review,
  bookmarks,
  challenge,
  passage;

  static PracticeMode? parse(Object? value) => values.where((m) => m.name == value).firstOrNull;
}

enum Difficulty {
  mixed('Mixed'),
  easy('Easy'),
  medium('Medium'),
  hard('Hard');

  const Difficulty(this.label);

  final String label;

  static Difficulty? parse(Object? value) => values.where((d) => d.name == value).firstOrNull;
}

/// `neet` is +4 for a correct answer and −1 for a wrong one.
enum Marking {
  none,
  neet;

  static Marking parse(Object? value) => value == 'neet' ? neet : none;
}

/// When the correct answers are shown: after each question, or at the end
/// (Self Challenge).
enum FeedbackTiming { instant, atEnd }

enum AnswerOutcome {
  correct,
  wrong,
  skipped,
  timeout;

  static AnswerOutcome? parse(Object? value) => values.where((o) => o.name == value).firstOrNull;
}

/// What the server did with one uploaded answer.
enum AnswerStatus {
  accepted,
  duplicate,
  rejected;

  static AnswerStatus? parse(Object? value) => values.where((s) => s.name == value).firstOrNull;
}

/// Body of `POST /v1/practice/sessions`.
@immutable
class SessionSettings {
  const SessionSettings({
    required this.mode,
    this.subject,
    this.chapters = const [],
    this.topic,
    this.category,
    this.count = 10,
    this.difficulty = Difficulty.mixed,
    this.timed = false,
    this.perQuestionS,
    this.timeLimitS,
    this.marking = Marking.none,
    this.unseenOnly = false,
    this.passageId,
  });

  /// Reads settings saved with [toJson].
  factory SessionSettings.fromJson(Object? json) {
    final r = JsonReader(json, 'session settings');
    return SessionSettings(
      mode: PracticeMode.parse(r.string('mode')) ?? (throw _invalidMode(r.string('mode'))),
      subject: r.optString('subject'),
      chapters: r.optList('chapters', _string),
      topic: r.optString('topic'),
      category: r.optString('category'),
      count: r.integer('count'),
      difficulty: Difficulty.parse(r.optString('difficulty')) ?? Difficulty.mixed,
      timed: r.flag('timed'),
      perQuestionS: r.optInt('per_question_s'),
      timeLimitS: r.optInt('time_limit_s'),
      marking: Marking.parse(r['marking']),
      unseenOnly: r.flag('unseen_only'),
      passageId: r.optString('passage_id'),
    );
  }

  /// The per-question limit the app uses for timed practice.
  static const defaultPerQuestionS = 30;

  final PracticeMode mode;
  final String? subject;

  /// Chapter slugs; empty means the whole subject.
  final List<String> chapters;
  final String? topic;
  final String? category;

  /// 5–50 questions.
  final int count;
  final Difficulty difficulty;
  final bool timed;
  final int? perQuestionS;
  final int? timeLimitS;
  final Marking marking;
  final bool unseenOnly;
  final String? passageId;

  /// The server rejects unknown fields, so this sends exactly the documented
  /// keys (and `passage_id` only for passages).
  Map<String, Object?> toJson() => {
    'mode': mode.name,
    'subject': subject,
    'chapters': chapters,
    'topic': topic,
    'category': category,
    'count': count,
    'difficulty': difficulty.name,
    'timed': timed,
    'per_question_s': timed ? (perQuestionS ?? defaultPerQuestionS) : null,
    'time_limit_s': timeLimitS,
    'marking': marking.name,
    'unseen_only': unseenOnly,
    if (passageId != null) 'passage_id': passageId,
  };

  @override
  bool operator ==(Object other) =>
      other is SessionSettings &&
      other.mode == mode &&
      other.subject == subject &&
      listEquals(other.chapters, chapters) &&
      other.topic == topic &&
      other.category == category &&
      other.count == count &&
      other.difficulty == difficulty &&
      other.timed == timed &&
      other.perQuestionS == perQuestionS &&
      other.timeLimitS == timeLimitS &&
      other.marking == marking &&
      other.unseenOnly == unseenOnly &&
      other.passageId == passageId;

  @override
  int get hashCode => Object.hash(
    mode,
    subject,
    Object.hashAll(chapters),
    topic,
    category,
    count,
    difficulty,
    timed,
    perQuestionS,
    timeLimitS,
    marking,
    unseenOnly,
    passageId,
  );

  @override
  String toString() => 'SessionSettings(${toJson()})';
}

/// A chapter or topic reference on a question.
@immutable
class NamedRef {
  const NamedRef({required this.slug, required this.name});

  factory NamedRef.fromJson(Object? json) {
    final r = JsonReader(json, 'chapter or topic');
    return NamedRef(slug: r.string('slug'), name: r.string('name'));
  }

  final String slug;
  final String name;

  Map<String, Object?> toJson() => {'slug': slug, 'name': name};

  @override
  bool operator ==(Object other) => other is NamedRef && other.slug == slug && other.name == name;

  @override
  int get hashCode => Object.hash(slug, name);
}

@immutable
class PracticeOption {
  const PracticeOption({required this.id, required this.text});

  factory PracticeOption.fromJson(Object? json) {
    final r = JsonReader(json, 'practice option');
    return PracticeOption(id: r.integer('id'), text: r.string('text'));
  }

  /// The option's position as authored (not its place on screen).
  final int id;
  final String text;

  Map<String, Object?> toJson() => {'id': id, 'text': text};

  @override
  bool operator ==(Object other) => other is PracticeOption && other.id == id && other.text == text;

  @override
  int get hashCode => Object.hash(id, text);
}

/// A question in a practice session, shipped with its answer so feedback is
/// instant and sessions work offline.
@immutable
class PracticeQuestion {
  const PracticeQuestion({
    required this.ref,
    required this.position,
    required this.stem,
    required this.options,
    required this.answer,
    required this.explanation,
    this.difficulty = 1,
    this.category = '',
    this.chapter,
    this.topic,
    this.bookmarked = false,
  });

  factory PracticeQuestion.fromJson(Object? json) {
    final r = JsonReader(json, 'practice question');
    final options = r.list('options', PracticeOption.fromJson);
    final answer = r.integer('answer');
    final ids = options.map((o) => o.id).toSet();
    if (options.length < 2 || ids.length != options.length) {
      throw const FormatException('practice question: "options" must have distinct ids');
    }
    if (!ids.contains(answer)) {
      throw const FormatException('practice question: "answer" must be one of the option ids');
    }
    return PracticeQuestion(
      ref: r.string('ref'),
      position: r.integer('position'),
      stem: r.string('stem'),
      options: options,
      answer: answer,
      explanation: r.optString('explanation') ?? '',
      difficulty: r.optInt('difficulty') ?? 1,
      category: r.optString('category') ?? '',
      chapter: r.optObject('chapter', NamedRef.fromJson),
      topic: r.optObject('topic', NamedRef.fromJson),
      bookmarked: r.flag('bookmarked'),
    );
  }

  /// Opaque question id.
  final String ref;

  /// 1-based place in the session.
  final int position;
  final String stem;

  /// In display order (already shuffled by the server).
  final List<PracticeOption> options;

  /// The `id` of the correct option.
  final int answer;
  final String explanation;
  final int difficulty;
  final String category;
  final NamedRef? chapter;

  /// Absent for passage questions.
  final NamedRef? topic;
  final bool bookmarked;

  Map<String, Object?> toJson() => {
    'ref': ref,
    'position': position,
    'stem': stem,
    'options': [for (final option in options) option.toJson()],
    'answer': answer,
    'explanation': explanation,
    'difficulty': difficulty,
    'category': category,
    'chapter': chapter?.toJson(),
    'topic': topic?.toJson(),
    'bookmarked': bookmarked,
  };
}

/// An answer the server already has for a session (`GET` only), or one
/// recorded on this device.
@immutable
class SessionAnswer {
  const SessionAnswer({
    required this.position,
    required this.outcome,
    this.selectedOption,
    this.timeMs = 0,
  });

  factory SessionAnswer.fromJson(Object? json) {
    final r = JsonReader(json, 'session answer');
    return SessionAnswer(
      position: r.integer('position'),
      selectedOption: r.optInt('selected_option'),
      outcome: AnswerOutcome.parse(r.string('outcome')) ?? AnswerOutcome.wrong,
      timeMs: r.optInt('time_ms') ?? 0,
    );
  }

  final int position;
  final int? selectedOption;
  final AnswerOutcome outcome;
  final int timeMs;

  Map<String, Object?> toJson() => {
    'position': position,
    'selected_option': selectedOption,
    'outcome': outcome.name,
    'time_ms': timeMs,
  };

  @override
  bool operator ==(Object other) =>
      other is SessionAnswer &&
      other.position == position &&
      other.selectedOption == selectedOption &&
      other.outcome == outcome &&
      other.timeMs == timeMs;

  @override
  int get hashCode => Object.hash(position, selectedOption, outcome, timeMs);
}

/// Fun & Learn reading passage.
@immutable
class Passage {
  const Passage({required this.id, required this.title, required this.body});

  factory Passage.fromJson(Object? json) {
    final r = JsonReader(json, 'passage');
    return Passage(id: r.string('id'), title: r.string('title'), body: r.string('body'));
  }

  final String id;
  final String title;
  final String body;

  Map<String, Object?> toJson() => {'id': id, 'title': title, 'body': body};
}

/// `POST /v1/practice/sessions` (201) and `GET /v1/practice/sessions/{id}`.
@immutable
class PracticeSession {
  const PracticeSession({
    required this.sessionId,
    required this.title,
    required this.questions,
    this.mode,
    this.feedback = FeedbackTiming.instant,
    this.createdAt,
    this.expiresAt,
    this.perQuestionMs,
    this.timeLimitMs,
    this.marking = Marking.none,
    this.short = false,
    this.answers = const [],
    this.finished = false,
    this.passage,
  });

  factory PracticeSession.fromJson(Object? json) {
    final r = JsonReader(json, 'practice session');
    final mode = PracticeMode.parse(r['mode']);
    final questions = [...r.list('questions', PracticeQuestion.fromJson)]
      ..sort((a, b) => a.position.compareTo(b.position));
    if (questions.isEmpty) {
      throw const FormatException('practice session: "questions" must not be empty');
    }
    return PracticeSession(
      sessionId: r.string('session_id'),
      mode: mode,
      title: r.optString('title') ?? '',
      feedback: switch (r.optString('feedback')) {
        'instant' => FeedbackTiming.instant,
        null => mode == PracticeMode.challenge ? FeedbackTiming.atEnd : FeedbackTiming.instant,
        _ => FeedbackTiming.atEnd,
      },
      createdAt: r.has('created_at') ? r.dateTime('created_at') : null,
      expiresAt: r.has('expires_at') ? r.dateTime('expires_at') : null,
      perQuestionMs: r.optInt('per_question_ms'),
      timeLimitMs: r.optInt('time_limit_ms'),
      marking: Marking.parse(r['marking']),
      short: r.flag('short'),
      questions: List.unmodifiable(questions),
      answers: r.optList('answers', SessionAnswer.fromJson),
      finished: r.flag('finished'),
      passage: r.optObject('passage', Passage.fromJson),
    );
  }

  final String sessionId;

  /// Null for a mode this app version doesn't know.
  final PracticeMode? mode;
  final String title;
  final FeedbackTiming feedback;
  final DateTime? createdAt;
  final DateTime? expiresAt;

  /// Per-question limit for timed practice.
  final int? perQuestionMs;

  /// Whole-session limit (Self Challenge).
  final int? timeLimitMs;
  final Marking marking;

  /// Fewer questions matched than were asked for.
  final bool short;

  /// Ordered by position.
  final List<PracticeQuestion> questions;

  /// Answers the server already counted (when resuming).
  final List<SessionAnswer> answers;
  final bool finished;
  final Passage? passage;

  bool get instantFeedback => feedback == FeedbackTiming.instant;

  bool get timed => perQuestionMs != null && perQuestionMs! > 0;

  /// Expired sessions no longer take answers; resuming one is pointless.
  bool isExpired(DateTime now) => expiresAt != null && !now.isBefore(expiresAt!);

  /// The same shape as the API response, so a saved session reads back
  /// with [PracticeSession.fromJson].
  Map<String, Object?> toJson() => {
    'session_id': sessionId,
    'mode': mode?.name,
    'title': title,
    'feedback': instantFeedback ? 'instant' : 'end',
    'created_at': createdAt?.toUtc().toIso8601String(),
    'expires_at': expiresAt?.toUtc().toIso8601String(),
    'per_question_ms': perQuestionMs,
    'time_limit_ms': timeLimitMs,
    'marking': marking.name,
    'short': short,
    'questions': [for (final question in questions) question.toJson()],
    'answers': [for (final answer in answers) answer.toJson()],
    'finished': finished,
    'passage': passage?.toJson(),
  };
}

/// One answer for `POST /v1/practice/sessions/{id}/answers`, and the record
/// the upload queue keeps on disk until the server has it.
@immutable
class AnswerUpload {
  const AnswerUpload({
    required this.clientAnswerId,
    required this.ref,
    required this.position,
    required this.selectedOption,
    required this.timeMs,
    required this.answeredAt,
    this.skipped = false,
    this.timedOut = false,
    this.answerChanges = 0,
  });

  /// A new answer with a fresh random 128-bit `client_answer_id`.
  factory AnswerUpload.create({
    required String ref,
    required int position,
    required int? selectedOption,
    required int timeMs,
    bool skipped = false,
    bool timedOut = false,
    int answerChanges = 0,
    DateTime? answeredAt,
  }) {
    final at = answeredAt ?? DateTime.now();
    return AnswerUpload(
      clientAnswerId: randomHexId(),
      ref: ref,
      position: position,
      selectedOption: skipped || timedOut ? null : selectedOption,
      skipped: skipped,
      timedOut: timedOut,
      timeMs: timeMs < 0 ? 0 : timeMs,
      answerChanges: answerChanges,
      // Millisecond precision, UTC.
      answeredAt: DateTime.fromMillisecondsSinceEpoch(at.millisecondsSinceEpoch, isUtc: true),
    );
  }

  factory AnswerUpload.fromJson(Object? json) {
    final r = JsonReader(json, 'answer');
    return AnswerUpload(
      clientAnswerId: r.string('client_answer_id'),
      ref: r.string('ref'),
      position: r.integer('position'),
      selectedOption: r.optInt('selected_option'),
      skipped: r.flag('skipped'),
      timedOut: r.flag('timed_out'),
      timeMs: r.integer('time_ms'),
      answerChanges: r.optInt('answer_changes') ?? 0,
      answeredAt: r.dateTime('answered_at').toUtc(),
    );
  }

  final String clientAnswerId;
  final String ref;
  final int position;

  /// An option `id`, or null when skipped or timed out.
  final int? selectedOption;
  final bool skipped;
  final bool timedOut;
  final int timeMs;
  final int answerChanges;
  final DateTime answeredAt;

  Map<String, Object?> toJson() => {
    'client_answer_id': clientAnswerId,
    'ref': ref,
    'position': position,
    'selected_option': selectedOption,
    'skipped': skipped,
    'timed_out': timedOut,
    'time_ms': timeMs,
    'answer_changes': answerChanges,
    'answered_at': answeredAt.toUtc().toIso8601String(),
  };

  @override
  bool operator ==(Object other) =>
      other is AnswerUpload &&
      other.clientAnswerId == clientAnswerId &&
      other.ref == ref &&
      other.position == position &&
      other.selectedOption == selectedOption &&
      other.skipped == skipped &&
      other.timedOut == timedOut &&
      other.timeMs == timeMs &&
      other.answerChanges == answerChanges &&
      other.answeredAt == answeredAt;

  @override
  int get hashCode => Object.hash(
    clientAnswerId,
    ref,
    position,
    selectedOption,
    skipped,
    timedOut,
    timeMs,
    answerChanges,
    answeredAt,
  );

  @override
  String toString() => 'AnswerUpload(${toJson()})';
}

/// The server's verdict on one uploaded answer.
@immutable
class AnswerResult {
  const AnswerResult({
    required this.clientAnswerId,
    required this.status,
    this.outcome,
    this.reason,
  });

  factory AnswerResult.fromJson(Object? json) {
    final r = JsonReader(json, 'answer result');
    return AnswerResult(
      clientAnswerId: r.string('client_answer_id'),
      status: AnswerStatus.parse(r.string('status')),
      outcome: AnswerOutcome.parse(r['outcome']),
      reason: r.optString('reason'),
    );
  }

  final String clientAnswerId;

  /// Null for a status this app version doesn't know; the answer is kept and
  /// sent again (the server then reports it as a duplicate).
  final AnswerStatus? status;
  final AnswerOutcome? outcome;

  /// Why it was rejected: `unknown_question`, `position_mismatch`,
  /// `session_expired` or `time_up`.
  final String? reason;

  /// Accepted, duplicate and rejected answers all leave the queue.
  bool get settled => status != null;
}

/// `POST /v1/practice/sessions/{id}/answers` (200).
@immutable
class AnswersResponse {
  const AnswersResponse({required this.results, this.xp});

  factory AnswersResponse.fromJson(Object? json) {
    final r = JsonReader(json, 'answers response');
    return AnswersResponse(
      results: r.list('results', AnswerResult.fromJson),
      xp: r.optObject('xp', XpUpdate.fromJson),
    );
  }

  final List<AnswerResult> results;
  final XpUpdate? xp;
}

@immutable
class XpUpdate {
  const XpUpdate({
    required this.delta,
    required this.total,
    required this.level,
    required this.intoLevel,
    required this.forNext,
    this.capped = false,
    this.resetsAt,
  });

  factory XpUpdate.fromJson(Object? json) {
    final r = JsonReader(json, 'xp');
    return XpUpdate(
      delta: r.integer('delta'),
      total: r.integer('total'),
      level: r.integer('level'),
      intoLevel: r.optInt('into_level') ?? 0,
      forNext: r.optInt('for_next') ?? 0,
      capped: r.flag('capped'),
      resetsAt: r.has('resets_at') ? r.dateTime('resets_at') : null,
    );
  }

  final int delta;
  final int total;
  final int level;

  /// XP earned inside the current level, and XP the level needs in all.
  final int intoLevel;
  final int forNext;

  /// The daily practice XP limit was reached, so [delta] is smaller than
  /// the answers would earn; it resets at [resetsAt].
  final bool capped;
  final DateTime? resetsAt;

  @override
  bool operator ==(Object other) =>
      other is XpUpdate &&
      other.delta == delta &&
      other.total == total &&
      other.level == level &&
      other.intoLevel == intoLevel &&
      other.forNext == forNext &&
      other.capped == capped &&
      other.resetsAt == resetsAt;

  @override
  int get hashCode => Object.hash(delta, total, level, intoLevel, forNext, capped, resetsAt);
}

/// A row of the result screen ("Equations of motion 5/9").
@immutable
class TopicResult {
  const TopicResult({
    required this.slug,
    required this.name,
    required this.answered,
    required this.correct,
  });

  factory TopicResult.fromJson(Object? json) {
    final r = JsonReader(json, 'topic result');
    return TopicResult(
      slug: r.string('slug'),
      name: r.string('name'),
      answered: r.integer('answered'),
      correct: r.integer('correct'),
    );
  }

  final String slug;
  final String name;
  final int answered;
  final int correct;

  @override
  bool operator ==(Object other) =>
      other is TopicResult &&
      other.slug == slug &&
      other.name == name &&
      other.answered == answered &&
      other.correct == correct;

  @override
  int get hashCode => Object.hash(slug, name, answered, correct);
}

/// `POST /v1/practice/sessions/{id}/finish`, or the same numbers worked out
/// on this device while the server can't be reached ([local]).
@immutable
class SessionSummary {
  const SessionSummary({
    required this.sessionId,
    required this.answered,
    required this.correct,
    required this.skipped,
    required this.timeMs,
    this.score,
    this.maxScore,
    this.topics = const [],
    this.xp,
    this.tip,
    this.local = false,
  });

  factory SessionSummary.fromJson(Object? json) {
    final r = JsonReader(json, 'session summary');
    return SessionSummary(
      sessionId: r.string('session_id'),
      answered: r.integer('answered'),
      correct: r.integer('correct'),
      skipped: r.optInt('skipped') ?? 0,
      timeMs: r.optInt('time_ms') ?? 0,
      score: r.optInt('score'),
      maxScore: r.optInt('max_score'),
      topics: r.optList('topics', TopicResult.fromJson),
      xp: r.optObject('xp', XpUpdate.fromJson),
      tip: r.optObject('tip', Tip.fromJson),
    );
  }

  final String sessionId;

  /// Questions attempted: every answer except skips.
  final int answered;
  final int correct;
  final int skipped;
  final int timeMs;

  /// Only with NEET marking (+4 / −1).
  final int? score;
  final int? maxScore;
  final List<TopicResult> topics;
  final XpUpdate? xp;
  final Tip? tip;

  /// Computed on this device; the server hasn't confirmed it yet.
  final bool local;
}

String _string(Object? value) => switch (value) {
  final String s => s,
  _ => throw const FormatException('session settings: "chapters" must be a list of strings'),
};

FormatException _invalidMode(String mode) =>
    FormatException('session settings: unknown mode "$mode"');
