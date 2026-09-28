import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_app/app/live/live_hub.dart';
import 'package:quiz_app/app/router.dart';
import 'package:quiz_app/core/auth/user.dart';
import 'package:quiz_app/core/network/app_failure.dart';
import 'package:quiz_app/features/battle/battle_screen.dart';
import 'package:quiz_app/features/leaderboards/data/fake_leaderboard_repository.dart';
import 'package:quiz_app/features/leaderboards/data/leaderboard_models.dart';

import '../../support/fakes.dart';

final _now = DateTime.utc(2026, 9, 26, 14, 30);

PlayerCard _player(int i) => PlayerCard(id: 'p$i', handle: 'player_$i', displayName: 'Player $i');

void main() {
  late FakeLeaderboardRepository boards;

  setUp(() => boards = FakeLeaderboardRepository.seeded(me: fakeUser(), now: _now));

  Future<ProviderContainer> pumpBoard(WidgetTester tester, String board) async {
    usePhoneViewport(tester);
    return pumpApp(
      tester,
      prefs: await testPrefs(),
      leaderboards: boards,
      location: Routes.board(board),
      overrides: [liveClockProvider.overrideWithValue(() => _now)],
    );
  }

  testWidgets('the top rows, with the viewer pinned at the bottom and more on scroll', (
    tester,
  ) async {
    await pumpBoard(tester, 'weekly_xp');

    expect(find.text('This week'), findsOneWidget);
    expect(find.textContaining('NEET · Ends in 1 d 4 h · You\'re in the top '), findsOneWidget);
    expect(find.textContaining('(you)'), findsOneWidget, reason: 'the sticky row');
    expect(boards.calls.first, 'weekly_xp:neet:null');

    for (var i = 0; i < 2; i++) {
      await tester.drag(find.byType(ListView), const Offset(0, -3000));
      await tester.pumpAndSettle();
    }
    expect(boards.calls, contains('weekly_xp:neet:50'));
  });

  testWidgets('below the top 100, the players around the viewer follow the list', (tester) async {
    final me = fakeUser();
    boards.boards['weekly_xp'] = FakeBoard(
      title: 'This week',
      entries: [
        for (var i = 1; i <= 130; i++) FakeEntry(_player(i), 1000 - i),
        FakeEntry(PlayerCard(id: me.id, handle: me.handle, displayName: me.displayName), 10),
      ],
    );
    await pumpBoard(tester, 'weekly_xp');

    // Scrolling loads the rest of the top 100; then come the players around the viewer.
    await tester.drag(find.byType(ListView), const Offset(0, -3000));
    await tester.pumpAndSettle();
    expect(boards.calls, contains('weekly_xp:neet:50'));

    // The pinned row jumps to them.
    await tester.tap(find.textContaining('(you)').last);
    await tester.pumpAndSettle();
    expect(find.text('Around you'), findsOneWidget);
    expect(find.text('Player 130'), findsOneWidget);
  });

  testWidgets('not ranked yet: how many rated battles are left, and Play', (tester) async {
    await pumpBoard(tester, 'rating:overall');

    expect(find.text('Not on this board yet'), findsOneWidget);
    expect(find.text('Play 7 more rated battles to appear'), findsOneWidget);
    expect(find.textContaining('(you)'), findsNothing);

    await tester.tap(find.text('Play'));
    await tester.pumpAndSettle();
    expect(find.byType(BattleScreen), findsOneWidget);
  });

  testWidgets('a board with few players asks to be one of the first and offers All India', (
    tester,
  ) async {
    boards.boards['weekly:chemistry'] = FakeBoard(
      title: 'Chemistry this week',
      entries: [
        FakeEntry(_player(1), 90, goal: Goal.neet),
        FakeEntry(_player(2), 80, goal: Goal.jee),
        FakeEntry(_player(3), 70, goal: Goal.jee),
      ],
      gamesToRank: 1,
    );
    await pumpBoard(tester, 'weekly:chemistry');

    expect(find.text('Be one of the first on this board'), findsOneWidget);
    expect(find.text('Player 2'), findsNothing);
    expect(find.text('Play 1 battle to appear'), findsOneWidget);

    await tester.tap(find.text('All India'));
    await tester.pumpAndSettle();
    expect(boards.calls.last, 'weekly:chemistry:null:null');
    expect(find.text('Player 2'), findsOneWidget);
  });

  testWidgets('an empty board invites the viewer to be first', (tester) async {
    boards.boards['weekly:chemistry'] = FakeBoard(title: 'Chemistry this week', entries: []);
    await pumpBoard(tester, 'weekly:chemistry');

    expect(find.text('Be one of the first on this board'), findsOneWidget);
    expect(find.text('See All India'), findsOneWidget);
  });

  testWidgets('a failed board offers a retry', (tester) async {
    boards.failures[FakeLeaderboardOp.board] = const ServerFailure();
    await pumpBoard(tester, 'weekly_xp');

    expect(find.text('Couldn\'t load this board'), findsOneWidget);
    boards.failures.clear();
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(find.textContaining('(you)'), findsOneWidget);
  });

  testWidgets('tapping a player opens their profile', (tester) async {
    boards.boards['friends:weekly_xp'] = FakeBoard(
      title: 'Friends this week',
      filtered: false,
      entries: [FakeEntry(_player(1), 90)],
    );
    final container = await pumpBoard(tester, 'friends:weekly_xp');

    await tester.tap(find.text('Player 1'));
    await tester.pumpAndSettle();
    expect(container.read(routerProvider).state.uri.path, '/u/player_1');
  });
}
