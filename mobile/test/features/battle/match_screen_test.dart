import 'package:design_system/design_system.dart' hide Presence;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_app/app/router.dart';
import 'package:quiz_app/core/network/app_failure.dart';
import 'package:quiz_app/features/battle/data/battle_models.dart';
import 'package:quiz_app/features/battle/data/fake_battle_repository.dart';
import 'package:quiz_app/features/battle/data/match_models.dart';
import 'package:quiz_app/features/battle/match/match_screen.dart';
import 'package:quiz_app/features/battle/match/match_widgets.dart';
import 'package:realtime_client/realtime_client.dart' hide AnswerOption;

import '../../support/battle.dart';
import '../../support/fakes.dart';
import '../../support/match_frames.dart';
import '../../support/rt_server.dart';

/// A server that queues searches and acks what a match sends (`match.ready`, `emote`,
/// `match.forfeit`). Answers are acked only with [ackAnswers].
TestRealtimeServer _server({bool ackAnswers = false}) {
  final server = TestRealtimeServer();
  server.onMessage = (socket, message) {
    final data = (message['d'] as Map?)?.cast<String, Object?>() ?? const {};
    switch (message['t']) {
      case 'mm.join':
        socket.push(
          frame('mm.queued', {
            'ticket_id': 't1',
            'mode': data['mode'],
            'subject': data['subject'],
            'chapter': data['chapter'],
            'joined_at': serverNow(),
          }, 'u'),
        );
      case 'match.ready' || 'emote' || 'match.forfeit':
        socket.push(frame('ack', {'ref': message['id']}, 'u'));
      case 'ans.submit' when ackAnswers:
        socket.push(frame('ans.ack', {'ref': message['id'], 'q': data['q'], 'status': 'accepted'}));
    }
  };
  return server;
}

/// Pumps the app on the search screen, where a found match opens at once.
Future<ProviderContainer> _pump(
  WidgetTester tester,
  TestRealtimeServer server, {
  FakeScreenGuard? guard,
  FakeMatchRepository? matches,
  String location = Routes.battleSearch,
}) async {
  final container = await pumpApp(
    tester,
    prefs: await testPrefs(),
    realtime: server,
    screenGuard: guard,
    matches: matches,
    location: location,
    settle: false,
  );
  await advance(tester, const Duration(milliseconds: 500));
  return container;
}

/// A match with Riya found, on its VS screen.
Future<ProviderContainer> _found(
  WidgetTester tester,
  TestRealtimeServer server,
  MatchFrames match, {
  FakeScreenGuard? guard,
  String mode = 'rated',
}) async {
  final container = await _pump(tester, server, guard: guard);
  server
    ..push(match.found(mode: mode, bot: mode == 'bot'))
    ..push(match.snapshot(phase: 'ready_wait', endsAt: serverNow() + 10000));
  await advance(tester, const Duration(milliseconds: 500));
  expect(location(container), Routes.battleMatch(match.matchId));
  return container;
}

/// Question [q] open (and on screen, unless [shownIn] is later than now).
Future<void> _open(
  WidgetTester tester,
  TestRealtimeServer server,
  MatchFrames match,
  int q, {
  Duration shownIn = Duration.zero,
}) async {
  server.push(match.show(q, shownAt: serverNow() + shownIn.inMilliseconds));
  await advance(tester, const Duration(milliseconds: 200));
}

Finder _option(String text, [AnswerOptionState? state]) => find.byWidgetPredicate(
  (w) => w is AnswerOption && w.text == text && (state == null || w.state == state),
);

AnswerOption _optionWidget(WidgetTester tester, String text) =>
    tester.widget<AnswerOption>(_option(text));

Finder _emoteButton(String label) =>
    find.descendant(of: find.byType(EmoteBar), matching: find.text(label));

