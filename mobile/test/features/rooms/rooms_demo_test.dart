import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_app/app/router.dart';
import 'package:quiz_app/features/battle/demo/demo_server.dart';
import 'package:quiz_app/features/battle/match/group_widgets.dart';
import 'package:quiz_app/features/rooms/rooms_controller.dart';
import 'package:quiz_app/features/social/data/fake_social_repository.dart';

import '../../support/battle.dart';
import '../../support/fakes.dart';

void main() {
  testWidgets('demo: a group room fills up, starts, and plays with standings', (tester) async {
    usePhoneViewport(tester, height: 1600);
    reduceMotion(tester);
    final server = demoServer();
    final container = await pumpDemo(tester, server, location: Routes.roomSetup('group'));
    await advance(tester, const Duration(milliseconds: 500));
    await tester.tap(find.text('5'));
    await advance(tester, const Duration(milliseconds: 300));

    await tester.tap(find.text('Create room'));
    await advance(tester, const Duration(seconds: 1));
    final room = server.currentRoom!;
    expect(location(container), Routes.room(room.id));
    expect(find.text('Players 1/8'), findsOneWidget);

    // Riya, Neha and Kabir join over the next few seconds and get ready.
    await advance(tester, const Duration(seconds: 12));
    expect(find.text('Players 4/8'), findsOneWidget);
    await tester.tap(find.text('Start'));
    await advance(tester, const Duration(seconds: 1));
    expect(location(container), Routes.battleMatch(room.match!.id));

    await pumpUntil(tester, find.byType(GroupHeader), timeout: const Duration(seconds: 10));
    await pumpUntil(tester, find.byType(MiniLeaderboard), timeout: const Duration(seconds: 20));
    expect(container.read(roomViewProvider)?.state.matchId, room.match!.id);
  });

  testWidgets('demo: inviting a friend to a duel, who accepts and joins', (tester) async {
    usePhoneViewport(tester, height: 1600);
    reduceMotion(tester);
    final server = demoServer()..guestsJoin = false;
    await pumpDemo(
      tester,
      server,
      location: Routes.roomSetup('friend', friend: 'u-rahul'),
      social: FakeSocialRepository.seeded(),
    );
    await advance(tester, const Duration(milliseconds: 500));
    await tester.tap(find.text('Create room'));
    await advance(tester, const Duration(seconds: 1));
    expect(find.text('1 invite on its way'), findsOneWidget);

    await advance(tester, const Duration(seconds: 3));
    expect(find.text('Rahul'), findsOneWidget);
    expect(find.text('Players 2/2'), findsOneWidget);
    expect(server.currentRoom!.members, hasLength(2));
  });
}
