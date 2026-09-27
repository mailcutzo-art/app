import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_app/features/learn/data/learn_models.dart';
import 'package:quiz_app/features/learn/tip_actions.dart';
import 'package:quiz_app/features/practice/data/practice_models.dart';

Tip _tip(TipAction? action, [Map<String, String> params = const {}]) =>
    Tip(key: 'k', message: 'm', action: action, params: params);

void main() {
  group('tipDestination follows the table in docs/api-learn.md', () {
    test('practice: a topic set, or the chapter when no topic is named', () {
      expect(
        tipDestination(
          _tip(TipAction.practice, {
            'subject': 'physics',
            'topic': 'projectile-motion',
            'count': '10',
          }),
        ),
        const TipPractice(
          SessionSettings(mode: PracticeMode.topic, subject: 'physics', topic: 'projectile-motion'),
        ),
      );
      expect(
        tipDestination(_tip(TipAction.practice, {'subject': 'physics', 'chapter': 'kinematics'})),
        const TipPractice(
          SessionSettings(mode: PracticeMode.chapter, subject: 'physics', chapters: ['kinematics']),
        ),
      );
    });

    test('timed_practice: 30 s per question for that topic or chapter', () {
      expect(
        tipDestination(
          _tip(TipAction.timedPractice, {'subject': 'physics', 'chapter': 'kinematics'}),
        ),
        const TipPractice(
          SessionSettings(
            mode: PracticeMode.chapter,
            subject: 'physics',
            chapters: ['kinematics'],
            timed: true,
            perQuestionS: 30,
          ),
        ),
      );
    });

    test('practice_category: category mode for the subject', () {
      expect(
        tipDestination(
          _tip(TipAction.practiceCategory, {
            'subject': 'physics',
            'category': 'numerical',
            'count': '10',
          }),
        ),
        const TipPractice(
          SessionSettings(mode: PracticeMode.category, subject: 'physics', category: 'numerical'),
        ),
      );
    });

    test('review: review mode, across subjects unless one is named', () {
      expect(
        tipDestination(_tip(TipAction.review)),
        const TipPractice(SessionSettings(mode: PracticeMode.review, count: 20)),
      );
      expect(
        tipDestination(_tip(TipAction.review, {'subject': 'biology'})),
        const TipPractice(
          SessionSettings(mode: PracticeMode.review, subject: 'biology', count: 20),
        ),
      );
    });

    test('start_chapter is easy chapter practice; practice_medium is medium', () {
      const params = {'subject': 'biology', 'chapter': 'genetics'};
      expect(
        tipDestination(_tip(TipAction.startChapter, params)),
        const TipPractice(
          SessionSettings(
            mode: PracticeMode.chapter,
            subject: 'biology',
            chapters: ['genetics'],
            difficulty: Difficulty.easy,
          ),
        ),
      );
      expect(
        tipDestination(_tip(TipAction.practiceMedium, params)),
        const TipPractice(
          SessionSettings(
            mode: PracticeMode.chapter,
            subject: 'biology',
            chapters: ['genetics'],
            difficulty: Difficulty.medium,
          ),
        ),
      );
    });

    test('battle opens the Battle tab on the tip\'s subject and chapter', () {
      expect(
        tipDestination(_tip(TipAction.battle, {'subject': 'physics', 'chapter': 'kinematics'})),
        const TipOpens('/battle?subject=physics&chapter=kinematics'),
      );
    });

    test('nothing to do for unknown actions or missing params', () {
      expect(tipDestination(_tip(null)), isNull);
      expect(tipDestination(_tip(TipAction.practice)), isNull, reason: 'no subject');
      expect(tipDestination(_tip(TipAction.startChapter, {'subject': 'physics'})), isNull);
      expect(tipDestination(_tip(TipAction.practiceCategory, {'subject': 'physics'})), isNull);
    });

    test('count is kept within what the server accepts', () {
      SessionSettings settings(String count) =>
          (tipDestination(_tip(TipAction.practice, {'subject': 'physics', 'count': count}))!
                  as TipPractice)
              .settings;
      expect(settings('20').count, 20);
      expect(settings('500').count, 50);
      expect(settings('1').count, 5);
      expect(settings('lots').count, 10);
    });
  });

  test('button labels', () {
    expect(tipButtonLabel(_tip(TipAction.practice, {'count': '10'})), 'Practise 10');
    expect(tipButtonLabel(_tip(TipAction.timedPractice)), 'Timed practice');
    expect(
      tipButtonLabel(_tip(TipAction.practiceCategory, {'category': 'numerical'})),
      'Practise 10 numericals',
    );
    expect(tipButtonLabel(_tip(TipAction.review)), 'Review');
    expect(tipButtonLabel(_tip(TipAction.startChapter)), 'Start');
    expect(tipButtonLabel(_tip(TipAction.practiceMedium)), 'Practise medium');
    expect(tipButtonLabel(_tip(TipAction.battle)), 'Battle');
  });
}
