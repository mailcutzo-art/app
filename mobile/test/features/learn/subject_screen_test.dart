import 'package:design_system/design_system.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_app/app/router.dart';
import 'package:quiz_app/core/network/app_failure.dart';
import 'package:quiz_app/features/learn/data/fake_learn_repository.dart';
import 'package:quiz_app/features/learn/data/learn_models.dart';
import 'package:quiz_app/features/practice/data/practice_models.dart';

import '../../support/fakes.dart';

const _progress = Progress(
  subjects: [
    SubjectProgress(
      slug: 'physics',
      answered: 18,
      correct: 12,
      chapters: [
        ChapterProgress(
          slug: 'kinematics',
          answered: 12,
          correct: 11,
          seen: 4,
          label: ChapterLabel.strong,
        ),
        ChapterProgress(
          slug: 'laws-of-motion',
          answered: 6,
          correct: 1,
          seen: 2,
          label: ChapterLabel.needsWork,
        ),
      ],
    ),
  ],
  reviewsDue: 0,
);

void main() {
  late FakeLearnRepository learn;

  setUp(() => learn = FakeLearnRepository.seeded());

  testWidgets('chapters show counts, how many were seen, and a Strong / Needs work word', (
    tester,
  ) async {
    usePhoneViewport(tester);
    learn.progressOverride = _progress;
    await pumpApp(
      tester,
      prefs: await testPrefs(),
      learn: learn,
      location: Routes.subject('physics'),
    );

    expect(find.text('Physics'), findsOneWidget);
    expect(find.text('2 chapters · 6 questions'), findsOneWidget);
    expect(find.text('Motion in a Straight Line'), findsOneWidget);
    expect(find.text('4 questions · 4 seen'), findsOneWidget);
    expect(find.text('2 questions · 2 seen'), findsOneWidget);

    final strong = tester.widget<InfoChip>(find.widgetWithText(InfoChip, 'Strong'));
    expect(strong.background, AppColors.light.successContainer);
    final needsWork = tester.widget<InfoChip>(find.widgetWithText(InfoChip, 'Needs work'));
    expect(needsWork.background, AppColors.light.warningContainer);

    expect(find.byType(FloatingNavBar), findsOneWidget, reason: 'pushed inside the Learn tab');
  });

  testWidgets('no label without enough answers; untouched chapters say so', (tester) async {
    usePhoneViewport(tester);
    await pumpApp(
      tester,
      prefs: await testPrefs(),
      learn: learn,
      location: Routes.subject('physics'),
    );

    expect(find.text('4 questions · Not started'), findsOneWidget);
    expect(find.byType(InfoChip), findsNothing);
  });

  testWidgets('a progress failure still lists the chapters, without labels', (tester) async {
    usePhoneViewport(tester);
    learn.failures[FakeLearnOp.progress] = const NetworkFailure();
    await pumpApp(
      tester,
      prefs: await testPrefs(),
      learn: learn,
      location: Routes.subject('physics'),
    );

    expect(find.text('Couldn\'t load your progress'), findsOneWidget);
    expect(find.text('4 questions'), findsOneWidget);
    expect(find.text('Laws of Motion'), findsOneWidget);
  });

  testWidgets('the chapter sheet starts a session with the chosen settings', (tester) async {
    usePhoneViewport(tester, height: 1100);
    await pumpApp(
      tester,
      prefs: await testPrefs(),
      learn: learn,
      location: Routes.subject('physics'),
    );

    await tester.tap(find.text('Motion in a Straight Line'));
    await tester.pumpAndSettle();
    expect(find.text('Whole chapter'), findsOneWidget);
    expect(find.text('Speed and velocity'), findsOneWidget);

    await tester.tap(find.text('Equations of motion'));
    await tester.tap(find.text('20'));
    await tester.tap(find.text('Medium'));
    await tester.tap(find.text('Timed'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start practice'));
    await tester.pumpAndSettle();

    final (settings, key) = learn.createCalls.single;
    expect(
      settings,
      const SessionSettings(
        mode: PracticeMode.topic,
        subject: 'physics',
        topic: 'equations-of-motion',
        count: 20,
        difficulty: Difficulty.medium,
        timed: true,
        perQuestionS: 30,
      ),
    );
    expect(key, matches(RegExp(r'^[0-9a-f]{32}$')));

    // The practice screen is full screen, above the tabs.
    expect(find.text('QUESTION 1 / 1'), findsOneWidget);
    expect(find.byType(CountdownRing), findsOneWidget);
    expect(find.byType(FloatingNavBar), findsNothing);
  });

  testWidgets('no matching questions is explained in the sheet; new settings get a new key', (
    tester,
  ) async {
    usePhoneViewport(tester, height: 1100);
    await pumpApp(
      tester,
      prefs: await testPrefs(),
      learn: learn,
      location: Routes.subject('physics'),
    );
    await tester.tap(find.text('Motion in a Straight Line'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Hard'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start practice'));
    await tester.pumpAndSettle();

    expect(find.text('No questions match these settings yet.'), findsOneWidget);
    expect(find.text('Start practice'), findsOneWidget, reason: 'the sheet stays open');

    await tester.tap(find.text('Start practice'));
    await tester.pumpAndSettle();
    expect(learn.createCalls[1].$2, learn.createCalls[0].$2, reason: 'a retry reuses the key');

    await tester.tap(find.text('Mixed'));
    await tester.pumpAndSettle();
    expect(find.text('No questions match these settings yet.'), findsNothing);
    await tester.tap(find.text('Start practice'));
    await tester.pumpAndSettle();

    expect(learn.createCalls, hasLength(3));
    expect(learn.createCalls.last.$2, isNot(learn.createCalls.first.$2));
    expect(learn.createCalls.last.$1.mode, PracticeMode.chapter);
    expect(learn.createCalls.last.$1.chapters, ['kinematics']);
    expect(find.text('QUESTION 1 / 4'), findsOneWidget);
  });
}
