import 'package:flutter/foundation.dart';

import '../../../core/network/json.dart';
import '../../practice/data/practice_models.dart';

/// A question in a list (`GET /v1/search`, `GET /v1/me/bookmarks`): its
/// stem and where it lives, without options or answer.
@immutable
class QuestionSummary {
  const QuestionSummary({
    required this.ref,
    required this.stem,
    required this.subject,
    this.chapter,
    this.topic,
  });

  factory QuestionSummary.fromJson(Object? json) {
    final r = JsonReader(json, 'question summary');
    return QuestionSummary(
      ref: r.string('ref'),
      stem: r.string('stem'),
      subject: r.string('subject'),
      chapter: r.optObject('chapter', NamedRef.fromJson),
      topic: r.optObject('topic', NamedRef.fromJson),
    );
  }

  /// Opaque question id.
  final String ref;

  /// In quiz markup.
  final String stem;

  /// Subject slug.
  final String subject;
  final NamedRef? chapter;
  final NamedRef? topic;

  @override
  bool operator ==(Object other) =>
      other is QuestionSummary &&
      other.ref == ref &&
      other.stem == stem &&
      other.subject == subject &&
      other.chapter == chapter &&
      other.topic == topic;

  @override
  int get hashCode => Object.hash(ref, stem, subject, chapter, topic);
}

/// A saved question (`GET /v1/me/bookmarks`), newest first.
@immutable
class Bookmark {
  const Bookmark({required this.question, required this.bookmarkedAt});

  factory Bookmark.fromJson(Object? json) {
    final r = JsonReader(json, 'bookmark');
    return Bookmark(
      question: QuestionSummary.fromJson(json),
      bookmarkedAt: r.dateTime('bookmarked_at'),
    );
  }

  final QuestionSummary question;
  final DateTime bookmarkedAt;

  String get ref => question.ref;
}

/// One page of bookmarks; [nextCursor] is null on the last page.
@immutable
class BookmarkPage {
  const BookmarkPage({required this.items, this.nextCursor});

  factory BookmarkPage.fromJson(Object? json) {
    final r = JsonReader(json, 'bookmarks');
    return BookmarkPage(
      items: r.list('items', Bookmark.fromJson),
      nextCursor: r.optString('next_cursor'),
    );
  }

  final List<Bookmark> items;
  final String? nextCursor;
}

/// One question with its answer and explanation (`GET /v1/questions/{ref}`),
/// as a practice session serves it. Options are in authored order.
@immutable
class QuestionDetail {
  const QuestionDetail({
    required this.ref,
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

  factory QuestionDetail.fromJson(Object? json) {
    final r = JsonReader(json, 'question');
    final options = r.list('options', PracticeOption.fromJson);
    final answer = r.integer('answer');
    final ids = options.map((o) => o.id).toSet();
    if (options.length < 2 || ids.length != options.length) {
      throw const FormatException('question: "options" must have distinct ids');
    }
    if (!ids.contains(answer)) {
      throw const FormatException('question: "answer" must be one of the option ids');
    }
    return QuestionDetail(
      ref: r.string('ref'),
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

  final String ref;
  final String stem;
  final List<PracticeOption> options;

  /// The `id` of the correct option.
  final int answer;
  final String explanation;

  /// 1–5.
  final int difficulty;
  final String category;
  final NamedRef? chapter;
  final NamedRef? topic;
  final bool bookmarked;
}

/// A Fun & Learn passage in the list (`GET /v1/passages`). Its text comes
/// with the session that practises it.
@immutable
class PassageItem {
  const PassageItem({
    required this.id,
    required this.title,
    required this.subject,
    required this.questionCount,
    this.chapter,
    this.difficulty = 1,
    this.done = false,
  });

  factory PassageItem.fromJson(Object? json) {
    final r = JsonReader(json, 'passage');
    return PassageItem(
      id: r.string('id'),
      title: r.string('title'),
      subject: r.string('subject'),
      chapter: r.optObject('chapter', NamedRef.fromJson),
      difficulty: r.optInt('difficulty') ?? 1,
      questionCount: r.integer('question_count'),
      done: r.flag('done'),
    );
  }

  final String id;
  final String title;

  /// Subject slug.
  final String subject;
  final NamedRef? chapter;

  /// 1–5.
  final int difficulty;
  final int questionCount;

  /// Every question of it has been answered at least once.
  final bool done;
}

/// Why a question is reported (`POST /v1/questions/{ref}/reports`).
enum ReportReason {
  wrongAnswer('wrong_answer', 'Wrong answer', 'The marked answer isn\'t right'),
  typo('typo', 'Typo', 'A spelling, number or unit is off'),
  unclear('unclear', 'Unclear', 'The question or options are confusing'),
  other('other', 'Something else', 'Tell us in the note');

  const ReportReason(this.wire, this.label, this.hint);

  final String wire;
  final String label;
  final String hint;
}

/// "Easy", "Medium" or "Hard" for a 1–5 difficulty, as the practice filter
/// groups them.
String difficultyLabel(int difficulty) => switch (difficulty) {
  <= 2 => 'Easy',
  3 => 'Medium',
  _ => 'Hard',
};
