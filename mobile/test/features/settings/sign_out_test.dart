import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_app/app/router.dart';
import 'package:quiz_app/core/network/app_failure.dart';
import 'package:quiz_app/features/learn/data/fake_learn_repository.dart';
import 'package:quiz_app/features/practice/data/practice_models.dart';

import '../../support/fakes.dart';

void main() {
  late FakeLearnRepository learn;
  late PracticeSession session;

  setUp(() async {
    learn = FakeLearnRepository.seeded();
    session = await learn.createSession(
      const SessionSettings(
        mode: PracticeMode.chapter,
        subject: 'physics',
        chapters: ['kinematics'],
      ),
      idempotencyKey: 'k',
    );
  });

  /// Two answers of the signed-in user still waiting on the phone.
  Map<String, Object> queued() => {
    'practice.queue.u1.${session.sessionId}': jsonEncode([
      for (final q in session.questions.take(2))
        AnswerUpload.create(
          ref: q.ref,
          position: q.position,
          selectedOption: q.answer,
          timeMs: 1000,
        ).toJson(),
    ]),
  };

  testWidgets('signing out first tries to send answers; unsent ones are counted', (tester) async {
    usePhoneViewport(tester);
    learn.failures[FakeLearnOp.uploadAnswers] = const NetworkFailure();
    await pumpApp(
      tester,
      prefs: await testPrefs(queued()),
      learn: learn,
      location: Routes.settings,
    );

    await tester.scrollUntilVisible(find.text('Sign out'), 300);
    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();

    expect(find.text('2 answers aren\'t saved yet. Sign out anyway?'), findsOneWidget);
    expect(find.text('Sign out anyway'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Sign out anyway'), findsNothing);
  });

  testWidgets('when the answers go through, the usual confirmation shows', (tester) async {
    usePhoneViewport(tester);
    await pumpApp(
      tester,
      prefs: await testPrefs(queued()),
      learn: learn,
      location: Routes.settings,
    );

    await tester.scrollUntilVisible(find.text('Sign out'), 300);
    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();

    expect(learn.uploadedAnswers, hasLength(2));
    expect(
      find.text('You can sign back in with the same Google account any time.'),
      findsOneWidget,
    );
  });
}
