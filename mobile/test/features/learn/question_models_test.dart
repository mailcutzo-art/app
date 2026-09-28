import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_app/features/learn/data/question_models.dart';

import '../../support/learn_samples.dart';

void main() {
  test('report reasons use the server\'s words', () {
    expect(ReportReason.values.map((r) => r.wire), ['wrong_answer', 'typo', 'unclear', 'other']);
  });

  test('difficulty reads as the practice filter groups it', () {
    expect([1, 2, 3, 4, 5].map(difficultyLabel), ['Easy', 'Easy', 'Medium', 'Hard', 'Hard']);
  });

  test('a search result needs its ref, stem and subject; chapter and topic are optional', () {
    final minimal = QuestionSummary.fromJson(const {'ref': 'q', 'stem': 's', 'subject': 'physics'});
    expect(minimal.chapter, isNull);
    expect(minimal.topic, isNull);
    expect(
      QuestionSummary.fromJson(questionSummaryJson()),
      QuestionSummary.fromJson(questionSummaryJson()),
    );
    expect(
      () => QuestionSummary.fromJson({...questionSummaryJson()}..remove('stem')),
      throwsFormatException,
    );
  });

  test('a bookmark needs its time', () {
    expect(() => Bookmark.fromJson(questionSummaryJson()), throwsFormatException);
    expect(() => BookmarkPage.fromJson(const {'next_cursor': null}), throwsFormatException);
  });

  test('a question needs distinct option ids and an answer among them', () {
    final json = questionDetailJson();
    expect(QuestionDetail.fromJson(json).options, hasLength(4));
    expect(
      () => QuestionDetail.fromJson({
        ...json,
        'options': const [
          {'id': 1, 'text': 'a'},
          {'id': 1, 'text': 'b'},
        ],
      }),
      throwsFormatException,
    );
  });

  test('a passage counts its questions; done defaults to false', () {
    final passage = PassageItem.fromJson(const {
      'id': 'p',
      'title': 't',
      'subject': 'biology',
      'question_count': 2,
    });
    expect(passage.done, isFalse);
    expect(passage.difficulty, 1);
    expect(
      () => PassageItem.fromJson(const {'id': 'p', 'title': 't', 'subject': 'b'}),
      throwsFormatException,
    );
  });
}
