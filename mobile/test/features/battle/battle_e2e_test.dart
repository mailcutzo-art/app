import 'package:design_system/design_system.dart' hide Presence;
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_app/app/router.dart';
import 'package:quiz_app/features/battle/demo/demo_server.dart';

import '../../support/battle.dart';
import '../../support/fakes.dart';
import '../../support/rt_server.dart';

Finder _option(String? text) => find.byWidgetPredicate((w) => w is AnswerOption && w.text == text);

void main() {
  late DemoRealtimeServer server;

  setUp(() {
    server = demoServer()
      ..opponentPlan = [for (var q = 0; q < 7; q++) const DemoAnswerPlan(correct: false, ms: 2500)];
  });

  testWidgets('Battle tab → search → widened → found → VS → 3-2-1 → 7 questions → result → Done', (
    tester,
  ) async {
    usePhoneViewport(tester, height: 1100);
    reduceMotion(tester);
    server
      ..world.firstSearch = false
      ..findAfter = const Duration(seconds: 16);
    final guard = FakeScreenGuard();
    final container = await pumpDemo(tester, server, screenGuard: guard);

    expect(find.text('Quick battle'), findsOneWidget);
    expect(find.text('1502?'), findsOneWidget, reason: 'the Physics rating');
    expect(find.text('3 players searching · usually 20 s'), findsOneWidget);
    expect(find.text('Physics this week: Riya leads · you\'re #12'), findsOneWidget);

    // Pick a chapter.
    await tester.tap(find.text('All chapters'));
    await advance(tester, const Duration(milliseconds: 500));
    expect(find.text('Choose a chapter'), findsOneWidget);
    expect(find.text('Coming soon'), findsOneWidget, reason: 'Work, Energy and Power');
    await tester.tap(find.text('Motion in a Straight Line'));
    await advance(tester, const Duration(milliseconds: 500));

    await tester.tap(find.text('Find opponent'));
    await pumpUntil(tester, find.text('Finding an opponent…'));
    expect(location(container), Routes.battleSearch);
    expect(find.text('Looking for a Physics player in Motion in a Straight Line…'), findsOneWidget);
    expect(server.receivedOfType('mm.join').single['d'], containsPair('chapter', 'kinematics'));

    await advance(tester, const Duration(seconds: 15));
    expect(find.text('Widened to all of Physics'), findsOneWidget);

    // Found on the search screen: straight to the VS screen, which says ready.
    await pumpUntil(tester, find.text('MATCH FOUND'));
    final matchId = server.currentMatch!.id;
    expect(location(container), Routes.battleMatch(matchId));
    expect(find.text('Riya'), findsWidgets);
    expect(find.text('You 3 – 1 Riya'), findsOneWidget);
    await pumpUntil(tester, find.text('Waiting for Riya…'));
    expect(server.receivedOfType('match.ready'), hasLength(1));
    expect(guard.protecting, isTrue, reason: 'screen kept on and protected');

    await pumpUntil(tester, find.text('Get ready'));
    for (var q = 1; q <= 7; q++) {
      final correct = server.optionText(matchId, q, server.correctOption(matchId, q));
      await pumpUntil(tester, _option(correct));
      await tester.tap(_option(correct));
      await tester.pump();
      expect(tester.widget<AnswerOption>(_option(correct)).state, AnswerOptionState.selected);
      await pumpUntil(tester, find.textContaining('s faster'));
      expect(find.textContaining('You were'), findsOneWidget);
      expect(tester.widget<AnswerOption>(_option(correct)).state, AnswerOptionState.correct);
    }

    await pumpUntil(tester, find.text('Victory!'), timeout: const Duration(seconds: 10));
    await pumpUntil(tester, find.text('You\'re now #42 in Physics · ↑5'));
    expect(find.text('+16'), findsOneWidget);
    expect(find.byType(ResultDots), findsOneWidget);
    expect(find.text('Play again'), findsOneWidget);
    expect(find.text('Review answers'), findsOneWidget);

    await tester.ensureVisible(find.text('Done'));
    await tester.pump();
    await tester.tap(find.text('Done'));
    await advance(tester, const Duration(seconds: 1));
    expect(location(container), Routes.battle);
    expect(find.text('1518?'), findsOneWidget, reason: 'the new rating');
    expect(guard.protecting, isFalse);
  });
}
