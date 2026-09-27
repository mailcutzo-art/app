import 'package:flutter/foundation.dart';

import '../../../core/network/json.dart';

/// Subjects, chapters and topics of one exam (`GET /v1/catalog`).
@immutable
class Catalog {
  const Catalog({
    required this.goal,
    required this.version,
    required this.subjects,
    this.fromCache = false,
  });

  /// Throws [FormatException] on malformed payloads.
  factory Catalog.fromJson(Object? json, {bool fromCache = false}) {
    final r = JsonReader(json, 'catalog');
    return Catalog(
      goal: r.string('goal'),
      version: r.optString('version') ?? '',
      subjects: r.list('subjects', CatalogSubject.fromJson),
      fromCache: fromCache,
    );
  }

  final String goal;
  final String version;
  final List<CatalogSubject> subjects;

  /// Served from the on-device copy because the server couldn't be reached.
  /// Client-side only; not part of the payload.
  final bool fromCache;

  CatalogSubject? subject(String slug) => subjects.where((s) => s.slug == slug).firstOrNull;

  /// The subject that has a chapter with [chapterSlug].
  CatalogSubject? subjectOfChapter(String chapterSlug) =>
      subjects.where((s) => s.chapter(chapterSlug) != null).firstOrNull;
}

@immutable
class CatalogSubject {
  const CatalogSubject({
    required this.slug,
    required this.name,
    required this.tone,
    required this.icon,
    required this.questionCount,
    required this.chapters,
  });

  factory CatalogSubject.fromJson(Object? json) {
    final r = JsonReader(json, 'catalog subject');
    final chapters = [...r.list('chapters', CatalogChapter.fromJson)]
      ..sort((a, b) => a.order.compareTo(b.order));
    return CatalogSubject(
      slug: r.string('slug'),
      name: r.string('name'),
      tone: r.optString('tone') ?? '',
      icon: r.optString('icon') ?? '',
      questionCount: r.integer('question_count'),
      chapters: List.unmodifiable(chapters),
    );
  }

  final String slug;
  final String name;

  /// Design system pastel tone name (`sky`, `mint`…); unknown names fall back.
  final String tone;

  /// Icon name (`physics`, `chemistry`…); unknown names fall back.
  final String icon;
  final int questionCount;

  /// In display order.
  final List<CatalogChapter> chapters;

  CatalogChapter? chapter(String slug) => chapters.where((c) => c.slug == slug).firstOrNull;
}

@immutable
class CatalogChapter {
  const CatalogChapter({
    required this.slug,
    required this.name,
    required this.order,
    required this.questionCount,
    required this.battleReady,
    required this.topics,
  });

  factory CatalogChapter.fromJson(Object? json) {
    final r = JsonReader(json, 'catalog chapter');
    return CatalogChapter(
      slug: r.string('slug'),
      name: r.string('name'),
      order: r.optInt('order') ?? 0,
      questionCount: r.integer('question_count'),
      battleReady: r.flag('battle_ready'),
      topics: r.optList('topics', CatalogTopic.fromJson),
    );
  }

  final String slug;
  final String name;
  final int order;
  final int questionCount;

  /// Enough battle questions (at least 7) to be offered for battles.
  final bool battleReady;
  final List<CatalogTopic> topics;
}

@immutable
class CatalogTopic {
  const CatalogTopic({required this.slug, required this.name, required this.questionCount});

  factory CatalogTopic.fromJson(Object? json) {
    final r = JsonReader(json, 'catalog topic');
    return CatalogTopic(
      slug: r.string('slug'),
      name: r.string('name'),
      questionCount: r.integer('question_count'),
    );
  }

  final String slug;
  final String name;
  final int questionCount;

  @override
  bool operator ==(Object other) =>
      other is CatalogTopic &&
      other.slug == slug &&
      other.name == name &&
      other.questionCount == questionCount;

  @override
  int get hashCode => Object.hash(slug, name, questionCount);
}

/// The single word shown next to a chapter; never a chart.
enum ChapterLabel {
  strong,
  needsWork;

  /// Unknown or missing labels read as no label.
  static ChapterLabel? parse(Object? value) => switch (value) {
    'strong' => strong,
    'needs_work' => needsWork,
    _ => null,
  };
}

/// The user's own progress for the Learn tab (`GET /v1/me/progress`).
@immutable
class Progress {
  const Progress({
    required this.subjects,
    required this.reviewsDue,
    this.continuePractice,
    this.tip,
  });

  factory Progress.fromJson(Object? json) {
    final r = JsonReader(json, 'progress');
    return Progress(
      subjects: r.list('subjects', SubjectProgress.fromJson),
      reviewsDue: r.integer('reviews_due'),
      continuePractice: r.optObject('continue', ContinuePractice.fromJson),
      tip: r.optObject('tip', Tip.fromJson),
    );
  }

  final List<SubjectProgress> subjects;
  final int reviewsDue;

  /// The latest unfinished practice session.
  final ContinuePractice? continuePractice;

  /// The top coach tip.
  final Tip? tip;

  SubjectProgress? subject(String slug) => subjects.where((s) => s.slug == slug).firstOrNull;

  ChapterProgress? chapter(String subjectSlug, String chapterSlug) =>
      subject(subjectSlug)?.chapters.where((c) => c.slug == chapterSlug).firstOrNull;
}

