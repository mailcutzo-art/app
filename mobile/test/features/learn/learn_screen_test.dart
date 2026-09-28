import 'package:design_system/design_system.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_app/app/router.dart';
import 'package:quiz_app/core/auth/session.dart';
import 'package:quiz_app/core/auth/user.dart';
import 'package:quiz_app/core/network/app_failure.dart';
import 'package:quiz_app/features/learn/data/fake_learn_repository.dart';
import 'package:quiz_app/features/learn/data/learn_models.dart';
import 'package:quiz_app/features/learn/learn_providers.dart';
import 'package:quiz_app/features/practice/data/practice_models.dart';

import '../../support/fakes.dart';

const _progress = Progress(
  subjects: [
    SubjectProgress(
      slug: 'physics',
      answered: 23,
      correct: 15,
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
  reviewsDue: 3,
  continuePractice: ContinuePractice(
    sessionId: 's-1',
    title: 'Physics · Motion in a Straight Line',
    answered: 12,
    count: 20,
  ),
  tip: Tip(
    key: 'weak_topic:physics:friction',
    message: 'Focus on Friction. You got 1 of 6 right.',
    action: TipAction.practice,
    params: {'subject': 'physics', 'topic': 'friction', 'count': '10'},
  ),
);

void main() {
  late FakeLearnRepository learn;

  setUp(() {
    learn = FakeLearnRepository.seeded()..progressOverride = _progress;
  });

  testWidgets('shows skeletons while loading, then subjects, continue and the tip', (tester) async {
    usePhoneViewport(tester);
    learn.latency = const Duration(milliseconds: 300);
    await pumpApp(
      tester,
      prefs: await testPrefs(),
      learn: learn,
      location: Routes.learn,
      settle: false,
    );

    expect(find.text('Learn'), findsWidgets);
    expect(find.byType(Shimmer), findsNWidgets(2), reason: 'progress card and subject grid');
    expect(find.text('Physics'), findsNothing);

    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();

    expect(find.byType(Shimmer), findsNothing);
    expect(find.text('Physics'), findsOneWidget);
    expect(find.text('2 chapters · 6 questions'), findsOneWidget);
    expect(find.text('Biology'), findsOneWidget);
    expect(find.text('Physics · Motion in a Straight Line'), findsOneWidget);
    expect(find.text('12/20'), findsOneWidget);
    expect(find.text('Resume'), findsOneWidget);
    expect(find.textContaining('Focus on Friction', findRichText: true), findsOneWidget);
    expect(find.text('Practise 10'), findsOneWidget);
    expect(find.text('3 due'), findsOneWidget);
    expect(find.text('SOON'), findsNothing, reason: 'every practice tool works');
    expect(find.text('Self Challenge'), findsOneWidget);
    expect(find.text('Fun & Learn'), findsOneWidget);
  });

  testWidgets('a progress error keeps the subjects on screen and retries on its own card', (
    tester,
  ) async {
    usePhoneViewport(tester);
    learn.failures[FakeLearnOp.progress] = const NetworkFailure();
    await pumpApp(tester, prefs: await testPrefs(), learn: learn, location: Routes.learn);

    expect(find.text('Couldn\'t load your progress'), findsOneWidget);
    expect(find.text('Physics'), findsOneWidget, reason: 'the catalog loads on its own');
    expect(find.text('Resume'), findsNothing);
    expect(
      find.text('Questions you missed'),
      findsOneWidget,
      reason: 'no due count without progress',
    );

    learn.failures.remove(FakeLearnOp.progress);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(find.text('Couldn\'t load your progress'), findsNothing);
    expect(find.text('Resume'), findsOneWidget);
    expect(find.text('3 due'), findsOneWidget);
  });

  testWidgets('a catalog error is a compact card with retry; progress still shows', (tester) async {
    usePhoneViewport(tester);
    learn.failures[FakeLearnOp.catalog] = const ServerFailure();
    await pumpApp(tester, prefs: await testPrefs(), learn: learn, location: Routes.learn);

    expect(find.text('Couldn\'t load subjects'), findsOneWidget);
    expect(find.text('Resume'), findsOneWidget);

    learn.failures.remove(FakeLearnOp.catalog);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Physics'), findsOneWidget);
  });

  testWidgets('the exam switcher changes what is browsed, not the profile goal', (tester) async {
    usePhoneViewport(tester);
    final container = await pumpApp(
      tester,
      prefs: await testPrefs(),
      learn: learn,
      location: Routes.learn,
    );
    expect(container.read(learnGoalProvider), Goal.neet, reason: 'starts at the user\'s goal');
    expect(find.text('Biology'), findsOneWidget);

    await tester.tap(find.text('JEE'));
    await tester.pumpAndSettle();

    expect(find.text('Biology'), findsNothing);
    expect(find.text('Physics'), findsOneWidget);
    expect(container.read(learnGoalProvider), Goal.jee);
    expect(container.read(meProvider).goal, Goal.neet);
  });

  testWidgets('reviewing with nothing due explains why instead of opening an empty set', (
    tester,
  ) async {
    usePhoneViewport(tester);
    learn.progressOverride = null;
    await pumpApp(tester, prefs: await testPrefs(), learn: learn, location: Routes.learn);

    expect(find.text('Nothing due'), findsOneWidget);
    await tester.tap(find.text('Review'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Nothing to review yet'), findsOneWidget);
    expect(learn.createCalls.single.$1.mode.name, 'review');
  });

  testWidgets('the search pill and every tool open their screens', (tester) async {
    usePhoneViewport(tester, height: 1400);
    await pumpApp(tester, prefs: await testPrefs(), learn: learn, location: Routes.learn);

    Future<void> openAndBack(Finder entry, String title) async {
      await tester.tap(entry);
      await tester.pumpAndSettle();
      expect(find.text(title), findsOneWidget);
      await tester.tap(
        find.byWidgetPredicate((w) => w is AppIconButton && w.semanticLabel == 'Back'),
      );
      await tester.pumpAndSettle();
    }

    await openAndBack(find.bySemanticsLabel('Search questions'), 'Find any question');
    await openAndBack(find.text('Bookmarks'), 'No bookmarks yet');
    await openAndBack(find.text('Self Challenge'), 'Start · 20 questions in 10 min');
    await openAndBack(find.text('Fun & Learn'), 'Galileo and the falling balls');
    expect(learn.createCalls, isEmpty, reason: 'nothing starts without a choice');
  });

  testWidgets('the coach tip\'s button starts the practice it suggests', (tester) async {
    usePhoneViewport(tester);
    await pumpApp(tester, prefs: await testPrefs(), learn: learn, location: Routes.learn);

    await tester.tap(find.text('Practise 10'));
    await tester.pumpAndSettle();

    expect(
      learn.createCalls.single.$1,
      const SessionSettings(mode: PracticeMode.topic, subject: 'physics', topic: 'friction'),
    );
    expect(find.text('QUESTION 1 / 1'), findsOneWidget);
  });

  testWidgets('a battle tip opens the Battle tab', (tester) async {
    usePhoneViewport(tester);
    learn.progressOverride = const Progress(
      subjects: [],
      reviewsDue: 0,
      tip: Tip(
        key: 'strong_topic:physics:friction',
        message: 'You\'re strong in Friction. Test it in a rated battle.',
        action: TipAction.battle,
        params: {'subject': 'physics'},
      ),
    );
    await pumpApp(tester, prefs: await testPrefs(), learn: learn, location: Routes.learn);

    await tester.tap(find.widgetWithText(AppButton, 'Battle'));
    await tester.pumpAndSettle();
    expect(find.text('Pick a chapter, find an opponent, play live.'), findsOneWidget);
  });

  testWidgets('resuming a session that has ended explains it and goes back', (tester) async {
    usePhoneViewport(tester);
    await pumpApp(tester, prefs: await testPrefs(), learn: learn, location: Routes.learn);

    await tester.tap(find.text('Resume'));
    await tester.pumpAndSettle();
    expect(find.text('This practice has ended'), findsOneWidget);

    await tester.tap(find.text('Back to Learn'));
    await tester.pumpAndSettle();
    expect(find.text('Practice tools'), findsOneWidget);
  });
}
