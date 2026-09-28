import 'package:design_system/design_system.dart' hide Presence;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_app/app/router.dart';
import 'package:quiz_app/features/battle/demo/demo_server.dart';

import '../../support/battle.dart';
import '../../support/fakes.dart';
import '../../support/rt_server.dart';

Finder _option(String? text, [AnswerOptionState? state]) => find.byWidgetPredicate(
  (w) => w is AnswerOption && w.text == text && (state == null || w.state == state),
);

/// Waits for question [q] to go live and taps its right (or a wrong) answer.
Future<void> _answer(
  WidgetTester tester,
  DemoRealtimeServer server,
  int q, {
  bool right = true,
}) async {
  final matchId = server.currentMatch!.id;
  final option = right ? server.correctOption(matchId, q) : server.wrongOption(matchId, q);
  final text = server.optionText(matchId, q, option);
  await pumpUntil(tester, _option(text));
  await tester.tap(_option(text));
  await tester.pump();
}

/// Waits until question [q] is revealed.
Future<void> _revealed(WidgetTester tester, DemoRealtimeServer server, int q) async {
  final matchId = server.currentMatch!.id;
  final correct = server.optionText(matchId, q, server.correctOption(matchId, q));
  await pumpUntil(tester, _option(correct, AnswerOptionState.correct));
}

