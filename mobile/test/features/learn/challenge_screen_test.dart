import 'dart:async';

import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_app/app/router.dart';
import 'package:quiz_app/features/learn/data/fake_learn_repository.dart';
import 'package:quiz_app/features/practice/challenge_clock.dart';
import 'package:quiz_app/features/practice/data/practice_models.dart';
import 'package:quiz_app/features/practice/practice_screen.dart';
import 'package:quiz_app/features/practice/start_practice.dart';

import '../../support/fakes.dart';

Finder _option(String text) => find.byWidgetPredicate((w) => w is AnswerOption && w.text == text);

AnswerOptionState _state(WidgetTester tester, String text) =>
    tester.widget<AnswerOption>(_option(text)).state;

Finder _iconButton(String label) =>
    find.byWidgetPredicate((w) => w is AppIconButton && w.semanticLabel == label);

/// A segment of the [n]th segmented control on screen.
Finder _segment(int n, String label) => find.descendant(
  of: find.byWidgetPredicate((w) => w is AppSegmentedControl<int>).at(n),
  matching: find.text(label),
);

Finder _semantics(String label) =>
    find.byWidgetPredicate((w) => w is Semantics && w.properties.label == label);

String _timer(WidgetTester tester) =>
    formatCountdown(tester.widget<ChallengeTimerChip>(find.byType(ChallengeTimerChip)).left!);

PracticeOption _correct(PracticeQuestion q) => q.options.firstWhere((o) => o.id == q.answer);

PracticeOption _wrong(PracticeQuestion q) => q.options.firstWhere((o) => o.id != q.answer);

const _kinematicsChallenge = SessionSettings(
  mode: PracticeMode.challenge,
  subject: 'physics',
  chapters: ['kinematics'],
  timeLimitS: 300,
  marking: Marking.neet,
);

