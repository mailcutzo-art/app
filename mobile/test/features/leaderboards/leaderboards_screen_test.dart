import 'package:design_system/design_system.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_app/app/live/live_hub.dart';
import 'package:quiz_app/app/router.dart';
import 'package:quiz_app/core/network/app_failure.dart';
import 'package:quiz_app/features/leaderboards/board_screen.dart';
import 'package:quiz_app/features/leaderboards/data/fake_leaderboard_repository.dart';
import 'package:quiz_app/features/leaderboards/leaderboards_screen.dart';

import '../../support/fakes.dart';

final _now = DateTime.utc(2026, 9, 26, 14, 30);

void main() {
  late FakeLeaderboardRepository boards;

  setUp(() => boards = FakeLeaderboardRepository.seeded(me: fakeUser(), now: _now));

  Future<void> pumpHub(WidgetTester tester, {String location = Routes.leaderboards}) async {
    usePhoneViewport(tester, height: 1600);
    await pumpApp(
      tester,
      prefs: await testPrefs(),
      leaderboards: boards,
      location: location,
      overrides: [liveClockProvider.overrideWithValue(() => _now)],
    );
  }

  testWidgets('the hub starts with the viewer\'s positions, then one card per board', (
    tester,
  ) async {
    await pumpHub(tester);

    expect(find.text('Leaderboards'), findsOneWidget);
    expect(find.textContaining('this week · '), findsOneWidget);
    expect(find.textContaining('Overall: 7 more rated games'), findsOneWidget);
    expect(boards.calls, ['hub:neet'], reason: 'defaults to the viewer\'s exam');

    expect(find.text('This week'), findsOneWidget);
    expect(find.text('Overall rating'), findsOneWidget);
    expect(find.text('Biology this week'), findsOneWidget);
    expect(find.text('Maths this week'), findsNothing, reason: 'NEET views never show Maths');
    expect(find.text('Ends in 1 d 4 h'), findsWidgets);
    expect(find.text('Play 7 more rated battles to appear'), findsOneWidget);
    expect(find.text('▲ 25'), findsWidgets, reason: 'the change since yesterday');
    expect(find.textContaining(' leads'), findsWidgets);

    expect(find.text('Last week\'s champions'), findsOneWidget);
    expect(find.byType(Podium), findsOneWidget);
  });

  testWidgets('All India shows everyone, including the other exam\'s subjects', (tester) async {
    await pumpHub(tester);

    await tester.tap(find.text('All India'));
    await tester.pumpAndSettle();

    expect(boards.calls.last, 'hub:null');
    await tester.scrollUntilVisible(find.text('Maths this week'), 300);
    expect(find.text('Maths this week'), findsOneWidget);
  });

  testWidgets('a failed hub offers a retry', (tester) async {
    boards.failures[FakeLeaderboardOp.hub] = const NetworkFailure();
    await pumpHub(tester);

    expect(find.text('Couldn\'t load leaderboards'), findsOneWidget);
    expect(find.text(const NetworkFailure().message), findsOneWidget);

    boards.failures.clear();
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(find.text('This week'), findsOneWidget);
  });

  testWidgets('a card opens its board', (tester) async {
    await pumpHub(tester);

    await tester.tap(find.text('Physics rating'));
    await tester.pumpAndSettle();

    expect(find.byType(BoardScreen), findsOneWidget);
    expect(boards.calls.last, 'rating:physics:neet:null');
  });

  testWidgets('the Home trophy opens the hub', (tester) async {
    await pumpHub(tester, location: Routes.home);

    await tester.tap(find.bySemanticsLabel('Leaderboards'));
    await tester.pumpAndSettle();

    expect(find.byType(LeaderboardsScreen), findsOneWidget);
  });
}
