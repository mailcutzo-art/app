import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_app/features/learn/data/learn_models.dart';

import '../../support/learn_samples.dart';

void main() {
  group('Catalog', () {
    test('parses the documented sample', () {
      final catalog = Catalog.fromJson(catalogJson());
      expect(catalog.goal, 'neet');
      expect(catalog.version, '4f1c2a');
      expect(catalog.fromCache, isFalse);
      final physics = catalog.subjects.single;
      expect(physics.slug, 'physics');
      expect(physics.name, 'Physics');
      expect(physics.tone, 'sky');
      expect(physics.icon, 'physics');
      expect(physics.questionCount, 16);
      final chapter = physics.chapters.single;
      expect(chapter.slug, 'kinematics');
      expect(chapter.name, 'Motion in a Straight Line');
      expect(chapter.order, 1);
      expect(chapter.questionCount, 8);
      expect(chapter.battleReady, isTrue);
      expect(chapter.topics, const [
        CatalogTopic(slug: 'speed-velocity', name: 'Speed and velocity', questionCount: 4),
        CatalogTopic(slug: 'equations-of-motion', name: 'Equations of motion', questionCount: 4),
      ]);
      expect(catalog.subject('physics'), same(physics));
      expect(catalog.subjectOfChapter('kinematics'), same(physics));
      expect(catalog.subject('maths'), isNull);
    });

    test('ignores unknown fields and sorts chapters by order', () {
      final json = catalogJson();
      json['etag'] = 'x';
      final subject = (json['subjects']! as List<Object?>).single! as Map<String, Object?>;
      subject['colour'] = 'blue';
      subject['chapters'] = [
        {'slug': 'b', 'name': 'B', 'order': 2, 'question_count': 1, 'new_field': true},
        {'slug': 'a', 'name': 'A', 'order': 1, 'question_count': 1},
      ];
      final catalog = Catalog.fromJson(json);
      expect(catalog.subjects.single.chapters.map((c) => c.slug), ['a', 'b']);
      final a = catalog.subjects.single.chapters.first;
      expect(a.battleReady, isFalse, reason: 'optional flags default to false');
      expect(a.topics, isEmpty);
    });

    test('a missing required field fails with a clear FormatException', () {
      final json = catalogJson();
      ((json['subjects']! as List<Object?>).single! as Map<String, Object?>).remove(
        'question_count',
      );
      expect(
        () => Catalog.fromJson(json),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            'catalog subject: "question_count" must be an integer',
          ),
        ),
      );
      expect(() => Catalog.fromJson(const {'goal': 'neet'}), throwsFormatException);
      expect(() => Catalog.fromJson('nope'), throwsFormatException);
    });

    test('a wrongly typed field fails too', () {
      final json = catalogJson()..['goal'] = 7;
      expect(
        () => Catalog.fromJson(json),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('"goal"'))),
      );
    });
  });

  group('Progress', () {
    test('parses the documented sample', () {
      final progress = Progress.fromJson(progressJson());
      expect(progress.reviewsDue, 3);
      final physics = progress.subjects.single;
      expect(physics.answered, 23);
      expect(physics.correct, 15);
      expect(
        progress.chapter('physics', 'kinematics'),
        const ChapterProgress(
          slug: 'kinematics',
          answered: 12,
          correct: 7,
          seen: 6,
          label: ChapterLabel.needsWork,
        ),
      );
      expect(
        progress.continuePractice,
        const ContinuePractice(
          sessionId: 's-1',
          title: 'Physics · Motion in a Straight Line',
          answered: 12,
          count: 20,
        ),
      );
      expect(
        progress.tip,
        const Tip(
          key: 'weak_topic:physics:projectile-motion',
          message: 'Focus on Projectile motion. You got 4 of 11 right.',
          action: TipAction.practice,
          params: {'subject': 'physics', 'topic': 'projectile-motion', 'count': '10'},
        ),
      );
    });

    test('continue, tip and labels may be null; unknown labels read as none', () {
      final json = progressJson()
        ..['continue'] = null
        ..remove('tip')
        ..['server_time'] = '2026-09-27T15:00:00Z';
      final chapters =
          ((json['subjects']! as List<Object?>).single! as Map<String, Object?>)['chapters']!
              as List<Object?>;
      (chapters.single! as Map<String, Object?>)['label'] = 'improving';
      final progress = Progress.fromJson(json);
      expect(progress.continuePractice, isNull);
      expect(progress.tip, isNull);
      expect(progress.chapter('physics', 'kinematics')!.label, isNull);
      expect(ChapterLabel.parse('strong'), ChapterLabel.strong);
      expect(ChapterLabel.parse(null), isNull);
    });

    test('missing required fields fail clearly', () {
      expect(
        () => Progress.fromJson(progressJson()..remove('reviews_due')),
        throwsA(
          isA<FormatException>().having((e) => e.message, 'message', contains('reviews_due')),
        ),
      );
      final json = progressJson();
      (json['continue']! as Map<String, Object?>).remove('session_id');
      expect(
        () => Progress.fromJson(json),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            'continue practice: "session_id" must be a string',
          ),
        ),
      );
    });
  });

  group('Tip', () {
    test('parses the tips list with rules, unknown actions and numeric params', () {
      final overview = TipsOverview.fromJson(const {
        'unlocked': true,
        'answers_needed': 0,
        'tips': [
          {
            'key': 'weak_topic:…',
            'rule': 'weak_topic',
            'message': 'Focus on Projectile motion. You got 4 of 11 right.',
            'action': 'practice',
            'params': {'subject': 'physics', 'topic': 'projectile-motion', 'count': 10},
          },
          {'key': 'new', 'message': 'Try the new thing.', 'action': 'teleport'},
        ],
      });
      expect(overview.unlocked, isTrue);
      expect(overview.answersNeeded, 0);
      expect(overview.tips.first.rule, 'weak_topic');
      expect(overview.tips.first.params['count'], '10');
      expect(overview.tips.last.action, isNull, reason: 'this app version can\'t act on it');
      expect(overview.tips.last.params, isEmpty);
    });

    test('locked tips say how many answers are needed', () {
      final overview = TipsOverview.fromJson(const {
        'unlocked': false,
        'answers_needed': 12,
        'tips': <Object?>[],
      });
      expect(overview.unlocked, isFalse);
      expect(overview.answersNeeded, 12);
      expect(overview.tips, isEmpty);
    });

    test('every documented action is known', () {
      for (final wire in [
        'practice',
        'timed_practice',
        'practice_category',
        'review',
        'start_chapter',
        'practice_medium',
        'battle',
      ]) {
        expect(TipAction.parse(wire)?.wire, wire);
      }
    });

    test('a tip without a message is malformed', () {
      expect(
        () => Tip.fromJson(const {'key': 'k', 'action': 'review'}),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('message'))),
      );
    });
  });

  test('reviews summary', () {
    expect(
      ReviewsSummary.fromJson(const {'due': 5, 'total': 23, 'extra': 1}),
      const ReviewsSummary(due: 5, total: 23),
    );
    expect(() => ReviewsSummary.fromJson(const {'due': 5}), throwsFormatException);
  });
}
