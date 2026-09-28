import 'package:design_system/design_system.dart' hide Presence;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_app/app/router.dart';
import 'package:quiz_app/core/network/app_failure.dart';
import 'package:quiz_app/core/realtime/live_providers.dart';
import 'package:quiz_app/features/battle/data/battle_models.dart';
import 'package:quiz_app/features/battle/data/fake_battle_repository.dart';
import 'package:quiz_app/features/battle/data/match_models.dart';
import 'package:quiz_app/features/learn/data/fake_learn_repository.dart';
import 'package:quiz_app/features/share/share_models.dart';
import 'package:quiz_app/features/social/data/fake_social_repository.dart';

import '../../support/battle.dart';
import '../../support/fakes.dart';
import '../../support/match_frames.dart';
import '../../support/rt_server.dart';
import '../../support/share_samples.dart';

/// A server that queues searches, acks what a match sends, and answers `match.rematch` with
/// [onRematch] (none: no answer).
TestRealtimeServer _server({
  void Function(TestSocket socket, Map<String, Object?> message)? onRematch,
  void Function(TestSocket socket, Map<String, Object?> message)? onBotJoin,
}) {
  final server = TestRealtimeServer();
  server.onMessage = (socket, message) {
    final data = (message['d'] as Map?)?.cast<String, Object?>() ?? const {};
    switch (message['t']) {
      case 'mm.join' when data['mode'] == 'bot':
        onBotJoin?.call(socket, message);
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
      case 'match.rematch':
        onRematch?.call(socket, message);
    }
  };
  return server;
}

/// Plays [match] to its end: found (after a search from the Battle tab when [search]), two
/// questions (the first right and faster, the second wrong and slower), then `match.end` with
/// [result], and `match.settled` when [settled] is given.
Future<ProviderContainer> _finish(
  WidgetTester tester,
  TestRealtimeServer server,
  MatchFrames match, {
  String mode = 'rated',
  String result = 'win',
  Map<String, Object?>? settled,
  bool search = false,
  FakeMatchRepository? matches,
  FakeLearnRepository? learn,
  FakeSocialRepository? social,
  List<Override> overrides = const [],
}) async {
  final container = await pumpApp(
    tester,
    prefs: await testPrefs(),
    realtime: server,
    matches: matches,
    learn: learn,
    social: social,
    overrides: overrides,
    battle: FakeBattleRepository(
      setup: (goal) => sampleBattleSetup(
        goal,
        last: const BattleSelection(subject: 'physics', chapter: 'kinematics'),
      ),
    ),
    location: search ? Routes.battle : Routes.battleSearch,
    settle: false,
  );
  await advance(tester, const Duration(milliseconds: 500));
  if (search) {
    if (mode == 'casual') {
      await tester.tap(find.text('Casual'));
      await advance(tester, const Duration(milliseconds: 300));
    }
    await tester.tap(find.text(mode == 'bot' ? 'Practice vs Bot' : 'Find opponent'));
    await advance(tester, const Duration(milliseconds: 500));
  }
  final bot = mode == 'bot';
  server
    ..push(match.found(mode: mode, bot: bot))
    ..push(match.snapshot(phase: 'ready_wait', endsAt: serverNow() + 10000))
    ..push(match.show(1, shownAt: serverNow()))
    ..push(
      match.reveal(
        1,
        myPick: match.correct(1),
        theirPick: match.wrong(1),
        myTotals: (139, 1),
        theirTotals: (0, 0),
        bot: bot,
      ),
    )
    ..push(match.show(2, shownAt: serverNow()))
    ..push(
      match.reveal(
        2,
        myPick: match.wrong(2),
        theirPick: match.correct(2),
        myMs: 6000,
        myTotals: (139, 1),
        theirTotals: (135, 1),
        bot: bot,
      ),
    )
    ..push(
      match.end(
        result: result,
        myTotals: result == 'loss' ? (100, 1) : (139, 1),
        theirTotals: result == 'draw' ? (139, 1) : (135, 1),
      ),
    );
  if (settled != null) server.push(frame('match.settled', settled, match.ch));
  await advance(tester, const Duration(milliseconds: 500));
  expect(location(container), Routes.battleMatch(match.matchId));
  return container;
}

Map<String, Object?> _settled(
  MatchFrames match, {
  bool levelUp = false,
  bool rated = true,
  Map<String, Object?> change = const {},
}) => {
  'match_id': match.matchId,
  ...match.settlementData(levelUp: levelUp, rated: rated),
  ...change,
};

