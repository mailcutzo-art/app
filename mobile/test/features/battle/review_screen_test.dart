import 'package:design_system/design_system.dart' hide Presence;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_app/app/router.dart';
import 'package:quiz_app/core/network/app_failure.dart';
import 'package:quiz_app/features/battle/data/match_models.dart';
import 'package:quiz_app/features/battle/match/review_screen.dart';
import 'package:quiz_app/features/learn/data/fake_learn_repository.dart';
import 'package:realtime_client/realtime_client.dart' hide AnswerOption;

import '../../support/battle.dart';
import '../../support/fakes.dart';
import '../../support/match_frames.dart';
import '../../support/rt_server.dart';

ReviewQuestion _question(
  int q, {
  String? myPick,
  String? theirPick,
  bool bookmarked = false,
  String explanation = '',
}) {
  String option(int i) => 'q$q-o$i';
  final correct = option(0);
  return ReviewQuestion(
    q: q,
    ref: 'phy-kin-00$q',
    stem: 'Question $q: how far does a car go?',
    options: [
      for (var i = 0; i < 4; i++) ReviewOption(id: option(i), text: 'Answer ${'ABCD'[i]} of $q'),
    ],
    correct: correct,
    explanation: explanation,
    chapter: 'Kinematics',
    topic: q == 1 ? 'Relative velocity' : null,
    players: {
      'u1': PlayerReveal(
        opt: myPick,
        correct: myPick == correct,
        pts: myPick == correct ? 139 : 0,
        timeMs: myPick == null ? null : 4000,
      ),
      'riya': PlayerReveal(
        opt: theirPick,
        correct: theirPick == correct,
        pts: theirPick == correct ? 132 : 0,
        timeMs: theirPick == null ? null : 5200,
      ),
    },
    bookmarked: bookmarked,
  );
}

final _review = MatchReview(
  questions: [
    _question(1, myPick: 'q1-o0', theirPick: 'q1-o2', explanation: 'Use v = u + at.'),
    _question(2, theirPick: 'q2-o0', bookmarked: true),
  ],
);

/// A finished game with Riya, and its review opened from the result.
Future<ProviderContainer> _openReview(
  WidgetTester tester, {
  required FakeMatchRepository matches,
  FakeLearnRepository? learn,
}) async {
  final match = MatchFrames();
  final server = TestRealtimeServer();
  final container = await pumpApp(
    tester,
    prefs: await testPrefs(),
    realtime: server,
    matches: matches,
    learn: learn,
    location: Routes.battleSearch,
    settle: false,
  );
  await advance(tester, const Duration(milliseconds: 500));
  server
    ..push(match.found())
    ..push(match.snapshot(phase: 'ready_wait', endsAt: serverNow() + 10000))
    ..push(match.end(result: 'win', myTotals: (139, 1)))
    ..push(match.settled());
  await advance(tester, const Duration(milliseconds: 500));
  await tester.tap(find.text('Review answers'));
  await advance(tester, const Duration(milliseconds: 500));
  expect(location(container), Routes.battleReview('m1'));
  return container;
}

AnswerOption _option(WidgetTester tester, String text) =>
    tester.widget<AnswerOption>(find.byWidgetPredicate((w) => w is AnswerOption && w.text == text));

Finder _bookmark(String label) =>
    find.byWidgetPredicate((w) => w is AppIconButton && w.semanticLabel == label);

