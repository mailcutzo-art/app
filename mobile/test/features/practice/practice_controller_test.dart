import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_app/core/auth/session.dart';
import 'package:quiz_app/features/learn/data/fake_learn_repository.dart';
import 'package:quiz_app/features/practice/data/answer_queue.dart';
import 'package:quiz_app/features/practice/data/practice_models.dart';
import 'package:quiz_app/features/practice/data/session_store.dart';
import 'package:quiz_app/features/practice/practice_controller.dart';
import 'package:quiz_app/features/practice/start_practice.dart';

import '../../support/fakes.dart';

PracticeQuestion _question(int position, String topic) => PracticeQuestion(
  ref: 'q$position',
  position: position,
  stem: 'Q$position',
  options: const [
    PracticeOption(id: 0, text: 'a'),
    PracticeOption(id: 1, text: 'b'),
  ],
  answer: 0,
  explanation: '',
  topic: NamedRef(slug: topic, name: topic.toUpperCase()),
);

void main() {
  group('localSummary', () {
    final session = PracticeSession(
      sessionId: 's',
      title: 't',
      marking: Marking.neet,
      questions: [
        _question(1, 'x'),
        _question(2, 'x'),
        _question(3, 'y'),
        _question(4, 'y'),
        _question(5, 'y'),
      ],
    );

    test('counts attempts (not skips), time, NEET score and topics', () {
      final summary = localSummary(session, const {
        1: SessionAnswer(
          position: 1,
          selectedOption: 0,
          outcome: AnswerOutcome.correct,
          timeMs: 1000,
        ),
        2: SessionAnswer(
          position: 2,
          selectedOption: 1,
          outcome: AnswerOutcome.wrong,
          timeMs: 2000,
        ),
        3: SessionAnswer(position: 3, outcome: AnswerOutcome.skipped, timeMs: 500),
        4: SessionAnswer(position: 4, outcome: AnswerOutcome.timeout, timeMs: 30000),
      });
      expect(summary.local, isTrue);
      expect(summary.answered, 3, reason: 'correct, wrong and the timeout');
      expect(summary.correct, 1);
      expect(summary.skipped, 1);
      expect(summary.timeMs, 33500);
      expect(summary.score, 4 - 1);
      expect(summary.maxScore, 20);
      expect(summary.topics, const [
        TopicResult(slug: 'x', name: 'X', answered: 2, correct: 1),
        TopicResult(slug: 'y', name: 'Y', answered: 1, correct: 0),
      ]);
      expect(summary.xp, isNull, reason: 'only the server knows XP');
    });
  });

  test('refused answers get one plain line', () {
    expect(refusalNotice(const []), isNull);
    expect(
      refusalNotice(const ['session_expired', 'session_expired']),
      '2 answers couldn\'t be saved: the session had expired',
    );
    expect(
      refusalNotice(const ['time_up']),
      '1 answer couldn\'t be saved: the time limit had passed',
    );
    expect(
      refusalNotice(const ['time_up', 'session_expired', 'x']),
      '3 answers couldn\'t be saved.',
    );
  });

  group('controller', () {
    late FakeLearnRepository learn;
    late ProviderContainer container;

    setUp(() async {
      learn = FakeLearnRepository.seeded();
      container = ProviderContainer(
        overrides: testOverrides(
          session: SignedIn(fakeUser()),
          prefs: await testPrefs(),
          learn: learn,
        ),
      );
      addTearDown(container.dispose);
      await container.read(sessionProvider.future);
    });

    Future<PracticeController> open(String sessionId) async {
      final provider = practiceControllerProvider(sessionId);
      container.listen(provider, (_, _) {});
      await container.read(provider.future);
      return container.read(provider.notifier);
    }

    PracticeState state(String sessionId) =>
        container.read(practiceControllerProvider(sessionId)).requireValue;

    test('with end-of-session feedback, picks can change and are sent on Next', () async {
      final session = await learn.createSession(
        const SessionSettings(
          mode: PracticeMode.challenge,
          subject: 'physics',
          chapters: ['laws-of-motion'],
          timeLimitS: 600,
          marking: Marking.neet,
        ),
        idempotencyKey: 'k',
      );
      expect(session.instantFeedback, isFalse);
      final controller = await open(session.sessionId);
      final [first, second] = session.questions;

      controller
        ..choose(first.options[0].id, timeMs: 1000)
        ..choose(first.options[1].id, timeMs: 2000);
      expect(state(session.sessionId).selection, first.options[1].id);
      expect(state(session.sessionId).revealed, isFalse, reason: 'no answers shown until the end');

      controller.next(timeMs: 2500);
      expect(state(session.sessionId).index, 1);
      await controller.finish(timeMs: 800);
      await container.read(answerQueueProvider).flush();

      final [a, b] = learn.uploadedAnswers;
      expect(a.selectedOption, first.options[1].id);
      expect(a.answerChanges, 1);
      expect(a.timeMs, 2500);
      expect(b.ref, second.ref);
      expect(b.skipped, isTrue, reason: 'finishing without a pick skips it');
      expect(state(session.sessionId).done, isTrue);
      expect(state(session.sessionId).summary!.score, isNotNull, reason: 'NEET marking');
    });

    test('the active session is saved as answers come in, and cleared at the end', () async {
      final session = await container
          .read(practiceStarterProvider)
          .start(
            const SessionSettings(
              mode: PracticeMode.chapter,
              subject: 'physics',
              chapters: ['laws-of-motion'],
            ),
            idempotencyKey: 'k',
          );
      final controller = await open(session.sessionId);
      final store = container.read(practiceSessionStoreProvider);
      expect(store.active()?.session.sessionId, session.sessionId);

      controller.skip(timeMs: 100);
      await pumpEventQueue();
      expect(store.active()?.answers.keys, [1]);

      controller
        ..next()
        ..skip(timeMs: 100);
      await controller.finish();
      expect(state(session.sessionId).done, isTrue);
      expect(store.active(), isNull);
    });
  });
}
