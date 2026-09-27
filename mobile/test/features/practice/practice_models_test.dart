import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_app/features/learn/data/learn_models.dart';
import 'package:quiz_app/features/practice/data/practice_models.dart';

import '../../support/learn_samples.dart';

void main() {
  group('SessionSettings', () {
    test('sends exactly the documented body', () {
      const settings = SessionSettings(
        mode: PracticeMode.chapter,
        subject: 'physics',
        chapters: ['kinematics'],
      );
      expect(settings.toJson(), {
        'mode': 'chapter',
        'subject': 'physics',
        'chapters': ['kinematics'],
        'topic': null,
        'category': null,
        'count': 10,
        'difficulty': 'mixed',
        'timed': false,
        'per_question_s': null,
        'time_limit_s': null,
        'marking': 'none',
        'unseen_only': false,
      });
    });

    test('timed practice sends the per-question limit, and passages their id', () {
      const timed = SessionSettings(
        mode: PracticeMode.topic,
        subject: 'physics',
        topic: 'friction',
        count: 20,
        difficulty: Difficulty.hard,
        timed: true,
      );
      expect(timed.toJson(), containsPair('per_question_s', 30));
      expect(timed.toJson(), containsPair('difficulty', 'hard'));
      expect(
        const SessionSettings(mode: PracticeMode.passage, passageId: 'p1').toJson(),
        containsPair('passage_id', 'p1'),
      );
      expect(timed.toJson().containsKey('passage_id'), isFalse);
    });

    test('round-trips through JSON (the settings store keeps them)', () {
      const settings = SessionSettings(
        mode: PracticeMode.chapter,
        subject: 'biology',
        chapters: ['cell', 'genetics'],
        count: 30,
        difficulty: Difficulty.easy,
        timed: true,
        perQuestionS: 30,
        marking: Marking.neet,
        unseenOnly: true,
      );
      expect(SessionSettings.fromJson(settings.toJson()), settings);
      expect(
        () => SessionSettings.fromJson({...settings.toJson(), 'mode': 'duel'}),
        throwsFormatException,
      );
    });
  });

  group('PracticeSession', () {
    test('parses the documented sample', () {
      final session = PracticeSession.fromJson(sessionJson());
      expect(session.sessionId, 's-1');
      expect(session.mode, PracticeMode.chapter);
      expect(session.title, 'Physics · Motion in a Straight Line');
      expect(session.feedback, FeedbackTiming.instant);
      expect(session.instantFeedback, isTrue);
      expect(session.createdAt, DateTime.utc(2026, 9, 27, 15));
      expect(session.expiresAt, DateTime.utc(2026, 9, 28, 15));
      expect(session.perQuestionMs, isNull);
      expect(session.timed, isFalse);
      expect(session.marking, Marking.none);
      expect(session.short, isFalse);
      expect(session.answers, isEmpty);
      expect(session.finished, isFalse);

      final question = session.questions.single;
      expect(question.ref, 'q_01929f');
      expect(question.position, 1);
      expect(question.stem, contains('2 m s^{-2}'));
      expect(question.options.map((o) => o.id), [2, 0, 3, 1], reason: 'display order kept');
      expect(question.options.last, const PracticeOption(id: 1, text: '25 m'));
      expect(question.answer, 1);
      expect(question.explanation, startsWith('Starting from rest'));
      expect(question.difficulty, 2);
      expect(question.category, 'numerical');
      expect(
        question.chapter,
        const NamedRef(slug: 'kinematics', name: 'Motion in a Straight Line'),
      );
      expect(
        question.topic,
        const NamedRef(slug: 'equations-of-motion', name: 'Equations of motion'),
      );
      expect(question.bookmarked, isFalse);
    });

    test('the resume body adds answers and finished; questions come by position', () {
      final json = sessionJson()
        ..['per_question_ms'] = 30000
        ..['questions'] = [questionJson(position: 2), questionJson()]
        ..['answers'] = [
          {'position': 1, 'selected_option': 1, 'outcome': 'correct', 'time_ms': 5320},
          {'position': 2, 'selected_option': null, 'outcome': 'timeout', 'time_ms': 30000},
        ]
        ..['finished'] = false
        ..['unknown'] = {'nested': true};
      final session = PracticeSession.fromJson(json);
      expect(session.questions.map((q) => q.position), [1, 2]);
      expect(session.timed, isTrue);
      expect(session.answers, const [
        SessionAnswer(position: 1, selectedOption: 1, outcome: AnswerOutcome.correct, timeMs: 5320),
        SessionAnswer(position: 2, outcome: AnswerOutcome.timeout, timeMs: 30000),
      ]);
    });

    test('feedback: challenge sessions reveal answers at the end', () {
      final explicit = PracticeSession.fromJson(sessionJson()..['feedback'] = 'end');
      expect(explicit.feedback, FeedbackTiming.atEnd);
      final implied = PracticeSession.fromJson(
        sessionJson()
          ..['mode'] = 'challenge'
          ..remove('feedback'),
      );
      expect(implied.feedback, FeedbackTiming.atEnd);
      final unknownMode = PracticeSession.fromJson(sessionJson()..['mode'] = 'marathon');
      expect(unknownMode.mode, isNull);
      expect(unknownMode.instantFeedback, isTrue);
    });

    test('passage sessions carry their passage', () {
      final session = PracticeSession.fromJson(
        sessionJson()
          ..['mode'] = 'passage'
          ..['passage'] = {'id': 'bio-passage-01', 'title': 'Mitochondria', 'body': 'Two to four…'},
      );
      expect(session.passage?.title, 'Mitochondria');
    });

    test('missing or inconsistent fields fail with a clear FormatException', () {
      expect(
        () => PracticeSession.fromJson(sessionJson()..remove('session_id')),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            'practice session: "session_id" must be a string',
          ),
        ),
      );
      expect(
        () => PracticeSession.fromJson(sessionJson()..['questions'] = <Object?>[]),
        throwsFormatException,
      );
      expect(
        () => PracticeQuestion.fromJson(questionJson()..['answer'] = 7),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('answer'))),
      );
      expect(
        () => PracticeQuestion.fromJson(questionJson()..remove('stem')),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            'practice question: "stem" must be a string',
          ),
        ),
      );
    });
  });

  group('AnswerUpload', () {
    test('serialises the documented wire format', () {
      final answer = AnswerUpload(
        clientAnswerId: '6b0e',
        ref: 'q_01929f',
        position: 1,
        selectedOption: 1,
        timeMs: 5320,
        answeredAt: DateTime.utc(2026, 9, 27, 15, 0, 7, 412),
      );
      expect(answer.toJson(), {
        'client_answer_id': '6b0e',
        'ref': 'q_01929f',
        'position': 1,
        'selected_option': 1,
        'skipped': false,
        'timed_out': false,
        'time_ms': 5320,
        'answer_changes': 0,
        'answered_at': '2026-09-27T15:00:07.412Z',
      });
      expect(AnswerUpload.fromJson(answer.toJson()), answer);
    });

    test('new answers get a random 128-bit hex id; skips send no option', () {
      final a = AnswerUpload.create(ref: 'q', position: 1, selectedOption: 2, timeMs: 10);
      final b = AnswerUpload.create(ref: 'q', position: 1, selectedOption: 2, timeMs: 10);
      expect(a.clientAnswerId, matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(a.clientAnswerId, isNot(b.clientAnswerId));
      expect(a.answeredAt.isUtc, isTrue);

      final skipped = AnswerUpload.create(
        ref: 'q',
        position: 1,
        selectedOption: 2,
        skipped: true,
        timeMs: -5,
      );
      expect(skipped.selectedOption, isNull);
      expect(skipped.timeMs, 0);
    });
  });

  group('answers response', () {
    test('parses results, statuses and XP', () {
      final response = AnswersResponse.fromJson(const {
        'results': [
          {'client_answer_id': 'a', 'status': 'accepted', 'outcome': 'correct'},
          {'client_answer_id': 'b', 'status': 'duplicate'},
          {'client_answer_id': 'c', 'status': 'rejected', 'reason': 'time_up'},
          {'client_answer_id': 'd', 'status': 'parked'},
        ],
        'xp': {'delta': 2, 'total': 1234, 'level': 4, 'into_level': 34, 'for_next': 250},
      });
      expect(response.results.map((r) => r.status), [
        AnswerStatus.accepted,
        AnswerStatus.duplicate,
        AnswerStatus.rejected,
        null,
      ]);
      expect(response.results.first.outcome, AnswerOutcome.correct);
      expect(response.results[2].reason, 'time_up');
      expect(response.results.map((r) => r.settled), [true, true, true, false]);
      expect(
        response.xp,
        const XpUpdate(delta: 2, total: 1234, level: 4, intoLevel: 34, forNext: 250),
      );
    });

    test('a result without an id is malformed', () {
      expect(
        () => AnswersResponse.fromJson(const {
          'results': [
            {'status': 'accepted'},
          ],
        }),
        throwsFormatException,
      );
    });
  });

  group('SessionSummary', () {
    test('parses the documented finish sample', () {
      final summary = SessionSummary.fromJson(const {
        'session_id': 's-1',
        'answered': 18,
        'correct': 12,
        'skipped': 2,
        'time_ms': 312000,
        'score': 44,
        'max_score': 80,
        'topics': [
          {
            'slug': 'equations-of-motion',
            'name': 'Equations of motion',
            'answered': 9,
            'correct': 5,
          },
        ],
        'xp': {'delta': 30, 'total': 1264, 'level': 4, 'into_level': 64, 'for_next': 250},
        'tip': {
          'key': 'slow:physics:kinematics',
          'message':
              'You\'re often slower than your opponents in Kinematics. Try a timed practice set.',
          'action': 'timed_practice',
          'params': {'subject': 'physics', 'chapter': 'kinematics'},
        },
      });
      expect(summary.answered, 18);
      expect(summary.correct, 12);
      expect(summary.skipped, 2);
      expect(summary.timeMs, 312000);
      expect(summary.score, 44);
      expect(summary.maxScore, 80);
      expect(summary.topics, const [
        TopicResult(
          slug: 'equations-of-motion',
          name: 'Equations of motion',
          answered: 9,
          correct: 5,
        ),
      ]);
      expect(summary.xp?.delta, 30);
      expect(summary.tip?.action, TipAction.timedPractice);
      expect(summary.local, isFalse);
    });

    test('score, topics, XP and tip are optional', () {
      final summary = SessionSummary.fromJson(const {
        'session_id': 's-1',
        'answered': 3,
        'correct': 1,
        'extra': 'ignored',
      });
      expect(summary.score, isNull);
      expect(summary.topics, isEmpty);
      expect(summary.xp, isNull);
      expect(summary.tip, isNull);
      expect(
        () => SessionSummary.fromJson(const {'session_id': 's-1', 'answered': 3}),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('correct'))),
      );
    });
  });
}