void main() {
  group('VS', () {
    testWidgets('both players, the record, where the questions come from; ready once', (
      tester,
    ) async {
      usePhoneViewport(tester);
      reduceMotion(tester);
      final guard = FakeScreenGuard();
      final match = MatchFrames();
      final server = _server();
      final container = await pumpApp(
        tester,
        prefs: await testPrefs(),
        realtime: server,
        screenGuard: guard,
        battle: FakeBattleRepository(
          setup: (goal) => sampleBattleSetup(
            goal,
            last: const BattleSelection(subject: 'physics', chapter: 'kinematics'),
          ),
        ),
        location: Routes.battle,
        settle: false,
      );
      await advance(tester, const Duration(milliseconds: 500));
      await tester.tap(find.text('Find opponent'));
      await advance(tester, const Duration(milliseconds: 500));
      server
        ..push(match.found())
        ..push(match.snapshot(phase: 'ready_wait', endsAt: serverNow() + 10000));
      await advance(tester, const Duration(milliseconds: 500));

      expect(location(container), Routes.battleMatch('m1'));
      expect(find.text('MATCH FOUND'), findsOneWidget);
      expect(find.text('You'), findsOneWidget);
      expect(find.text('Riya'), findsOneWidget);
      expect(find.text('Level 6'), findsOneWidget);
      expect(find.text('Level 4'), findsOneWidget, reason: 'mine, from the snapshot');
      expect(find.text('1548'), findsOneWidget, reason: 'their rating');
      expect(find.text('1502?'), findsOneWidget, reason: 'my Physics rating');
      expect(find.text('You 3 – 1 Riya'), findsOneWidget);
      expect(find.text('4 from Kinematics · 3 from Laws of Motion'), findsOneWidget);
      expect(find.text('Rated'), findsOneWidget);
      expect(find.text('7 questions · 15 s each'), findsOneWidget);
      expect(find.text('Waiting for Riya…'), findsOneWidget);
      expect(server.sentOfType('match.ready').single['d'], {'match_id': 'm1'});
      expect(guard.protecting, isTrue, reason: 'the screen stays on and can\'t be captured');

      // The same phase again (a resync) doesn't send ready twice.
      server.push(match.snapshot(phase: 'ready_wait', endsAt: serverNow() + 9000));
      await advance(tester, const Duration(milliseconds: 500));
      expect(server.sentOfType('match.ready'), hasLength(1));
    });

    testWidgets('the Practice Bot is a practice game, not rated', (tester) async {
      usePhoneViewport(tester);
      reduceMotion(tester);
      final match = MatchFrames(them: 'bot', kind: 'bot');
      final server = _server();
      await _found(tester, server, match, mode: 'bot');
      expect(find.text('PRACTICE BOT'), findsOneWidget);
      expect(find.text('Practice game · not rated'), findsOneWidget);
      expect(find.text('Level 6'), findsNothing, reason: 'the bot has no level');
      expect(find.textContaining('You 3'), findsNothing, reason: 'no record against the bot');
      expect(find.text('Waiting for Practice Bot…'), findsOneWidget);
    });

    testWidgets('a casual game says what the winner takes', (tester) async {
      usePhoneViewport(tester);
      reduceMotion(tester);
      final match = MatchFrames(kind: 'quick_casual');
      await _found(tester, _server(), match, mode: 'casual');
      expect(find.text('Casual · winner takes 10 coins'), findsOneWidget);
    });

    testWidgets('a ready that didn\'t get through is sent again after reconnecting', (
      tester,
    ) async {
      usePhoneViewport(tester);
      reduceMotion(tester);
      final match = MatchFrames();
      final server = TestRealtimeServer();
      await _found(tester, server, match);
      expect(server.sentOfType('match.ready'), hasLength(1));

      server.socket.closeFromServer();
      await advance(tester, const Duration(seconds: 3));
      expect(server.sockets, hasLength(2));
      expect(server.socket.sent.where((m) => m['t'] == 'match.ready'), hasLength(1));
    });
  });

  testWidgets('the 3-2-1 follows the server\'s clock', (tester) async {
    usePhoneViewport(tester);
    reduceMotion(tester);
    final match = MatchFrames();
    final server = _server();
    await _found(tester, server, match);
    server.push(match.phase('countdown', endsAt: serverNow() + 3000));
    await advance(tester, const Duration(milliseconds: 100));
    expect(find.text('Get ready'), findsOneWidget);
    expect(find.text('You vs Riya'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    await advance(tester, const Duration(seconds: 1));
    expect(find.text('2'), findsOneWidget);
    await advance(tester, const Duration(seconds: 1));
    expect(find.text('1'), findsOneWidget);
    await advance(tester, const Duration(seconds: 1));
    expect(find.text('Go!'), findsOneWidget);
  });

  group('questions', () {
    testWidgets('nothing of a question shows before its shown_at', (tester) async {
      usePhoneViewport(tester);
      reduceMotion(tester);
      final match = MatchFrames();
      final server = _server();
      await _found(tester, server, match);
      await _open(tester, server, match, 1, shownIn: const Duration(milliseconds: 1500));
      expect(find.text('QUESTION 1 / 7'), findsOneWidget);
      expect(find.text('Get ready…'), findsOneWidget);
      expect(find.textContaining('how far does a car go'), findsNothing);
      expect(find.byType(AnswerOption), findsNothing);
      expect(find.byType(QuestionRing), findsNothing);

      await advance(tester, const Duration(milliseconds: 1400));
      expect(find.textContaining('how far does a car go'), findsOneWidget);
      expect(find.byType(AnswerOption), findsNWidgets(4));
      expect(find.text('Get ready…'), findsNothing);
    });

    testWidgets('the ring counts down on its own, behind a repaint boundary', (tester) async {
      usePhoneViewport(tester);
      reduceMotion(tester);
      final match = MatchFrames();
      final server = _server();
      await _found(tester, server, match);
      await _open(tester, server, match, 1);
      final ring = find.byType(QuestionRing);
      expect(ring, findsOneWidget);
      expect(find.descendant(of: ring, matching: find.byType(RepaintBoundary)), findsWidgets);
      expect(find.descendant(of: ring, matching: find.text('15')), findsOneWidget);
      await advance(tester, const Duration(seconds: 2));
      expect(find.descendant(of: ring, matching: find.text('13')), findsOneWidget);
      expect(find.text('Q1'), findsOneWidget);
      expect(find.text('of 7'), findsOneWidget);
    });

    testWidgets('a pick shows at once, is sent once and locks the question', (tester) async {
      usePhoneViewport(tester);
      reduceMotion(tester);
      final match = MatchFrames();
      final server = _server(ackAnswers: true);
      await _found(tester, server, match);
      await _open(tester, server, match, 1);
      await advance(tester, const Duration(seconds: 2));

      await tester.tap(_option('Answer B of 1'));
      await tester.pump();
      expect(_optionWidget(tester, 'Answer B of 1').state, AnswerOptionState.selected);
      expect(_optionWidget(tester, 'Answer A of 1').state, AnswerOptionState.dimmed);
      final submit = server.sentOfType('ans.submit').single['d']! as Map;
      expect(submit['match_id'], 'm1');
      expect(submit['q'], 1);
      expect(submit['opt'], match.option(1, 1));
      expect(submit['el_ms'], inInclusiveRange(1900, 2300));
      await advance(tester, const Duration(milliseconds: 200));
      expect(find.text('Locked in · waiting for Riya'), findsOneWidget);

      await tester.tap(_option('Answer C of 1'), warnIfMissed: false);
      await advance(tester, const Duration(milliseconds: 200));
      expect(server.sentOfType('ans.submit'), hasLength(1));
      expect(_optionWidget(tester, 'Answer C of 1').onTap, isNull);

      server.push(match.progress(1, ['u1', 'riya']));
      await advance(tester, const Duration(milliseconds: 200));
      expect(find.text('Both answered'), findsOneWidget);
    });

    testWidgets('"Riya answered" when they are first', (tester) async {
      usePhoneViewport(tester);
      reduceMotion(tester);
      final match = MatchFrames();
      final server = _server();
      await _found(tester, server, match);
      await _open(tester, server, match, 1);
      server.push(match.progress(1, ['riya']));
      await advance(tester, const Duration(milliseconds: 200));
      expect(find.text('Riya answered'), findsOneWidget);
    });

    testWidgets('an answer that arrived late says "Time\'s up"', (tester) async {
      usePhoneViewport(tester);
      reduceMotion(tester);
      final match = MatchFrames();
      final server = _server();
      await _found(tester, server, match);
      await _open(tester, server, match, 1);
      await tester.tap(_option('Answer A of 1'));
      await tester.pump();
      server.push(match.ansAck(server.socket.lastIdOf('ans.submit'), 1, status: 'late'));
      await advance(tester, const Duration(milliseconds: 200));
      expect(find.text('Time\'s up'), findsOneWidget);
      expect(_optionWidget(tester, 'Answer A of 1').state, isNot(AnswerOptionState.selected));
    });

    testWidgets('when time runs out without a pick, the options lock', (tester) async {
      usePhoneViewport(tester);
      reduceMotion(tester);
      final match = MatchFrames();
      final server = _server();
      await _found(tester, server, match);
      await _open(tester, server, match, 1);
      await advance(tester, const Duration(seconds: 15));
      expect(find.text('Time\'s up'), findsOneWidget);
      expect(_optionWidget(tester, 'Answer A of 1').onTap, isNull);
      await tester.tap(_option('Answer A of 1'), warnIfMissed: false);
      await tester.pump();
      expect(server.sentOfType('ans.submit'), isEmpty);
    });

    testWidgets('the reveal: right and wrong, their pick, the points, who was faster', (
      tester,
    ) async {
      usePhoneViewport(tester);
      reduceMotion(tester);
      final match = MatchFrames();
      final server = _server(ackAnswers: true);
      await _found(tester, server, match);
      await _open(tester, server, match, 1);
      await tester.tap(_option('Answer B of 1'));
      await tester.pump();
      server.push(
        match.reveal(
          1,
          myPick: match.correct(1),
          theirPick: match.wrong(1),
          myTotals: (139, 1),
          theirTotals: (0, 0),
        ),
      );
      await advance(tester, const Duration(milliseconds: 300));
      expect(_optionWidget(tester, 'Answer B of 1').state, AnswerOptionState.correct);
      expect(_optionWidget(tester, 'Answer C of 1').opponent, isNotNull, reason: 'their pick');
      expect(_optionWidget(tester, 'Answer B of 1').opponent, isNull);
      expect(find.text('+139'), findsOneWidget);
      expect(find.text('You were 1.2 s faster'), findsOneWidget);
      expect(find.text('Next question coming up'), findsOneWidget);
      expect(find.text('139'), findsOneWidget, reason: 'my score in the header');

      await _open(tester, server, match, 2);
      expect(find.text('+139'), findsNothing);
      await tester.tap(_option('Answer D of 2'));
      await tester.pump();
      server.push(
        match.reveal(
          2,
          myPick: match.wrong(2),
          theirPick: match.correct(2),
          myMs: 6000,
          myTotals: (139, 1),
          theirTotals: (139, 1),
        ),
      );
      await advance(tester, const Duration(milliseconds: 300));
      expect(_optionWidget(tester, 'Answer D of 2').state, AnswerOptionState.wrong);
      expect(_optionWidget(tester, 'Answer C of 2').state, AnswerOptionState.correct);
      expect(_optionWidget(tester, 'Answer C of 2').opponent, isNotNull);
      expect(find.text('No points'), findsOneWidget);
      expect(find.text('Riya was 0.8 s faster'), findsOneWidget);
    });

    testWidgets('after the last reveal: "That was the last one"', (tester) async {
      usePhoneViewport(tester);
      reduceMotion(tester);
      final match = MatchFrames(total: 1);
      final server = _server();
      await _found(tester, server, match);
      await _open(tester, server, match, 1);
      server.push(match.reveal(1, myTotals: (0, 0), theirTotals: (0, 0)));
      await advance(tester, const Duration(milliseconds: 300));
      expect(find.text('That was the last one'), findsOneWidget);
      expect(find.text('No points'), findsOneWidget);
    });
  });

  testWidgets('an opponent who drops: "Riya is reconnecting… 23 s", counting down', (tester) async {
    usePhoneViewport(tester);
    reduceMotion(tester);
    final match = MatchFrames();
    final server = _server();
    await _found(tester, server, match);
    await _open(tester, server, match, 1);
    server.push(match.oppConn('reconnecting', graceUntil: serverNow() + 23000));
    await advance(tester, const Duration(milliseconds: 100));
    expect(find.text('Riya is reconnecting… 23 s'), findsOneWidget);
    await advance(tester, const Duration(seconds: 3));
    expect(find.text('Riya is reconnecting… 20 s'), findsOneWidget);

    server.push(match.oppConn('connected'));
    await advance(tester, const Duration(milliseconds: 300));
    expect(find.textContaining('is reconnecting'), findsNothing);
  });

  testWidgets('this phone reconnecting: an overlay, and the answer is resent with its id', (
    tester,
  ) async {
    usePhoneViewport(tester);
    reduceMotion(tester);
    final match = MatchFrames();
    final server = _server();
    await _found(tester, server, match);
    await _open(tester, server, match, 1);
    await tester.tap(_option('Answer A of 1'));
    await tester.pump();
    final first = server.socket.lastIdOf('ans.submit');

    server.socket.closeFromServer();
    await advance(tester, const Duration(milliseconds: 100));
    expect(find.text('Reconnecting… your answers are safe'), findsOneWidget);
    expect(_optionWidget(tester, 'Answer A of 1').state, AnswerOptionState.selected);

    await advance(tester, const Duration(seconds: 3));
    expect(server.sockets, hasLength(2));
    expect(find.text('Reconnecting… your answers are safe'), findsNothing);
    expect(server.socket.lastIdOf('ans.submit'), first, reason: 'the same answer, never lost');
    final hello = server.socket.sent.firstWhere((m) => m['t'] == 'hello')['d']! as Map;
    expect(hello['resume'], [
      {'ch': 'm:m1', 'last_seq': match.seq},
    ], reason: 'the match picks up where it was');
  });

  testWidgets('reactions: one every 3 s, and theirs pops up by their side', (tester) async {
    usePhoneViewport(tester);
    reduceMotion(tester);
    final match = MatchFrames();
    final server = _server();
    await _found(tester, server, match);
    await _open(tester, server, match, 1);

    await tester.tap(_emoteButton('GG'));
    await advance(tester, const Duration(milliseconds: 200));
    expect(server.sentOfType('emote').single['d'], {'match_id': 'm1', 'e': 'gg'});
    await tester.tap(_emoteButton('Nice!'), warnIfMissed: false);
    await advance(tester, const Duration(milliseconds: 200));
    expect(server.sentOfType('emote'), hasLength(1), reason: 'too soon');
    await advance(tester, const Duration(seconds: 3));
    await tester.tap(_emoteButton('Wow'));
    await advance(tester, const Duration(milliseconds: 200));
    expect(server.sentOfType('emote'), hasLength(2));

    server.push(match.emote('riya', 'oops'));
    await advance(tester, const Duration(milliseconds: 200));
    final bubble = find.byType(EmoteBubble);
    expect(bubble, findsOneWidget);
    expect(tester.widget<EmoteBubble>(bubble).label, 'Oops');
    expect(tester.widget<EmoteBubble>(bubble).pointsLeft, isFalse);
    await advance(tester, const Duration(seconds: 2));
    expect(find.byType(EmoteBubble), findsNothing);
  });

  testWidgets('leaving asks first: Keep playing stays, and Back asks too', (tester) async {
    usePhoneViewport(tester);
    reduceMotion(tester);
    final match = MatchFrames();
    final server = _server();
    final container = await _found(tester, server, match);
    await _open(tester, server, match, 1);

    await tester.tap(
      find.byWidgetPredicate((w) => w is AppIconButton && w.semanticLabel == 'Leave the battle'),
    );
    await advance(tester, const Duration(milliseconds: 500));
    expect(find.text('Leave the battle?'), findsOneWidget);
    expect(find.text('You\'ll lose this game.'), findsOneWidget);
    await tester.tap(find.text('Keep playing'));
    await advance(tester, const Duration(milliseconds: 500));
    expect(find.text('Leave the battle?'), findsNothing);
    expect(server.sentOfType('match.forfeit'), isEmpty);
    expect(location(container), Routes.battleMatch('m1'));

    await tester.binding.handlePopRoute();
    await advance(tester, const Duration(milliseconds: 500));
    expect(find.text('Leave the battle?'), findsOneWidget);
    await tester.tap(find.text('Leave'));
    await advance(tester, const Duration(milliseconds: 500));
    expect(server.sentOfType('match.forfeit').single['d'], {'match_id': 'm1'});
    expect(_optionWidget(tester, 'Answer A of 1').onTap, isNull, reason: 'no more answers');

    server.push(match.end(result: 'loss', reason: 'forfeit'));
    await advance(tester, const Duration(milliseconds: 500));
    expect(find.text('Defeat'), findsOneWidget);
    expect(find.text('You left the game'), findsOneWidget);
  });

  testWidgets('the screen is protected only while the match is up', (tester) async {
    usePhoneViewport(tester);
    reduceMotion(tester);
    final guard = FakeScreenGuard();
    final match = MatchFrames();
    final server = _server();
    final container = await _found(tester, server, match, guard: guard);
    expect(guard.protecting, isTrue);
    server
      ..push(match.end(result: 'win', myTotals: (140, 1)))
      ..push(match.settled());
    await advance(tester, const Duration(milliseconds: 500));
    expect(guard.protecting, isTrue, reason: 'the result is part of the match screen');
    await tester.scrollUntilVisible(
      find.text('Done'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Done'));
    await advance(tester, const Duration(milliseconds: 500));
    expect(location(container), Routes.battle);
    expect(guard.protecting, isFalse);
    expect(guard.calls, ['protect', 'release']);
  });

  group('games that end early', () {
    testWidgets('an opponent who never got ready: explained, then back by itself', (tester) async {
      usePhoneViewport(tester);
      reduceMotion(tester);
      final match = MatchFrames(kind: 'quick_casual');
      final server = _server();
      final container = await _found(tester, server, match, mode: 'casual');
      server.push(match.end(result: 'none', reason: 'aborted'));
      await advance(tester, const Duration(milliseconds: 500));
      expect(find.text('The game didn\'t start'), findsOneWidget);
      expect(find.text('Riya didn\'t join · 5 coins returned'), findsOneWidget);
      await advance(tester, const Duration(seconds: 5));
      expect(location(container), Routes.battle);
    });

    testWidgets('a voided game says nothing changed', (tester) async {
      usePhoneViewport(tester);
      reduceMotion(tester);
      final match = MatchFrames();
      final server = _server();
      final container = await _found(tester, server, match);
      await _open(tester, server, match, 1);
      server.push(match.end(result: 'none', reason: 'voided'));
      await advance(tester, const Duration(milliseconds: 500));
      expect(find.text('This game didn\'t count'), findsOneWidget);
      expect(
        find.text('Something went wrong, so ratings and coins didn\'t change'),
        findsOneWidget,
      );
      await advance(tester, const Duration(seconds: 6));
      expect(location(container), Routes.battleMatch('m1'), reason: 'stays until Back');
      await tester.tap(find.text('Back to Battle'));
      await advance(tester, const Duration(milliseconds: 500));
      expect(location(container), Routes.battle);
    });
  });

  group('opened without live state', () {
    testWidgets('waits for the snapshot, then picks up mid-question', (tester) async {
      usePhoneViewport(tester);
      reduceMotion(tester);
      final matches = FakeMatchRepository()
        ..summaries['m3'] = const MatchSummary(id: 'm3', status: MatchStatus.live);
      final match = MatchFrames(matchId: 'm3')..seq = 12;
      final server = _server();
      await _pump(tester, server, matches: matches, location: Routes.battleMatch('m3'));
      expect(find.text('Opening your game…'), findsOneWidget);
      expect(server.sentOfType('sync').single['d'], {'ch': 'm:m3', 'last_seq': 0});

      final shownAt = serverNow() - 4000;
      server.push(
        match.snapshot(
          phase: 'q_open',
          q: 4,
          scores: {'u1': 380, 'riya': 250},
          answered: {'riya'},
          question: match.showData(4, shownAt: shownAt),
        ),
      );
      await advance(tester, const Duration(milliseconds: 300));
      expect(find.text('Question 4: how far does a car go?'), findsOneWidget);
      expect(find.text('380'), findsOneWidget);
      expect(find.text('Riya answered'), findsOneWidget);
      expect(find.descendant(of: find.byType(QuestionRing), matching: find.text('11')), findsOne);
    });

    testWidgets('an answer given before a restart shows from the snapshot', (tester) async {
      usePhoneViewport(tester);
      reduceMotion(tester);
      final matches = FakeMatchRepository()
        ..summaries['m3'] = const MatchSummary(id: 'm3', status: MatchStatus.live);
      final match = MatchFrames(matchId: 'm3')..seq = 5;
      final server = _server();
      await _pump(tester, server, matches: matches, location: Routes.battleMatch('m3'));
      server.push(
        match.snapshot(
          phase: 'q_open',
          q: 2,
          question: match.showData(2, shownAt: serverNow() - 2000),
          answered: {'u1'},
          mine: [
            {'q': 2, 'opt': match.option(2, 3), 'status': 'accepted'},
          ],
        ),
      );
      await advance(tester, const Duration(milliseconds: 300));
      expect(_optionWidget(tester, 'Answer D of 2').state, AnswerOptionState.selected);
      expect(find.text('Locked in · waiting for Riya'), findsOneWidget);
    });

    testWidgets('a game that can\'t be opened says so, and Try again works', (tester) async {
      usePhoneViewport(tester);
      reduceMotion(tester);
      final matches = FakeMatchRepository()..failure = const NetworkFailure();
      final server = _server();
      final container = await _pump(
        tester,
        server,
        matches: matches,
        location: Routes.battleMatch('m3'),
      );
      expect(find.text('Couldn\'t open this game'), findsOneWidget);
      expect(find.text('Back to Battle'), findsOneWidget);

      matches
        ..failure = null
        ..summaries['m3'] = const MatchSummary(
          id: 'm3',
          status: MatchStatus.settled,
          kind: 'quick_rated',
          result: 'win',
          scoreMe: 540,
          scoreOther: 320,
        );
      await tester.tap(find.text('Try again'));
      await advance(tester, const Duration(milliseconds: 500));
      expect(find.text('Victory!'), findsOneWidget);
      expect(location(container), Routes.battleMatch('m3'));
    });
  });

  test('the VS lines', () {
    expect(
      sourcesLine(const [
        SourceChapter(chapter: 'kinematics', name: 'Kinematics', count: 4),
        SourceChapter(chapter: 'laws-of-motion', count: 3),
      ]),
      '4 from Kinematics · 3 from laws-of-motion',
    );
    expect(recordLine(null, 'Riya'), isNull);
    expect(recordLine(const HeadToHead(wins: 0, losses: 0), 'Riya'), isNull);
    expect(recordLine(const HeadToHead(wins: 3, losses: 1), 'Riya'), 'You 3 – 1 Riya');
    expect(
      recordLine(const HeadToHead(wins: 2, losses: 2, draws: 1), 'Riya'),
      'You 2 – 2 Riya · 1 drawn',
    );
    expect(emoteLabel('gg'), 'GG');
    expect(emoteLabel('party'), 'PARTY');
  });
}