/// From the Battle tab to the 3-2-1 of a match with Riya.
Future<void> _startMatch(WidgetTester tester, DemoRealtimeServer server) async {
  server
    ..world.firstSearch = false
    ..findAfter = const Duration(seconds: 1);
  await tester.tap(find.text('Find opponent'));
  await pumpUntil(tester, find.text('Get ready'));
}

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

    await tester.scrollUntilVisible(
      find.text('Done'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Done'));
    await advance(tester, const Duration(seconds: 1));
    expect(location(container), Routes.battle);
    expect(find.text('1518?'), findsOneWidget, reason: 'the new rating');
    expect(guard.protecting, isFalse);
  });

  testWidgets('the first search offers the Practice Bot at 20 s; the bot game is not rated', (
    tester,
  ) async {
    usePhoneViewport(tester, height: 1100);
    reduceMotion(tester);
    await pumpDemo(tester, server);
    await tester.tap(find.text('Find opponent'));
    await pumpUntil(tester, find.text('Finding an opponent…'));

    await advance(tester, const Duration(seconds: 19));
    expect(find.text('No one found yet'), findsNothing);
    await pumpUntil(tester, find.text('No one found yet'), timeout: const Duration(seconds: 3));
    await advance(tester, const Duration(milliseconds: 500));
    final invite = tester.widget<AppButton>(find.widgetWithText(AppButton, 'Invite a friend'));
    expect(invite.onPressed, isNotNull);

    await tester.tap(find.text('Play a Practice Bot'));
    await pumpUntil(tester, find.text('PRACTICE BOT'));
    expect(server.receivedOfType('mm.respond').single['d'], {'choice': 'bot'});
    expect(find.text('Practice game · not rated'), findsOneWidget);

    for (var q = 1; q <= 7; q++) {
      await _answer(tester, server, q);
      await _revealed(tester, server, q);
      expect(find.textContaining('faster'), findsNothing, reason: 'no speed labels with the bot');
    }
    await pumpUntil(tester, find.text('Victory!'), timeout: const Duration(seconds: 10));
    await advance(tester, const Duration(seconds: 2));
    expect(find.text('Practice game · not rated'), findsWidgets);
    expect(find.textContaining('You\'re now #'), findsNothing, reason: 'no rank change');
  });

  testWidgets('Cancel stops the search and goes back to the Battle tab', (tester) async {
    usePhoneViewport(tester);
    reduceMotion(tester);
    server
      ..world.firstSearch = false
      ..findAfter = const Duration(seconds: 30);
    final container = await pumpDemo(tester, server);
    await tester.tap(find.text('Find opponent'));
    await pumpUntil(tester, find.text('Finding an opponent…'));
    expect(server.searching, isTrue);

    await tester.tap(find.widgetWithText(AppButton, 'Cancel'));
    await advance(tester, const Duration(seconds: 1));
    expect(server.receivedOfType('mm.cancel'), hasLength(1));
    expect(server.searching, isFalse);
    expect(location(container), Routes.battle);
    expect(find.text('Find opponent'), findsOneWidget);
    expect(find.textContaining('Searching ·'), findsNothing);
  });

  testWidgets('leaving the search shows the pill everywhere; it leads back, and a match found '
      'elsewhere takes over the screen', (tester) async {
    usePhoneViewport(tester);
    reduceMotion(tester);
    server
      ..world.firstSearch = false
      ..findAfter = const Duration(seconds: 12);
    final container = await pumpDemo(tester, server);
    await tester.tap(find.text('Find opponent'));
    await pumpUntil(tester, find.text('Finding an opponent…'));
    expect(
      find.textContaining('Searching ·'),
      findsNothing,
      reason: 'no pill on the search screen',
    );

    await tester.tap(find.bySemanticsLabel('Back'));
    await advance(tester, const Duration(seconds: 3));
    expect(location(container), Routes.battle);
    expect(find.textContaining('Searching · 0:0'), findsOneWidget);

    container.read(routerProvider).go(Routes.learn);
    await advance(tester, const Duration(seconds: 1));
    expect(find.textContaining('Searching · 0:0'), findsOneWidget, reason: 'on every tab');

    await tester.tap(find.textContaining('Searching · 0:0'));
    await advance(tester, const Duration(milliseconds: 500));
    expect(location(container), Routes.battleSearch);
    expect(find.textContaining('Searching ·'), findsNothing);

    // Off the search screen again when Riya is found: the takeover waits for one tap (within
    // the 10 s ready window), so nobody is dropped into a game mid-scroll.
    container.read(routerProvider).go(Routes.home);
    await pumpUntil(tester, find.text('Match found!'));
    expect(find.text('You vs Riya · Physics'), findsOneWidget);
    await advance(tester, const Duration(milliseconds: 2500));
    expect(location(container), Routes.home, reason: 'not opened without a tap');
    expect(find.text('Match found!'), findsOneWidget);
    expect(find.textContaining(RegExp(r'^0:0[5-8]$')), findsOneWidget, reason: 'counting down');

    await tester.tap(find.text('Play now'));
    await advance(tester, const Duration(milliseconds: 500));
    expect(location(container), Routes.battleMatch(server.currentMatch!.id));
    expect(find.text('Match found!'), findsNothing);
  });

  testWidgets('an opponent who drops shows "reconnecting" with the time they have left', (
    tester,
  ) async {
    usePhoneViewport(tester);
    reduceMotion(tester);
    server
      ..opponentDropsAtQ = 2
      ..opponentAwayFor = const Duration(seconds: 6);
    await pumpDemo(tester, server);
    await _startMatch(tester, server);
    await _answer(tester, server, 1);
    await _revealed(tester, server, 1);

    await pumpUntil(tester, find.textContaining('Riya is reconnecting…'));
    expect(find.text('Riya is reconnecting… 30 s'), findsOneWidget);
    await advance(tester, const Duration(seconds: 2));
    expect(find.text('Riya is reconnecting… 28 s'), findsOneWidget);
    await advance(tester, const Duration(seconds: 5));
    expect(find.textContaining('reconnecting'), findsNothing, reason: 'Riya is back');
  });

  testWidgets('results sync late: "Results syncing…", then fetched over REST after 20 s', (
    tester,
  ) async {
    usePhoneViewport(tester, height: 1100);
    reduceMotion(tester);
    server
      ..withholdSettlement = true
      ..opponentPlan = [for (var q = 0; q < 7; q++) const DemoAnswerPlan(correct: false, ms: 1000)];
    await pumpDemo(tester, server);
    await _startMatch(tester, server);
    for (var q = 1; q <= 7; q++) {
      await _answer(tester, server, q);
      await _revealed(tester, server, q);
    }
    await pumpUntil(tester, find.text('Victory!'), timeout: const Duration(seconds: 10));
    expect(find.text('Results syncing…'), findsOneWidget);
    await advance(tester, const Duration(seconds: 18));
    expect(find.text('Results syncing…'), findsOneWidget, reason: 'waiting for match.settled');
    expect(find.textContaining('You\'re now #'), findsNothing);

    await advance(tester, const Duration(seconds: 3));
    expect(find.text('Results syncing…'), findsNothing);
    expect(find.text('You\'re now #42 in Physics · ↑5'), findsOneWidget);
  });

  testWidgets('leaving asks first; Leave forfeits and shows the loss', (tester) async {
    usePhoneViewport(tester);
    reduceMotion(tester);
    await pumpDemo(tester, server);
    await _startMatch(tester, server);
    final matchId = server.currentMatch!.id;
    await pumpUntil(
      tester,
      _option(server.optionText(matchId, 1, server.correctOption(matchId, 1))),
    );

    await tester.tap(find.bySemanticsLabel('Leave the battle'));
    await advance(tester, const Duration(milliseconds: 500));
    expect(find.text('Leave the battle?'), findsOneWidget);
    expect(find.text('You\'ll lose this game.'), findsOneWidget);
    await tester.tap(find.text('Keep playing'));
    await advance(tester, const Duration(milliseconds: 500));
    expect(find.text('Leave the battle?'), findsNothing);
    expect(server.receivedOfType('match.forfeit'), isEmpty);

    await tester.tap(find.bySemanticsLabel('Leave the battle'));
    await advance(tester, const Duration(milliseconds: 500));
    await tester.tap(find.widgetWithText(AppButton, 'Leave'));
    await pumpUntil(tester, find.text('Defeat'));
    expect(server.receivedOfType('match.forfeit'), hasLength(1));
    expect(find.textContaining('You left the game'), findsOneWidget);
  });

  testWidgets('BUSY answers "You\'re already in a match" with Go there', (tester) async {
    usePhoneViewport(tester);
    reduceMotion(tester);
    server.busyOnJoin = {'kind': 'match', 'id': 'demo-m9', 'title': 'Quick battle vs Riya'};
    final container = await pumpDemo(tester, server);
    await tester.tap(find.text('Find opponent'));
    await pumpUntil(tester, find.text('You\'re already in a match'));
    expect(find.text('Quick battle vs Riya'), findsOneWidget);
    expect(location(container), Routes.battle, reason: 'stays on the tab');

    await tester.tap(find.text('Go there'));
    await advance(tester, const Duration(milliseconds: 500));
    expect(location(container), Routes.battleMatch('demo-m9'));
  });

  testWidgets('a game live on another device asks before moving it here', (tester) async {
    usePhoneViewport(tester);
    reduceMotion(tester);
    server.liveElsewhereMatchId = 'demo-m7';
    final container = await pumpDemo(tester, server);
    await pumpUntil(tester, find.text('Your game is running on another device'));
    expect(find.text('Move it here?'), findsOneWidget);

    await tester.tap(find.text('Not now'));
    await advance(tester, const Duration(milliseconds: 500));
    expect(find.text('Your game is running on another device'), findsNothing);
    expect(server.connected, isFalse);

    // Coming back to the app asks again; Move here takes the game over.
    toBackground(tester);
    await advance(tester, const Duration(milliseconds: 200));
    toForeground(tester);
    await pumpUntil(tester, find.text('Your game is running on another device'));
    await tester.tap(find.text('Move here'));
    await advance(tester, const Duration(seconds: 1));
    final hellos = server.receivedOfType('hello');
    expect((hellos.last['d']! as Map)['takeover'], isTrue);
    expect(server.connected, isTrue);
    expect(location(container), Routes.battleMatch('demo-m7'));
  });
}
