import 'package:design_system/design_system.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_app/app/router.dart';
import 'package:quiz_app/core/network/app_failure.dart';
import 'package:quiz_app/features/learn/data/fake_learn_repository.dart';
import 'package:quiz_app/features/practice/data/practice_models.dart';

import '../../support/fakes.dart';

Finder _iconButton(String label) =>
    find.byWidgetPredicate((w) => w is AppIconButton && w.semanticLabel == label);

Finder _option(String text) => find.byWidgetPredicate((w) => w is AnswerOption && w.text == text);

void main() {
  late FakeLearnRepository learn;

  setUp(() => learn = FakeLearnRepository.seeded());

  Future<void> open(WidgetTester tester, {bool settle = true}) async {
    usePhoneViewport(tester, height: 1200);
    await pumpApp(tester, prefs: await testPrefs(), learn: learn, location: Routes.learn);
    await tester.tap(find.text('Fun & Learn'));
    if (settle) await tester.pumpAndSettle();
  }

  testWidgets('lists passages with their chapter, size and difficulty', (tester) async {
    learn.latency = const Duration(milliseconds: 200);
    await open(tester, settle: false);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(Shimmer), findsOneWidget, reason: 'rows skeleton');

    await tester.pumpAndSettle();
    expect(find.text('Galileo and the falling balls'), findsOneWidget);
    expect(find.text('Motion in a Straight Line · 3 questions · Easy'), findsOneWidget);
    expect(find.text('The cell\'s power stations'), findsOneWidget);
    expect(find.text('Done'), findsNothing);
  });

  testWidgets('a subject chip asks for that subject; none is explained', (tester) async {
    await open(tester);
    await tester.tap(find.widgetWithText(AppChip, 'Biology'));
    await tester.pumpAndSettle();
    expect(find.text('Galileo and the falling balls'), findsNothing);
    expect(find.text('The cell\'s power stations'), findsOneWidget);

    learn.failures[FakeLearnOp.passages] = const ServerFailure();
    await tester.tap(find.widgetWithText(AppChip, 'Physics'));
    await tester.pumpAndSettle();
    expect(find.text('Couldn\'t load passages'), findsOneWidget);

    learn.failures.clear();
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(find.text('Galileo and the falling balls'), findsOneWidget);
  });

  testWidgets('read the passage, answer with explanations, and it is done', (tester) async {
    await open(tester);

    await tester.tap(find.text('The cell\'s power stations'));
    await tester.pumpAndSettle();

    expect(learn.createCalls.single.$1.mode, PracticeMode.passage);
    expect(find.text('FUN & LEARN'), findsOneWidget);
    expect(find.textContaining('double-membraned', findRichText: true), findsOneWidget);
    expect(find.byType(AnswerOption), findsNothing, reason: 'the passage comes first');

    await tester.tap(find.text('Answer 2 questions'));
    await tester.pumpAndSettle();
    expect(find.text('QUESTION 1 / 2'), findsOneWidget);

    // The passage stays a tap away.
    await tester.tap(_iconButton('Read the passage'));
    await tester.pumpAndSettle();
    expect(find.textContaining('endosymbiotic theory', findRichText: true), findsOneWidget);
    await tester.tapAt(const Offset(200, 40)); // outside the sheet
    await tester.pumpAndSettle();

    await tester.tap(_option('Cristae'));
    await tester.pumpAndSettle();
    expect(find.text('Correct'), findsOneWidget);
    expect(find.textContaining('Thylakoids and grana', findRichText: true), findsOneWidget);
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();

    await tester.tap(_option('They make ATP'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Not quite · the answer is'), findsOneWidget);
    await tester.tap(find.text('Finish'));
    await tester.pumpAndSettle();

    expect(find.text('Practice complete'), findsOneWidget);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    expect(find.text('The cell\'s power stations'), findsOneWidget);
    expect(find.text('Done'), findsOneWidget, reason: 'every question answered');
  });
}
