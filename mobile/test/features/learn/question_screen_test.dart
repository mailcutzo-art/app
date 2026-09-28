import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_app/app/router.dart';
import 'package:quiz_app/core/network/app_failure.dart';
import 'package:quiz_app/features/learn/data/fake_learn_repository.dart';
import 'package:quiz_app/features/learn/data/question_models.dart';

import '../../support/fakes.dart';

Finder _option(String text) => find.byWidgetPredicate((w) => w is AnswerOption && w.text == text);

AnswerOptionState _state(WidgetTester tester, String text) =>
    tester.widget<AnswerOption>(_option(text)).state;

Finder _iconButton(String label) =>
    find.byWidgetPredicate((w) => w is AppIconButton && w.semanticLabel == label);

Finder _button(String label) => find.widgetWithText(AppButton, label);

void main() {
  late FakeLearnRepository learn;

  setUp(() => learn = FakeLearnRepository.seeded());

  Future<void> open(WidgetTester tester, String ref) async {
    usePhoneViewport(tester, height: 1200);
    await pumpApp(tester, prefs: await testPrefs(), learn: learn, location: Routes.question(ref));
  }

  testWidgets('loads, then shows the stem and options in authored order', (tester) async {
    learn.latency = const Duration(milliseconds: 200);
    usePhoneViewport(tester, height: 1200);
    await pumpApp(
      tester,
      prefs: await testPrefs(),
      learn: learn,
      location: Routes.question('phy-kin-005'),
      settle: false,
    );
    expect(find.byType(Shimmer), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();
    expect(find.textContaining('A car starts from rest', findRichText: true), findsOneWidget);
    expect(find.text('EQUATIONS OF MOTION'), findsOneWidget);
    expect(find.text('EASY'), findsOneWidget);
    expect(tester.widgetList<AnswerOption>(find.byType(AnswerOption)).map((o) => o.text), [
      '10 m',
      '25 m',
      '50 m',
      '100 m',
    ]);
    expect(_state(tester, '25 m'), AnswerOptionState.idle, reason: 'no answer before trying');
  });

  testWidgets('trying a wrong option reveals the answer and the explanation', (tester) async {
    await open(tester, 'phy-kin-005');

    await tester.tap(_option('50 m'));
    await tester.pumpAndSettle();

    expect(_state(tester, '50 m'), AnswerOptionState.wrong);
    expect(_state(tester, '25 m'), AnswerOptionState.correct);
    expect(_state(tester, '10 m'), AnswerOptionState.dimmed);
    expect(find.text('Not quite · the answer is B'), findsOneWidget);
    expect(find.byType(ExplanationCard), findsOneWidget);

    await tester.tap(_button('Try again'));
    await tester.pumpAndSettle();
    expect(_state(tester, '50 m'), AnswerOptionState.idle);
    expect(find.byType(ExplanationCard), findsNothing);
  });

  testWidgets('Show answer reveals without trying', (tester) async {
    await open(tester, 'phy-kin-005');
    await tester.tap(_button('Show answer'));
    await tester.pumpAndSettle();
    expect(find.text('The answer is B'), findsOneWidget);
    expect(_state(tester, '25 m'), AnswerOptionState.correct);
    expect(find.byType(ExplanationCard), findsOneWidget);
  });

  testWidgets('the bookmark flips at once and is put back if saving fails', (tester) async {
    await open(tester, 'phy-kin-005');

    await tester.tap(_iconButton('Bookmark question'));
    await tester.pumpAndSettle();
    expect(learn.bookmarks, {'phy-kin-005'});
    expect(_iconButton('Remove bookmark'), findsOneWidget);

    learn.failures[FakeLearnOp.bookmark] = const NetworkFailure();
    await tester.tap(_iconButton('Remove bookmark'));
    await tester.pumpAndSettle();
    expect(_iconButton('Remove bookmark'), findsOneWidget, reason: 'put back');
    expect(find.text('You\'re offline, so the bookmark wasn\'t saved.'), findsOneWidget);
    expect(learn.bookmarks, {'phy-kin-005'});
  });

  testWidgets('a retired question says so', (tester) async {
    await open(tester, 'gone');
    expect(find.text('This question isn\'t available'), findsOneWidget);
  });

  testWidgets('other errors offer a retry', (tester) async {
    learn.failures[FakeLearnOp.question] = const ServerFailure();
    await open(tester, 'bio-cell-001');
    expect(find.text('Couldn\'t load this question'), findsOneWidget);

    learn.failures.clear();
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(find.textContaining('powerhouse', findRichText: true), findsOneWidget);
  });

  group('reporting', () {
    testWidgets('needs a reason, sends it with the note, and thanks', (tester) async {
      await open(tester, 'phy-kin-005');

      await tester.tap(_button('Report question'));
      await tester.pumpAndSettle();
      expect(find.text('What looks wrong? Our team checks every report.'), findsOneWidget);
      expect(tester.widget<AppButton>(_button('Send report')).onPressed, isNull);

      await tester.tap(find.text('Typo'));
      await tester.enterText(find.byType(TextField), '  m/s should be m s^-1 ');
      await tester.pump();
      await tester.tap(_button('Send report'));
      await tester.pumpAndSettle();

      expect(learn.reportCalls.single.$1, 'phy-kin-005');
      expect(learn.reportCalls.single.$2, ReportReason.typo);
      expect(learn.reportCalls.single.$3, contains('m/s should be'));
      expect(find.text('Report question'), findsOneWidget, reason: 'the sheet closed');
      expect(find.text('Thanks! We\'ll check this question.'), findsOneWidget);
    });

    testWidgets('the daily limit is explained in the sheet', (tester) async {
      learn.failures[FakeLearnOp.report] = const RateLimitedFailure();
      await open(tester, 'phy-kin-005');

      await tester.tap(_button('Report question'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Wrong answer'));
      await tester.pump();
      await tester.tap(_button('Send report'));
      await tester.pumpAndSettle();

      expect(find.textContaining('most reports allowed today'), findsOneWidget);
      expect(find.text('Send report'), findsOneWidget, reason: 'still open');
    });
  });
}
