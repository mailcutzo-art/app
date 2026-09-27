import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_app/core/auth/user.dart';
import 'package:quiz_app/core/network/app_failure.dart';
import 'package:quiz_app/features/learn/data/fake_learn_repository.dart';
import 'package:quiz_app/features/learn/data/learn_models.dart';
import 'package:quiz_app/features/practice/data/practice_models.dart';

/// The demo data behaves like the contract, so the flow can be tried and
/// tested without a backend.
void main() {
  late FakeLearnRepository learn;

  setUp(() => learn = FakeLearnRepository.seeded());

  const kinematics = SessionSettings(
    mode: PracticeMode.chapter,
    subject: 'physics',
    chapters: ['kinematics'],
  );

  AnswerUpload answer(PracticeQuestion q, {bool correct = true}) => AnswerUpload.create(
    ref: q.ref,
    position: q.position,
    selectedOption: correct ? q.answer : q.options.firstWhere((o) => o.id != q.answer).id,
    timeMs: 3000,
  );

  test('the catalog follows the exam: Biology is NEET only', () async {
    final neet = await learn.catalog(Goal.neet);
    final jee = await learn.catalog(Goal.jee);
    expect(neet.subjects.map((s) => s.slug), ['physics', 'biology']);
    expect(jee.subjects.map((s) => s.slug), ['physics']);
    final physics = neet.subject('physics')!;
    expect(physics.questionCount, 6);
    expect(physics.chapters.map((c) => c.questionCount), [4, 2]);
    expect(physics.chapters.first.topics.map((t) => t.questionCount), [2, 2]);
  });

  test('sessions keep authored option ids, and a retried key returns the same session', () async {
    final session = await learn.createSession(kinematics, idempotencyKey: 'k1');
    final again = await learn.createSession(kinematics, idempotencyKey: 'k1');
    final other = await learn.createSession(kinematics, idempotencyKey: 'k2');

    expect(again.sessionId, session.sessionId);
    expect(other.sessionId, isNot(session.sessionId));
    expect(session.short, isTrue, reason: '4 questions match, 10 were asked for');
    expect(session.title, 'Physics · Motion in a Straight Line');
    final first = session.questions.first;
    expect(first.ref, 'phy-kin-001');
    expect(first.options.map((o) => o.id).toSet(), {0, 1, 2, 3});
    expect(first.options.firstWhere((o) => o.id == first.answer).text, 'Zero');
  });

  test('nothing matching is 409 NO_QUESTIONS', () async {
    await expectLater(
      learn.createSession(
        const SessionSettings(
          mode: PracticeMode.chapter,
          subject: 'physics',
          chapters: ['kinematics'],
          difficulty: Difficulty.hard,
        ),
        idempotencyKey: 'k',
      ),
      throwsA(isA<ConflictFailure>().having((f) => f.code, 'code', 'NO_QUESTIONS')),
    );
  });

  test('answers: first per position counts, ids de-duplicate, strangers are rejected', () async {
    final session = await learn.createSession(kinematics, idempotencyKey: 'k');
    final q1 = session.questions.first;
    final first = answer(q1);
    final response = await learn.uploadAnswers(session.sessionId, [
      first,
      first,
      answer(q1, correct: false),
      AnswerUpload.create(ref: 'nope', position: 2, selectedOption: 0, timeMs: 1),
    ]);
    expect(response.results.map((r) => r.status), [
      AnswerStatus.accepted,
      AnswerStatus.duplicate,
      AnswerStatus.duplicate,
      AnswerStatus.rejected,
    ]);
    expect(response.results.first.outcome, AnswerOutcome.correct);
    expect(response.results.last.reason, 'unknown_question');
    expect(response.xp?.delta, 2);

    final resumed = await learn.session(session.sessionId);
    expect(resumed.answers.single.position, 1);
  });

  test('wrong answers go to review; a right review answer takes them out', () async {
    final session = await learn.createSession(kinematics, idempotencyKey: 'k');
    await learn.uploadAnswers(session.sessionId, [
      for (final q in session.questions.take(2)) answer(q, correct: false),
    ]);
    expect((await learn.reviewsSummary()).due, 2);
    expect((await learn.progress(Goal.neet)).reviewsDue, 2);

    final review = await learn.createSession(
      const SessionSettings(mode: PracticeMode.review, count: 20),
      idempotencyKey: 'r',
    );
    expect(review.questions, hasLength(2));
    await learn.uploadAnswers(review.sessionId, [answer(review.questions.first)]);
    expect((await learn.reviewsSummary()).due, 1);
  });

  test('progress: seen counts, continue practice, labels by the contract\'s formula', () async {
    final session = await learn.createSession(kinematics, idempotencyKey: 'k');
    await learn.uploadAnswers(session.sessionId, [answer(session.questions.first)]);

    var progress = await learn.progress(Goal.neet);
    expect(progress.chapter('physics', 'kinematics')!.seen, 1);
    expect(progress.continuePractice?.sessionId, session.sessionId);
    expect(progress.continuePractice?.answered, 1);

    await learn.finishSession(session.sessionId);
    progress = await learn.progress(Goal.neet);
    expect(progress.continuePractice, isNull, reason: 'finished sessions are not continued');

    // Ten right answers: (10 + 2) / (11 + 4) = 0.8 >= 0.75 with 11 answers.
    for (var i = 0; i < 3; i++) {
      final s = await learn.createSession(kinematics, idempotencyKey: 'k$i');
      await learn.uploadAnswers(s.sessionId, [for (final q in s.questions) answer(q)]);
    }
    progress = await learn.progress(Goal.neet);
    expect(progress.chapter('physics', 'kinematics')!.answered, 13);
    expect(progress.chapter('physics', 'kinematics')!.label, ChapterLabel.strong);
  });

  test('a weak topic becomes a practice tip once enough answers are in', () async {
    for (var i = 0; i < 2; i++) {
      final s = await learn.createSession(
        const SessionSettings(mode: PracticeMode.topic, subject: 'physics', topic: 'friction'),
        idempotencyKey: 'f$i',
      );
      await learn.uploadAnswers(s.sessionId, [
        for (final q in s.questions) answer(q, correct: false),
      ]);
    }
    for (var i = 0; i < 2; i++) {
      final s = await learn.createSession(
        const SessionSettings(mode: PracticeMode.topic, subject: 'physics', topic: 'friction'),
        idempotencyKey: 'g$i',
      );
      await learn.uploadAnswers(s.sessionId, [
        for (final q in s.questions) answer(q, correct: false),
      ]);
    }
    final tips = await learn.tips();
    expect(tips.unlocked, isFalse, reason: '4 answers, 5 needed');

    final s = await learn.createSession(kinematics, idempotencyKey: 'x');
    await learn.uploadAnswers(s.sessionId, [answer(s.questions.first)]);
    final unlocked = await learn.tips();
    expect(unlocked.unlocked, isTrue);
    final weak = unlocked.tips.first;
    expect(weak.action, TipAction.practice);
    expect(weak.message, 'Focus on Friction. You got 0 of 4 right.');
    expect(weak.params, {'subject': 'physics', 'topic': 'friction', 'count': '10'});

    await learn.dismissTip(weak.key);
    expect((await learn.tips()).tips.map((t) => t.key), isNot(contains(weak.key)));
  });

  test('finishing sums up the counted answers per topic', () async {
    final session = await learn.createSession(kinematics, idempotencyKey: 'k');
    final [q1, q2, q3, _] = session.questions;
    await learn.uploadAnswers(session.sessionId, [
      answer(q1),
      answer(q2, correct: false),
      AnswerUpload.create(
        ref: q3.ref,
        position: q3.position,
        selectedOption: null,
        skipped: true,
        timeMs: 500,
      ),
    ]);
    final summary = await learn.finishSession(session.sessionId);
    expect(summary.answered, 2);
    expect(summary.correct, 1);
    expect(summary.skipped, 1);
    expect(summary.timeMs, 6500);
    expect(summary.topics.single, isA<TopicResult>().having((t) => t.answered, 'answered', 2));
    expect(summary.xp?.delta, 4);
    expect((await learn.finishSession(session.sessionId)).correct, 1, reason: 'idempotent');
  });

  test('failures can be scripted per call', () async {
    learn.failures[FakeLearnOp.catalog] = const ServerFailure();
    await expectLater(learn.catalog(Goal.neet), throwsA(isA<ServerFailure>()));
    learn.failures.clear();
    expect((await learn.catalog(Goal.neet)).subjects, isNotEmpty);
  });
}
