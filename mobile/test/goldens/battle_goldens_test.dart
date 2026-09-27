import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_app/app/app.dart';
import 'package:quiz_app/app/router.dart';
import 'package:quiz_app/features/battle/data/battle_models.dart';
import 'package:quiz_app/features/battle/data/fake_battle_repository.dart';

import '../support/battle.dart';
import '../support/fakes.dart';
import '../support/match_frames.dart';
import '../support/rt_server.dart';

/// Golden screenshots of Quick Battle, light and dark, on a phone (390 × 844).
///
/// Update with `flutter test --update-goldens test/goldens/battle_goldens_test.dart`.
void main() {
  setUpAll(() {
    final current = goldenFileComparator;
    if (current is LocalFileComparator) {
      goldenFileComparator = _TolerantComparator(
        current.basedir.resolve('battle_goldens_test.dart'),
      );
    }
  });

  for (final brightness in Brightness.values) {
    final theme = brightness.name;
    Future<void> matches(WidgetTester tester, String name) =>
        expectLater(find.byType(QuizApp), matchesGoldenFile('battle/$theme/$name.png'));

    group('$theme theme', () {
      testWidgets('Battle tab', (tester) async {
        _phone(tester, brightness);
        await _pump(tester, TestRealtimeServer(), location: Routes.battle);
        await matches(tester, 'battle_tab');
      });

      testWidgets('search, widened', (tester) async {
        _phone(tester, brightness);
        final server = _server();
        await _pump(tester, server, location: Routes.battle);
        await tester.tap(find.text('Find opponent'));
        await advance(tester, const Duration(milliseconds: 500));
        await advance(tester, const Duration(seconds: 15));
        server.push(
          frame('mm.status', {'waited_s': 15, 'widened': true, 'online': 3, 'p50_wait_s': 20}, 'u'),
        );
        await advance(tester, const Duration(milliseconds: 300));
        expect(find.text('Widened to all of Physics'), findsOneWidget);
        await matches(tester, 'search_widened');
      });

      testWidgets('question open', (tester) async {
        _phone(tester, brightness);
        final match = MatchFrames();
        final server = _server();
        await _pump(tester, server, location: Routes.battleSearch);
        await _question(tester, server, match);
        expect(find.text('Riya answered'), findsOneWidget);
        await matches(tester, 'question_open');
      });

      testWidgets('reveal', (tester) async {
        _phone(tester, brightness);
        final match = MatchFrames();
        final server = _server();
        await _pump(tester, server, location: Routes.battleSearch);
        await _question(tester, server, match);
        await tester.tap(find.text('Answer D of 3'));
        await tester.pump();
        server.push(
          match.reveal(
            3,
            myPick: match.correct(3),
            theirPick: match.wrong(3),
            myTotals: (401, 3),
            theirTotals: (135, 1),
          ),
        );
        await advance(tester, const Duration(milliseconds: 300));
        expect(find.text('You were 1.2 s faster'), findsOneWidget);
        await matches(tester, 'reveal');
      });

      testWidgets('result, a win with a rank', (tester) async {
        _phone(tester, brightness);
        final match = MatchFrames();
        final server = _server();
        await _pump(tester, server, location: Routes.battle);
        await tester.tap(find.text('Find opponent'));
        await advance(tester, const Duration(milliseconds: 500));
        server
          ..push(match.found())
          ..push(match.snapshot(phase: 'ready_wait', endsAt: serverNow() + 10000));
        var mine = (0, 0);
        var theirs = (0, 0);
        // Right and faster, except question 2 (wrong) and 5 (right, but slower).
        for (var q = 1; q <= 7; q++) {
          final right = q != 2;
          final myMs = q == 5 ? 7000 : 4000;
          final theirRight = q.isOdd;
          final reveal = match.revealData(
            q,
            myPick: right ? match.correct(q) : match.wrong(q),
            theirPick: theirRight ? match.correct(q) : match.wrong(q),
            myMs: myMs,
            myTotals: mine,
            theirTotals: theirs,
          );
          final players = reveal['players']! as Map<String, Object?>;
          int points(String uid) => (players[uid]! as Map<String, Object?>)['pts']! as int;
          mine = (mine.$1 + points('u1'), mine.$2 + (right ? 1 : 0));
          theirs = (theirs.$1 + points('riya'), theirs.$2 + (theirRight ? 1 : 0));
          server
            ..push(match.show(q, shownAt: serverNow()))
            ..push(
              match.reveal(
                q,
                myPick: right ? match.correct(q) : match.wrong(q),
                theirPick: theirRight ? match.correct(q) : match.wrong(q),
                myMs: myMs,
                myTotals: mine,
                theirTotals: theirs,
              ),
            );
        }
        server
          ..push(match.end(result: 'win', myTotals: mine, theirTotals: theirs))
          ..push(match.settled());
        await advance(tester, const Duration(milliseconds: 600));
        expect(find.text('You\'re now #42 in Physics · ↑5'), findsOneWidget);
        await matches(tester, 'result_win');
      });
    });
  }
}

/// A phone in [brightness], with motion reduced so pulses and rings hold still.
void _phone(WidgetTester tester, Brightness brightness) {
  tester.view
    ..physicalSize = const Size(390 * 2, 844 * 2)
    ..devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  tester.platformDispatcher.platformBrightnessTestValue = brightness;
  addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
  reduceMotion(tester);
}

/// A server that queues searches and acks what a match sends.
TestRealtimeServer _server() {
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
      case 'match.ready' || 'emote':
        socket.push(frame('ack', {'ref': message['id']}, 'u'));
      case 'ans.submit':
        socket.push(frame('ans.ack', {'ref': message['id'], 'q': data['q'], 'status': 'accepted'}));
    }
  };
  return server;
}

Future<ProviderContainer> _pump(
  WidgetTester tester,
  TestRealtimeServer server, {
  required String location,
}) async {
  final container = await pumpApp(
    tester,
    prefs: await testPrefs(),
    realtime: server,
    battle: FakeBattleRepository(
      setup: (goal) => sampleBattleSetup(
        goal,
        last: const BattleSelection(subject: 'physics', chapter: 'kinematics'),
      ),
    ),
    location: location,
    settle: false,
  );
  await advance(tester, const Duration(seconds: 1));
  return container;
}

/// Question 3 of a match with Riya, 4 s in; Riya has answered.
Future<void> _question(WidgetTester tester, TestRealtimeServer server, MatchFrames match) async {
  server.push(match.found());
  await advance(tester, const Duration(milliseconds: 300));
  match.seq = 20;
  server.push(
    match.snapshot(
      phase: 'q_open',
      q: 3,
      scores: {'u1': 262, 'riya': 135},
      answered: {'riya'},
      question: match.showData(3, shownAt: serverNow() - 4000),
    ),
  );
  await advance(tester, const Duration(milliseconds: 300));
}

/// Accepts tiny anti-aliasing differences between machines (0.3% of pixels).
class _TolerantComparator extends LocalFileComparator {
  _TolerantComparator(super.testFile);

  static const _tolerance = 0.003;

  @override
  Future<bool> compare(Uint8List imageBytes, Uri golden) async {
    final result = await GoldenFileComparator.compareLists(
      imageBytes,
      await getGoldenBytes(golden),
    );
    if (result.passed || result.diffPercent <= _tolerance) {
      if (!result.passed) {
        debugPrint('Golden $golden differs by ${(result.diffPercent * 100).toStringAsFixed(3)}%');
      }
      result.dispose();
      return true;
    }
    final error = await generateFailureOutput(result, golden, basedir);
    result.dispose();
    throw FlutterError(error);
  }
}
