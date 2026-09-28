import 'package:design_system/design_system.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_app/app/router.dart';
import 'package:quiz_app/features/battle/match/group_widgets.dart';

import '../../support/battle.dart';
import '../../support/fakes.dart';
import '../../support/room_frames.dart';
import '../../support/rt_server.dart';

void main() {
  final players = [meCard, riyaCard, nehaCard];
  final members = [
    member(riyaCard, host: true, ready: true),
    member(meCard, ready: true),
    member(nehaCard, ready: true),
  ];

  Future<(TestRealtimeServer, RoomFrames, GroupMatchFrames)> start(WidgetTester tester) async {
    usePhoneViewport(tester, height: 1600);
    reduceMotion(tester);
    final server = TestRealtimeServer();
    final room = RoomFrames(roomId: 'R9');
    serveRoom(server, () => room.state(host: 'u2', members: members));
    final container = await pumpApp(
      tester,
      prefs: await testPrefs(),
      realtime: server,
      location: Routes.room('R9'),
      settle: false,
    );
    await advance(tester, const Duration(milliseconds: 800));
    final game = GroupMatchFrames(players: players);
    server.push(room.started(game.matchId));
    await advance(tester, const Duration(milliseconds: 300));
    expect(location(container), Routes.battleMatch(game.matchId));
    return (server, room, game);
  }

  testWidgets('the lineup, answered seats, standings between questions, then the podium', (
    tester,
  ) async {
    final (server, room, game) = await start(tester);

    server.push(game.snapshot());
    await advance(tester, const Duration(milliseconds: 300));
    expect(find.text('Group battle · unrated'), findsOneWidget);
    expect(find.byType(GroupLineup), findsOneWidget);
    expect(find.text('Waiting for everyone…'), findsOneWidget);
    expect(server.sentOfType('match.ready'), hasLength(1));

    server.push(game.snapshot(phase: 'q_open', q: 1));
    await advance(tester, const Duration(milliseconds: 300));
    expect(find.byType(GroupHeader), findsOneWidget);
    expect(find.text('Q 1 / 5'), findsOneWidget);
    server.push(game.progress(1, ['u2', 'u3']));
    await advance(tester, const Duration(milliseconds: 300));
    expect(find.text('2/3 answered'), findsOneWidget);

    server.push(
      game.reveal(
        1,
        gained: {'u1': 120, 'u2': 140, 'u3': 0},
        points: {'u1': 120, 'u2': 140, 'u3': 0},
        standings: [('u2', 1, 2), ('u1', 2, -1), ('u3', 3, -1)],
      ),
    );
    await advance(tester, const Duration(milliseconds: 300));
    expect(find.text('You\'re 2nd · down 1'), findsOneWidget);
    expect(find.byType(MiniLeaderboard), findsOneWidget);
    expect(find.text('Riya'), findsWidgets);
    expect(find.text('↑2'), findsOneWidget);

    server
      ..push(
        game.end(
          result: 'loss',
          reason: 'ended_by_host',
          ranking: [
            ['u2'],
            ['u1'],
            ['u3'],
          ],
          points: {'u1': 120, 'u2': 140, 'u3': 0},
        ),
      )
      ..push(
        room.state(
          host: 'u2',
          status: 'finished',
          matchId: game.matchId,
          members: members,
          rematch: {
            'offered_by': 'u2',
            'until': serverNow() + 180000,
            'accepted': ['u2'],
          },
        ),
      );
    await advance(tester, const Duration(seconds: 1));
    expect(find.text('You finished 2nd of 3'), findsOneWidget);
    expect(find.text('The host ended the game early'), findsOneWidget);
    expect(find.byType(Podium), findsOneWidget);
    expect(find.text('Final ranking'), findsOneWidget);
    expect(find.byType(LeaderboardRow), findsNWidgets(3));
    expect(find.text('Riya wants to play again'), findsOneWidget);

    await tester.tap(find.text('Play again'));
    await advance(tester, const Duration(milliseconds: 300));
    final rematch = server.sentOfType('room.rematch').single['d']! as Map;
    expect(rematch, {'room_id': 'R9', 'accept': true});

    await tester.tap(find.text('Back to lobby'));
    await advance(tester, const Duration(milliseconds: 600));
    expect(find.text('K7M 2QX'), findsOneWidget);
  });

  testWidgets('a late joiner after halfway only watches', (tester) async {
    final (server, _, game) = await start(tester);
    server.push(game.snapshot(phase: 'q_open', q: 4, who: [riyaCard, nehaCard]));
    await advance(tester, const Duration(milliseconds: 300));
    expect(find.byType(SpectatorBanner), findsOneWidget);
    expect(find.text('Watching'), findsOneWidget);
    await tester.tap(find.text('Option A of 4'));
    await advance(tester, const Duration(milliseconds: 300));
    expect(server.sentOfType('ans.submit'), isEmpty);
  });
}