@immutable
class SubjectProgress {
  const SubjectProgress({
    required this.slug,
    required this.answered,
    required this.correct,
    required this.chapters,
  });

  factory SubjectProgress.fromJson(Object? json) {
    final r = JsonReader(json, 'subject progress');
    return SubjectProgress(
      slug: r.string('slug'),
      answered: r.integer('answered'),
      correct: r.integer('correct'),
      chapters: r.optList('chapters', ChapterProgress.fromJson),
    );
  }

  final String slug;
  final int answered;
  final int correct;
  final List<ChapterProgress> chapters;
}

@immutable
class ChapterProgress {
  const ChapterProgress({
    required this.slug,
    required this.answered,
    required this.correct,
    this.seen = 0,
    this.label,
  });

  factory ChapterProgress.fromJson(Object? json) {
    final r = JsonReader(json, 'chapter progress');
    return ChapterProgress(
      slug: r.string('slug'),
      answered: r.integer('answered'),
      correct: r.integer('correct'),
      seen: r.optInt('seen') ?? 0,
      label: ChapterLabel.parse(r['label']),
    );
  }

  final String slug;

  /// All answers, including repeats.
  final int answered;
  final int correct;

  /// Distinct questions answered.
  final int seen;
  final ChapterLabel? label;

  @override
  bool operator ==(Object other) =>
      other is ChapterProgress &&
      other.slug == slug &&
      other.answered == answered &&
      other.correct == correct &&
      other.seen == seen &&
      other.label == label;

  @override
  int get hashCode => Object.hash(slug, answered, correct, seen, label);
}

/// "Continue practice": the latest unfinished session.
@immutable
class ContinuePractice {
  const ContinuePractice({
    required this.sessionId,
    required this.title,
    required this.answered,
    required this.count,
  });

  factory ContinuePractice.fromJson(Object? json) {
    final r = JsonReader(json, 'continue practice');
    return ContinuePractice(
      sessionId: r.string('session_id'),
      title: r.string('title'),
      answered: r.integer('answered'),
      count: r.integer('count'),
    );
  }

  final String sessionId;
  final String title;
  final int answered;
  final int count;

  @override
  bool operator ==(Object other) =>
      other is ContinuePractice &&
      other.sessionId == sessionId &&
      other.title == title &&
      other.answered == answered &&
      other.count == count;

  @override
  int get hashCode => Object.hash(sessionId, title, answered, count);
}

/// What a coach tip's button opens.
enum TipAction {
  practice('practice'),
  timedPractice('timed_practice'),
  practiceCategory('practice_category'),
  review('review'),
  startChapter('start_chapter'),
  practiceMedium('practice_medium'),
  battle('battle');

  const TipAction(this.wire);

  final String wire;

  /// Actions this app version doesn't know read as null (the tip shows no button).
  static TipAction? parse(Object? value) => values.where((a) => a.wire == value).firstOrNull;
}

/// A short instruction with one button (e.g. "Focus on Projectile motion").
@immutable
class Tip {
  const Tip({
    required this.key,
    required this.message,
    required this.action,
    this.rule,
    this.params = const {},
  });

  factory Tip.fromJson(Object? json) {
    final r = JsonReader(json, 'tip');
    return Tip(
      key: r.string('key'),
      rule: r.optString('rule'),
      message: r.string('message'),
      action: TipAction.parse(r.string('action')),
      params: r.stringMap('params'),
    );
  }

  final String key;
  final String? rule;
  final String message;
  final TipAction? action;

  /// e.g. `{"subject": "physics", "topic": "projectile-motion", "count": "10"}`.
  final Map<String, String> params;

  @override
  bool operator ==(Object other) =>
      other is Tip &&
      other.key == key &&
      other.rule == rule &&
      other.message == message &&
      other.action == action &&
      mapEquals(other.params, params);

  @override
  int get hashCode => Object.hash(
    key,
    rule,
    message,
    action,
    Object.hashAllUnordered(params.entries.map((e) => Object.hash(e.key, e.value))),
  );
}

/// `GET /v1/me/tips`.
@immutable
class TipsOverview {
  const TipsOverview({required this.unlocked, required this.answersNeeded, required this.tips});

  factory TipsOverview.fromJson(Object? json) {
    final r = JsonReader(json, 'tips');
    return TipsOverview(
      unlocked: r.boolean('unlocked'),
      answersNeeded: r.optInt('answers_needed') ?? 0,
      tips: r.optList('tips', Tip.fromJson),
    );
  }

  /// False until the user has 20 answers.
  final bool unlocked;

  /// How many more answers unlock tips.
  final int answersNeeded;

  /// Up to 5, most important first.
  final List<Tip> tips;
}

/// `GET /v1/me/reviews/summary`.
@immutable
class ReviewsSummary {
  const ReviewsSummary({required this.due, required this.total});

  factory ReviewsSummary.fromJson(Object? json) {
    final r = JsonReader(json, 'reviews summary');
    return ReviewsSummary(due: r.integer('due'), total: r.integer('total'));
  }

  final int due;
  final int total;

  @override
  bool operator ==(Object other) =>
      other is ReviewsSummary && other.due == due && other.total == total;

  @override
  int get hashCode => Object.hash(due, total);
}