void main() {
  testWidgets('every question: both picks, times, the right answer and the explanation', (
    tester,
  ) async {
    usePhoneViewport(tester, height: 2400);
    reduceMotion(tester);
    final matches = FakeMatchRepository()..reviews['m1'] = _review;
    await _openReview(tester, matches: matches);

    expect(find.text('Review answers'), findsOneWidget);
    expect(find.text('QUESTION 1 / 2'), findsOneWidget);
    expect(find.text('RELATIVE VELOCITY'), findsOneWidget, reason: 'the topic, when there is one');
    expect(find.text('KINEMATICS'), findsOneWidget);
    expect(find.text('Question 1: how far does a car go?'), findsOneWidget);
    expect(_option(tester, 'Answer A of 1').state, AnswerOptionState.correct);
    expect(_option(tester, 'Answer C of 1').state, AnswerOptionState.dimmed);
    expect(_option(tester, 'Answer C of 1').opponent, isNotNull, reason: 'Riya\'s pick');
    expect(find.text('You · 4.0 s · +139'), findsOneWidget);
    expect(find.text('Riya · 5.2 s · wrong'), findsOneWidget);
    expect(find.text('Use v = u + at.'), findsOneWidget);

    expect(find.text('You · no answer'), findsOneWidget);
    expect(find.text('Riya · 5.2 s · +132'), findsOneWidget);
    expect(_bookmark('Remove bookmark'), findsOneWidget, reason: 'question 2 is bookmarked');
  });

  testWidgets('a wrong pick is marked wrong', (tester) async {
    usePhoneViewport(tester, height: 2400);
    reduceMotion(tester);
    final matches = FakeMatchRepository()
      ..reviews['m1'] = MatchReview(questions: [_question(1, myPick: 'q1-o3')]);
    await _openReview(tester, matches: matches);
    expect(_option(tester, 'Answer D of 1').state, AnswerOptionState.wrong);
    expect(_option(tester, 'Answer A of 1').state, AnswerOptionState.correct);
    expect(find.text('You · 4.0 s · wrong'), findsOneWidget);
  });

  testWidgets('bookmarks save, and can be undone', (tester) async {
    usePhoneViewport(tester, height: 2400);
    reduceMotion(tester);
    final learn = FakeLearnRepository.seeded();
    final matches = FakeMatchRepository()..reviews['m1'] = _review;
    await _openReview(tester, matches: matches, learn: learn);

    await tester.tap(_bookmark('Bookmark question'));
    await advance(tester, const Duration(milliseconds: 300));
    expect(learn.bookmarkCalls, [('phy-kin-001', true)]);
    expect(_bookmark('Bookmark question'), findsNothing);
    expect(_bookmark('Remove bookmark'), findsNWidgets(2));

    await tester.tap(_bookmark('Remove bookmark').first);
    await advance(tester, const Duration(milliseconds: 300));
    expect(learn.bookmarkCalls.last, ('phy-kin-001', false));
    expect(learn.bookmarks, isNot(contains('phy-kin-001')));
  });

  testWidgets('a bookmark that couldn\'t be saved goes back, with a note', (tester) async {
    usePhoneViewport(tester, height: 2400);
    reduceMotion(tester);
    final learn = FakeLearnRepository.seeded()
      ..failures[FakeLearnOp.bookmark] = const NetworkFailure();
    final matches = FakeMatchRepository()..reviews['m1'] = _review;
    await _openReview(tester, matches: matches, learn: learn);

    await tester.tap(_bookmark('Bookmark question'));
    await advance(tester, const Duration(milliseconds: 300));
    expect(find.text('You\'re offline, so the bookmark wasn\'t saved.'), findsOneWidget);
    expect(_bookmark('Bookmark question'), findsOneWidget);
  });

  testWidgets('a review that didn\'t load offers Try again', (tester) async {
    usePhoneViewport(tester, height: 2400);
    reduceMotion(tester);
    final matches = FakeMatchRepository();
    await _openReview(tester, matches: matches);
    // The finished game itself read fine; only the review fails.
    matches.failure = const NetworkFailure();
    await tester.tap(find.text('Try again'));
    await advance(tester, const Duration(milliseconds: 300));
    expect(find.text('Couldn\'t load the review'), findsOneWidget);

    matches
      ..failure = null
      ..reviews['m1'] = _review;
    await tester.tap(find.text('Try again'));
    await advance(tester, const Duration(milliseconds: 300));
    expect(find.text('Question 1: how far does a car go?'), findsOneWidget);
  });

  testWidgets('a game that ended before any question has nothing to review', (tester) async {
    usePhoneViewport(tester, height: 2400);
    reduceMotion(tester);
    final matches = FakeMatchRepository()..reviews['m1'] = const MatchReview(questions: []);
    await _openReview(tester, matches: matches);
    expect(find.text('Nothing to review'), findsOneWidget);
  });

  testWidgets('back returns to the result', (tester) async {
    usePhoneViewport(tester, height: 2400);
    reduceMotion(tester);
    final matches = FakeMatchRepository()..reviews['m1'] = _review;
    final container = await _openReview(tester, matches: matches);
    await tester.tap(
      find.byWidgetPredicate((w) => w is AppIconButton && w.semanticLabel == 'Back'),
    );
    await advance(tester, const Duration(milliseconds: 500));
    expect(location(container), Routes.battleMatch('m1'));
    expect(find.text('Victory!'), findsOneWidget);
  });

  test('seconds', () {
    expect(seconds(6200), '6.2 s');
    expect(seconds(480), '0.5 s');
  });
}