RatingDelta _delta(WidgetTester tester) => tester.widget<RatingDelta>(find.byType(RatingDelta));

void main() {
  testWidgets('a rated win: the outcome, the dots, rating, rank, coins, XP, missions and a tip', (
    tester,
  ) async {
    usePhoneViewport(tester, height: 2600);
    reduceMotion(tester);
    final match = MatchFrames();
    await _finish(tester, _server(), match, search: true, settled: _settled(match));

    expect(find.text('Victory!'), findsOneWidget);
    expect(find.text('Physics · Rated'), findsOneWidget);
    expect(find.text('139'), findsOneWidget);
    expect(find.text('135'), findsOneWidget);
    final dots = tester.widget<ResultDots>(find.byType(ResultDots)).dots;
    expect(dots, hasLength(7));
    expect(dots[0].outcome, DotOutcome.right);
    expect(dots[0].speed, DotSpeed.fast);
    expect(dots[1].outcome, DotOutcome.wrong);
    expect(dots[1].speed, DotSpeed.slow);
    expect(dots.skip(2).map((d) => d.outcome), everyElement(DotOutcome.unknown));

    expect(find.text('Physics rating'), findsOneWidget);
    expect(find.text('1518?'), findsOneWidget);
    expect(_delta(tester).delta, 16);
    expect(find.text('You\'re now #42 in Physics · ↑5'), findsOneWidget);
    expect(find.text('COINS'), findsOneWidget);
    expect(find.text('+10'), findsOneWidget);
    expect(find.text('Balance 255'), findsOneWidget);
    expect(find.text('XP'), findsOneWidget);
    expect(find.text('+30'), findsOneWidget);
    expect(find.text('Level 4 · 150/250'), findsOneWidget);
    expect(find.text('5-day streak'), findsOneWidget);
    expect(find.text('Extended today'), findsOneWidget);
    expect(find.text('Play 3 battles'), findsOneWidget);
    expect(find.text('1/3'), findsOneWidget);
    expect(find.text('First win'), findsOneWidget);
    expect(find.text('COACH TIP'), findsOneWidget);
    expect(find.text('You were slower on 4 of 7. Try a timed set in Kinematics.'), findsOneWidget);
    expect(find.text('Timed practice'), findsOneWidget);
    expect(find.text('Results syncing…'), findsNothing);
    expect(find.text('Rematch'), findsNothing, reason: 'rated games have no rematch');
    expect(find.text('Level up!'), findsNothing);
    for (final label in ['Play again', 'Review answers', 'Done']) {
      expect(find.widgetWithText(AppButton, label), findsOneWidget);
    }
  });

  group('share', () {
    testWidgets('the result becomes a card for other apps', (tester) async {
      usePhoneViewport(tester, height: 2600);
      reduceMotion(tester);
      final recorder = ShareRecorder();
      final match = MatchFrames();
      await _finish(
        tester,
        _server(),
        match,
        search: true,
        settled: _settled(match),
        overrides: recorder.overrides,
      );

      await tester.tap(find.bySemanticsLabel('Share result'));
      await tester.pumpAndSettle();
      expect(find.text('Share this battle'), findsOneWidget);
      await tester.tap(find.text('Share to other apps'));
      await tester.pumpAndSettle();

      final card = recorder.captured.single as MatchShareData;
      expect(card.matchId, match.matchId);
      expect(card.outcome, ShareOutcome.win);
      expect((card.subject, card.chapter), ('Physics', 'Motion in a Straight Line'));
      expect((card.score, card.opponentScore), (139, 135));
      expect(card.player.displayName, 'Aarav Sharma');
      expect(card.answers.take(2), [ShareAnswer.correct, ShareAnswer.wrong]);
      expect((card.ratingChange, card.coins, card.xp), (16, 10, 30));
      expect(recorder.shared.single.text, 'I won a Physics battle on Quiz Arena! 🏆');
    });

    testWidgets('Post to friends sends the match id', (tester) async {
      usePhoneViewport(tester, height: 2600);
      reduceMotion(tester);
      final match = MatchFrames();
      final social = FakeSocialRepository(matchResults: {match.matchId: sampleWin});
      await _finish(tester, _server(), match, result: 'draw', social: social);

      await tester.tap(find.bySemanticsLabel('Share result'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Post to friends'));
      await tester.pumpAndSettle();

      expect(social.posted, [MatchShareTarget(match.matchId)]);
      expect(find.text('Posted to your friends'), findsOneWidget);
    });
  });

  testWidgets('a level up is celebrated', (tester) async {
    usePhoneViewport(tester, height: 2600);
    reduceMotion(tester);
    final match = MatchFrames();
    await _finish(tester, _server(), match, settled: _settled(match, levelUp: true));
    expect(find.text('Level up!'), findsOneWidget);
    expect(find.text('You\'re now level 5'), findsOneWidget);
  });

  testWidgets('not ranked yet: how many rated games to go', (tester) async {
    usePhoneViewport(tester, height: 2600);
    reduceMotion(tester);
    final match = MatchFrames();
    await _finish(
      tester,
      _server(),
      match,
      settled: _settled(
        match,
        change: {
          'rank': {'board': 'rating:physics', 'games_to_rank': 6},
        },
      ),
    );
    expect(find.text('Play 6 more rated battles to get ranked'), findsOneWidget);
  });

  testWidgets('the daily coin limit is explained', (tester) async {
    usePhoneViewport(tester, height: 2600);
    reduceMotion(tester);
    final match = MatchFrames();
    await _finish(
      tester,
      _server(),
      match,
      settled: _settled(
        match,
        change: {
          'coins': {'delta': 0, 'balance': 245, 'capped': true},
        },
      ),
    );
    expect(find.text('Daily coin limit reached · resets at midnight'), findsOneWidget);
  });

  testWidgets('a loss shows the rating going down', (tester) async {
    usePhoneViewport(tester, height: 2600);
    reduceMotion(tester);
    final match = MatchFrames();
    await _finish(
      tester,
      _server(),
      match,
      result: 'loss',
      settled: _settled(
        match,
        change: {
          'rating': {'scope': 'physics', 'before': '1502?', 'after': '1490?', 'delta': -12},
          'rank': {'board': 'rating:physics', 'before': 42, 'after': 44},
        },
      ),
    );
    expect(find.text('Defeat'), findsOneWidget);
    expect(_delta(tester).delta, -12);
    expect(find.text('You\'re now #44 in Physics · ↓2'), findsOneWidget);
  });

  testWidgets('a draw', (tester) async {
    usePhoneViewport(tester, height: 2600);
    reduceMotion(tester);
    final match = MatchFrames();
    await _finish(tester, _server(), match, result: 'draw', settled: _settled(match));
    expect(find.text('Draw'), findsOneWidget);
  });

  testWidgets('a Practice Bot game: not rated, no coins, XP only', (tester) async {
    usePhoneViewport(tester, height: 2600);
    reduceMotion(tester);
    final match = MatchFrames(them: 'bot', kind: 'bot');
    await _finish(tester, _server(), match, mode: 'bot', settled: _settled(match, rated: false));
    expect(find.text('Victory!'), findsOneWidget);
    expect(find.text('Practice Bot'), findsWidgets);
    expect(find.text('Practice game · not rated'), findsOneWidget);
    expect(find.text('COINS'), findsNothing);
    expect(find.text('+30'), findsOneWidget);
    expect(find.byType(RatingDelta), findsNothing);
    expect(find.text('Rematch'), findsNothing);
    final dots = tester.widget<ResultDots>(find.byType(ResultDots)).dots;
    expect(dots.first.speed, isNull, reason: 'no speed race against the bot');
  });

  group('rewards that come late', () {
    testWidgets('"Results syncing…", then REST after 20 s: saved, then the rewards', (
      tester,
    ) async {
      usePhoneViewport(tester, height: 2600);
      reduceMotion(tester);
      final matches = FakeMatchRepository()
        ..summaries['m1'] = const MatchSummary(
          id: 'm1',
          status: MatchStatus.settling,
          kind: 'quick_rated',
          result: 'win',
        );
      final match = MatchFrames();
      await _finish(tester, _server(), match, matches: matches);
      expect(find.text('Results syncing…'), findsOneWidget);
      expect(find.text('Victory!'), findsOneWidget, reason: 'the outcome shows right away');
      expect(matches.calls, isEmpty);

      await advance(tester, const Duration(seconds: 20));
      expect(matches.calls, ['m1']);
      expect(find.text('Result saved. Rewards will appear shortly'), findsOneWidget);

      matches.summaries['m1'] = MatchSummary(
        id: 'm1',
        status: MatchStatus.settled,
        kind: 'quick_rated',
        result: 'win',
        settlement: parseSettlement(match.settlementData()),
      );
      await advance(tester, const Duration(seconds: 5));
      expect(matches.calls, hasLength(2));
      expect(find.text('You\'re now #42 in Physics · ↑5'), findsOneWidget);
      expect(find.text('Result saved. Rewards will appear shortly'), findsNothing);
    });

    testWidgets('a failed read says it keeps trying', (tester) async {
      usePhoneViewport(tester, height: 2600);
      reduceMotion(tester);
      final matches = FakeMatchRepository()..failure = const NetworkFailure();
      final match = MatchFrames();
      await _finish(tester, _server(), match, matches: matches);
      await advance(tester, const Duration(seconds: 20));
      expect(find.text('Results syncing… trying again'), findsOneWidget);

      matches
        ..failure = null
        ..summaries['m1'] = MatchSummary(
          id: 'm1',
          status: MatchStatus.settled,
          result: 'win',
          settlement: parseSettlement(match.settlementData()),
        );
      await advance(tester, const Duration(seconds: 5));
      expect(find.text('+16'), findsOneWidget);
      expect(find.textContaining('Results syncing'), findsNothing);
    });

    testWidgets('a dropped connection reads them over REST at once', (tester) async {
      usePhoneViewport(tester, height: 2600);
      reduceMotion(tester);
      final match = MatchFrames();
      final matches = FakeMatchRepository()
        ..summaries['m1'] = MatchSummary(
          id: 'm1',
          status: MatchStatus.settled,
          result: 'win',
          settlement: parseSettlement(match.settlementData()),
        );
      final server = _server();
      await _finish(tester, server, match, matches: matches);
      expect(find.text('Results syncing…'), findsOneWidget);
      server.socket.closeFromServer();
      await advance(tester, const Duration(milliseconds: 300));
      expect(matches.calls, ['m1']);
      expect(find.text('+16'), findsOneWidget);
    });

    testWidgets('a snapshot of a settled game reads the rewards over REST', (tester) async {
      usePhoneViewport(tester, height: 2600);
      reduceMotion(tester);
      final match = MatchFrames(matchId: 'm4')..seq = 30;
      final matches = FakeMatchRepository()
        ..summaries['m4'] = MatchSummary(
          id: 'm4',
          status: MatchStatus.settled,
          kind: 'quick_rated',
          result: 'win',
          settlement: parseSettlement(match.settlementData()),
        );
      final server = _server();
      await pumpApp(
        tester,
        prefs: await testPrefs(),
        realtime: server,
        matches: matches,
        location: Routes.battleMatch('m4'),
        settle: false,
      );
      await advance(tester, const Duration(milliseconds: 300));
      server.push(
        match.snapshot(
          phase: 'finished',
          q: 7,
          scores: {'u1': 540, 'riya': 320},
          end: match.endData(result: 'win', myTotals: (540, 5), theirTotals: (320, 3)),
          settled: true,
        ),
      );
      await advance(tester, const Duration(milliseconds: 500));
      expect(find.text('Victory!'), findsOneWidget);
      expect(find.text('540'), findsOneWidget);
      expect(find.text('You\'re now #42 in Physics · ↑5'), findsOneWidget);
    });
  });

  testWidgets('the coach tip starts a timed practice', (tester) async {
    usePhoneViewport(tester, height: 2600);
    reduceMotion(tester);
    final learn = FakeLearnRepository.seeded();
    final match = MatchFrames();
    final container = await _finish(
      tester,
      _server(),
      match,
      settled: _settled(match),
      learn: learn,
    );
    await tester.tap(find.text('Timed practice'));
    await advance(tester, const Duration(milliseconds: 500));
    final settings = learn.createCalls.single.$1;
    expect(settings.timed, isTrue);
    expect(settings.subject, 'physics');
    expect(settings.chapters, ['kinematics']);
    expect(location(container), startsWith('${Routes.practice}/'));
  });

  group('rematch, in casual games', () {
    Map<String, Object?> status(MatchFrames match, String state, String by) =>
        match.rematch(state, by: by);

    testWidgets('ask, wait, and hear no', (tester) async {
      usePhoneViewport(tester, height: 2600);
      reduceMotion(tester);
      final match = MatchFrames(kind: 'quick_casual');
      final server = _server(
        onRematch: (socket, message) => socket.push(status(match, 'offered', 'u1')),
      );
      await _finish(tester, server, match, mode: 'casual', settled: _settled(match));
      expect(find.text('Physics · Casual'), findsNothing, reason: 'no search, no subject');
      expect(find.text('Casual'), findsOneWidget);

      await tester.tap(find.text('Rematch'));
      await advance(tester, const Duration(milliseconds: 300));
      expect(server.sentOfType('match.rematch').single['d'], {'match_id': 'm1', 'accept': true});
      expect(find.text('Waiting for Riya…'), findsOneWidget);

      server.push(status(match, 'declined', 'riya'));
      await advance(tester, const Duration(milliseconds: 300));
      expect(find.text('Riya said no to a rematch'), findsOneWidget);
      expect(tester.widget<AppButton>(find.widgetWithText(AppButton, 'Rematch')).onPressed, isNull);
    });

    testWidgets('an offer from them: Accept starts the new game at once', (tester) async {
      usePhoneViewport(tester, height: 2600);
      reduceMotion(tester);
      final match = MatchFrames(kind: 'quick_casual');
      final next = MatchFrames(matchId: 'm2', kind: 'quick_casual');
      final server = _server(
        onRematch: (socket, message) => socket
          ..push(status(match, 'accepted', 'u1'))
          ..push(next.found(mode: 'casual'))
          ..push(next.snapshot(phase: 'ready_wait', endsAt: serverNow() + 10000)),
      );
      final container = await _finish(
        tester,
        server,
        match,
        mode: 'casual',
        settled: _settled(match),
      );
      server.push(status(match, 'offered', 'riya'));
      await advance(tester, const Duration(milliseconds: 300));
      expect(find.text('Riya wants a rematch · 5 coins each'), findsOneWidget);
      expect(find.text('Riya wants a rematch'), findsNothing, reason: 'no banner over the result');

      await tester.tap(find.text('Accept rematch'));
      await advance(tester, const Duration(milliseconds: 500));
      expect(location(container), Routes.battleMatch('m2'));
      expect(find.text('Match found!'), findsNothing);
      expect(find.text('MATCH FOUND'), findsOneWidget);
    });

    testWidgets('a refused rematch says why', (tester) async {
      usePhoneViewport(tester, height: 2600);
      reduceMotion(tester);
      final match = MatchFrames(kind: 'quick_casual');
      final server = _server(
        onRematch: (socket, message) => socket.push(
          frame('error', {
            'ref': message['id'],
            'code': 'INSUFFICIENT_COINS',
            'message': 'Not enough coins.',
          }, 'u'),
        ),
      );
      await _finish(tester, server, match, mode: 'casual', settled: _settled(match));
      await tester.tap(find.text('Rematch'));
      await advance(tester, const Duration(milliseconds: 300));
      expect(find.text('You need 5 coins for a rematch.'), findsOneWidget);
    });

    testWidgets('an offer that ran out', (tester) async {
      usePhoneViewport(tester, height: 2600);
      reduceMotion(tester);
      final match = MatchFrames(kind: 'quick_casual');
      final server = _server();
      await _finish(tester, server, match, mode: 'casual', settled: _settled(match));
      server
        ..push(status(match, 'offered', 'riya'))
        ..push(status(match, 'expired', 'riya'));
      await advance(tester, const Duration(milliseconds: 300));
      expect(find.text('The rematch offer ran out'), findsOneWidget);
    });

    testWidgets('an offer while reviewing shows as a banner', (tester) async {
      usePhoneViewport(tester, height: 2600);
      reduceMotion(tester);
      final match = MatchFrames(kind: 'quick_casual');
      final server = _server(
        onRematch: (socket, message) => socket.push(status(match, 'declined', 'u1')),
      );
      final container = await _finish(
        tester,
        server,
        match,
        mode: 'casual',
        settled: _settled(match),
      );
      await tester.tap(find.text('Review answers'));
      await advance(tester, const Duration(milliseconds: 500));
      expect(location(container), Routes.battleReview('m1'));

      server.push(status(match, 'offered', 'riya'));
      await advance(tester, const Duration(milliseconds: 500));
      expect(find.text('Riya wants a rematch'), findsOneWidget);
      await tester.tap(find.text('Decline'));
      await advance(tester, const Duration(milliseconds: 500));
      expect(server.sentOfType('match.rematch').single['d'], {'match_id': 'm1', 'accept': false});
      expect(find.text('Riya wants a rematch'), findsNothing);
    });
  });

  group('what next', () {
    testWidgets('Play again searches with the same settings', (tester) async {
      usePhoneViewport(tester, height: 2600);
      reduceMotion(tester);
      final match = MatchFrames();
      final server = _server();
      final container = await _finish(
        tester,
        server,
        match,
        search: true,
        settled: _settled(match),
      );
      await tester.tap(find.text('Play again'));
      await advance(tester, const Duration(milliseconds: 500));
      final joins = server.sentOfType('mm.join');
      expect(joins, hasLength(2));
      expect(joins.last['d'], containsPair('chapter', 'kinematics'));
      expect(joins.last['d'], containsPair('mode', 'rated'));
      expect(location(container), Routes.battleSearch);
      expect(find.text('Finding an opponent…'), findsOneWidget);
      expect(container.read(liveControllerProvider)!.match('m1'), isNull, reason: 'let go');
    });

    testWidgets('Play again after a bot game starts another bot game', (tester) async {
      usePhoneViewport(tester, height: 2600);
      reduceMotion(tester);
      final match = MatchFrames(them: 'bot', kind: 'bot');
      final next = MatchFrames(matchId: 'm2', them: 'bot', kind: 'bot');
      var joins = 0;
      final server = _server(
        onBotJoin: (socket, message) {
          final frames = joins++ == 0 ? match : next;
          socket
            ..push(frames.found(mode: 'bot', bot: true))
            ..push(frames.snapshot(phase: 'ready_wait', endsAt: serverNow() + 10000));
        },
      );
      final container = await pumpApp(
        tester,
        prefs: await testPrefs(),
        realtime: server,
        location: Routes.battle,
        settle: false,
      );
      await advance(tester, const Duration(milliseconds: 500));
      await tester.tap(find.text('Practice vs Bot'));
      await advance(tester, const Duration(milliseconds: 500));
      expect(location(container), Routes.battleMatch('m1'));
      server
        ..push(match.end(result: 'win', myTotals: (300, 3)))
        ..push(match.settled(rated: false));
      await advance(tester, const Duration(milliseconds: 500));

      await tester.tap(find.text('Play again'));
      await advance(tester, const Duration(milliseconds: 500));
      expect(server.sentOfType('mm.join').last['d'], containsPair('mode', 'bot'));
      expect(location(container), Routes.battleMatch('m2'));
      expect(find.text('PRACTICE BOT'), findsOneWidget);
    });

    testWidgets('Play again for a game reopened after a restart goes to the Battle tab', (
      tester,
    ) async {
      usePhoneViewport(tester, height: 2600);
      reduceMotion(tester);
      final matches = FakeMatchRepository()
        ..summaries['m5'] = const MatchSummary(
          id: 'm5',
          status: MatchStatus.settled,
          kind: 'quick_rated',
          result: 'loss',
          scoreMe: 200,
          scoreOther: 380,
        );
      final server = _server();
      final container = await pumpApp(
        tester,
        prefs: await testPrefs(),
        realtime: server,
        matches: matches,
        location: Routes.battleMatch('m5'),
        settle: false,
      );
      await advance(tester, const Duration(milliseconds: 500));
      expect(find.text('Defeat'), findsOneWidget);
      await tester.tap(find.text('Play again'));
      await advance(tester, const Duration(milliseconds: 500));
      expect(server.sentOfType('mm.join'), isEmpty);
      expect(location(container), Routes.battle);
    });

    testWidgets('Done and back both return to the Battle tab and let the match go', (tester) async {
      usePhoneViewport(tester, height: 2600);
      reduceMotion(tester);
      final match = MatchFrames();
      final prefs = await testPrefs();
      final server = _server();
      final container = await pumpApp(
        tester,
        prefs: prefs,
        realtime: server,
        location: Routes.battleSearch,
        settle: false,
      );
      await advance(tester, const Duration(milliseconds: 500));
      server
        ..push(match.found())
        ..push(match.snapshot(phase: 'ready_wait', endsAt: serverNow() + 10000))
        ..push(match.end(result: 'win', myTotals: (300, 3)))
        ..push(match.settled());
      await advance(tester, const Duration(milliseconds: 500));
      expect(prefs.getString('battle.active_match.u1'), 'm1');

      await tester.binding.handlePopRoute();
      await advance(tester, const Duration(milliseconds: 500));
      expect(location(container), Routes.battle);
      expect(container.read(liveControllerProvider)!.match('m1'), isNull);
      expect(prefs.getString('battle.active_match.u1'), isNull);
      expect(find.text('Leave the battle?'), findsNothing);
    });
  });
}