void main() {
  late DateTime now;
  late FakeLearnRepository learn;

  setUp(() {
    now = DateTime.utc(2026, 9, 28, 10);
    learn = FakeLearnRepository.seeded(now: () => now);
  });

  Future<ProviderContainer> pump(WidgetTester tester, {String location = Routes.learn}) async {
    usePhoneViewport(tester, height: 1600);
    return pumpApp(
      tester,
      prefs: await testPrefs(),
      learn: learn,
      location: location,
      overrides: [practiceNowProvider.overrideWithValue(() => now)],
    );
  }

  /// Starts [settings] the way the set-up screen does and opens it.
  Future<PracticeSession> startChallenge(
    WidgetTester tester, [
    SessionSettings settings = _kinematicsChallenge,
  ]) async {
    final container = await pump(tester);
    final session = await container
        .read(practiceStarterProvider)
        .start(settings, idempotencyKey: 'k');
    await tester.runAsync(() async {});
    unawaited(container.read(routerProvider).push(Routes.practiceSession(session.sessionId)));
    await tester.pumpAndSettle();
    return session;
  }

  group('set-up', () {
    testWidgets('opens from Learn with 20 questions, 10 minutes and +4/−1 on', (tester) async {
      await pump(tester);
      await tester.tap(find.text('Self Challenge'));
      await tester.pumpAndSettle();

      expect(find.text('Start · 20 questions in 10 min'), findsOneWidget);
      final marking = tester.widget<ToggleRow>(find.widgetWithText(ToggleRow, '+4 / −1 marking'));
      expect(marking.value, isTrue);
      final unseen = tester.widget<ToggleRow>(find.widgetWithText(ToggleRow, 'Unseen only'));
      expect(unseen.value, isFalse);

      await tester.tap(find.text('Start · 20 questions in 10 min'));
      await tester.pumpAndSettle();

      expect(
        learn.createCalls.single.$1,
        const SessionSettings(
          mode: PracticeMode.challenge,
          subject: 'physics',
          count: 20,
          timeLimitS: 600,
          marking: Marking.neet,
        ),
      );
      expect(find.byType(ChallengeTimerChip), findsOneWidget);
    });

    testWidgets('every choice goes into the session', (tester) async {
      await pump(tester, location: Routes.selfChallenge(subject: 'physics'));

      for (final choice in [
        find.text('Laws of Motion'),
        find.text('Motion in a Straight Line'),
        _segment(0, '50'),
        _segment(1, '30'),
        find.widgetWithText(AppChip, 'Easy'),
        find.text('+4 / −1 marking'),
        find.text('Unseen only'),
      ]) {
        await tester.ensureVisible(choice);
        await tester.tap(choice);
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('Start · 50 questions in 30 min'));
      await tester.pumpAndSettle();

      expect(
        learn.createCalls.single.$1,
        const SessionSettings(
          mode: PracticeMode.challenge,
          subject: 'physics',
          chapters: ['kinematics', 'laws-of-motion'],
          count: 50,
          difficulty: Difficulty.easy,
          timeLimitS: 1800,
          unseenOnly: true,
        ),
        reason: 'chapters in catalog order; marking off',
      );
    });

    testWidgets('switching subject clears the chapters', (tester) async {
      await pump(tester, location: Routes.selfChallenge(subject: 'physics'));
      await tester.tap(find.text('Laws of Motion'));
      await tester.tap(find.widgetWithText(AppChip, 'Biology'));
      await tester.pumpAndSettle();
      expect(find.text('Cell: The Unit of Life'), findsOneWidget);
      expect(find.text('Laws of Motion'), findsNothing);

      await tester.tap(find.textContaining('Start ·'));
      await tester.pumpAndSettle();
      expect(learn.createCalls.single.$1.subject, 'biology');
      expect(learn.createCalls.single.$1.chapters, isEmpty);
    });

    testWidgets('nothing matching is explained in place; a retry keeps its key', (tester) async {
      await pump(tester, location: Routes.selfChallenge(subject: 'biology'));
      await tester.tap(find.widgetWithText(AppChip, 'Hard'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Start ·'));
      await tester.pumpAndSettle();

      expect(find.text('No questions match these settings yet.'), findsOneWidget);
      await tester.tap(find.textContaining('Start ·'));
      await tester.pumpAndSettle();
      expect(learn.createCalls[0].$2, learn.createCalls[1].$2);

      await tester.tap(find.widgetWithText(AppChip, 'Mixed'));
      await tester.pumpAndSettle();
      expect(find.text('No questions match these settings yet.'), findsNothing);
      await tester.tap(find.textContaining('Start ·'));
      await tester.pumpAndSettle();
      expect(learn.createCalls[2].$2, isNot(learn.createCalls[1].$2));
    });
  });

  group('the timed test', () {
    testWidgets('counts down from the server deadline, even while away', (tester) async {
      await startChallenge(tester);
      expect(_timer(tester), '5:00');
      expect(find.text('Physics · Self Challenge'), findsOneWidget);

      now = now.add(const Duration(seconds: 30));
      await tester.pump(const Duration(seconds: 1));
      expect(_timer(tester), '4:30');

      // Time in the background counts.
      tester.binding
        ..handleAppLifecycleStateChanged(AppLifecycleState.inactive)
        ..handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      now = now.add(const Duration(minutes: 3, seconds: 55));
      tester.binding
        ..handleAppLifecycleStateChanged(AppLifecycleState.inactive)
        ..handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(_timer(tester), '0:35');
      final chip = tester.widget<InfoChip>(
        find.descendant(of: find.byType(ChallengeTimerChip), matching: find.byType(InfoChip)),
      );
      final colors = tester.element(find.byType(ChallengeTimerChip)).colors;
      expect(chip.background, colors.warningContainer, reason: 'the last minute');
    });

    testWidgets('answers stay hidden until the end; picks can change', (tester) async {
      final session = await startChallenge(tester);
      final q1 = session.questions.first;

      await tester.tap(_option(_wrong(q1).text));
      await tester.pumpAndSettle();
      expect(_state(tester, _wrong(q1).text), AnswerOptionState.selected);
      expect(_state(tester, _correct(q1).text), AnswerOptionState.idle);
      expect(find.text('Correct'), findsNothing);
      expect(find.textContaining('Not quite'), findsNothing);
      expect(learn.uploadCalls, isEmpty, reason: 'nothing is final until Next');

      await tester.tap(_option(_correct(q1).text));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();

      final upload = learn.uploadedAnswers.single;
      expect(upload.selectedOption, q1.answer);
      expect(upload.answerChanges, 1);
      expect(find.text('QUESTION 2 / 4'), findsOneWidget);
    });

    testWidgets('the result has the +4/−1 score, accuracy, time per question and a review', (
      tester,
    ) async {
      final session = await startChallenge(tester);
      final [q1, q2, q3, q4] = session.questions;

      await tester.tap(_option(_correct(q1).text));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
      await tester.tap(_option(_correct(q2).text));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
      await tester.tap(_option(_wrong(q3).text));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Skip'));
      await tester.pumpAndSettle();

      expect(find.text('Challenge complete'), findsOneWidget);
      expect(find.text('SCORE'), findsOneWidget);
      expect(find.text(' / 16'), findsOneWidget);
      expect(_semantics('Score 7 out of 16'), findsOneWidget);
      expect(find.text('67%'), findsOneWidget, reason: '2 of 3 answered right');
      expect(find.text('Per question'), findsOneWidget);
      expect(find.textContaining('2 right · 1 wrong · 1 skipped'), findsOneWidget);
      expect(learn.finishCalls, [session.sessionId]);

      await tester.tap(find.text('Review answers'));
      await tester.pumpAndSettle();
      expect(find.text('QUESTION 1 / 4'), findsOneWidget);
      expect(find.text('Correct'), findsNWidgets(2));
      await tester.scrollUntilVisible(find.text('Skipped'), 300);
      expect(find.text('Wrong'), findsOneWidget);
      expect(find.text('Skipped'), findsOneWidget);
      expect(q4.explanation, isNotEmpty);

      await tester.tap(_iconButton('Back'));
      await tester.pumpAndSettle();
      expect(find.text('Challenge complete'), findsOneWidget);
    });

    testWidgets('when time runs out it ends where it is; a pick in hand still counts', (
      tester,
    ) async {
      final session = await startChallenge(tester);
      final [q1, q2, ..._] = session.questions;
      await tester.tap(_option(_correct(q1).text));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
      await tester.tap(_option(_correct(q2).text));
      await tester.pumpAndSettle();

      now = now.add(const Duration(minutes: 5));
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();

      expect(find.text('Time\'s up'), findsOneWidget);
      expect(learn.uploadedAnswers.map((a) => a.position), [1, 2]);
      expect(find.textContaining('2 right · 0 wrong · 2 not answered'), findsOneWidget);
      expect(_semantics('Score 8 out of 16'), findsOneWidget);
    });

    testWidgets('Submit now ends it early from the leave sheet', (tester) async {
      final session = await startChallenge(tester);
      await tester.tap(_option(_correct(session.questions.first).text));
      await tester.pumpAndSettle();

      await tester.tap(_iconButton('Leave practice'));
      await tester.pumpAndSettle();
      expect(find.text('The timer keeps running. Your answers so far are saved.'), findsOneWidget);
      await tester.tap(find.text('Submit now'));
      await tester.pumpAndSettle();

      expect(find.text('Time\'s up'), findsOneWidget);
      expect(learn.uploadedAnswers.single.selectedOption, session.questions.first.answer);
    });

    testWidgets('reopening after the deadline ends it at once', (tester) async {
      final container = await pump(tester);
      final session = await container
          .read(practiceStarterProvider)
          .start(_kinematicsChallenge, idempotencyKey: 'k');
      now = now.add(const Duration(minutes: 20));

      unawaited(container.read(routerProvider).push(Routes.practiceSession(session.sessionId)));
      await tester.pumpAndSettle();

      expect(find.text('Time\'s up'), findsOneWidget);
      expect(learn.finishCalls, [session.sessionId]);
      expect(learn.uploadCalls, isEmpty);
    });

    testWidgets('a question can be reported mid-test', (tester) async {
      final session = await startChallenge(tester);
      await tester.tap(_iconButton('Report question'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Unclear'));
      await tester.pump();
      await tester.tap(find.widgetWithText(AppButton, 'Send report'));
      await tester.pumpAndSettle();

      expect(learn.reportCalls.single.$1, session.questions.first.ref);
      expect(find.text('QUESTION 1 / 4'), findsOneWidget);
    });
  });
}
