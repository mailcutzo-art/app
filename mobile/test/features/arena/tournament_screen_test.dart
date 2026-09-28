import 'package:design_system/design_system.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_app/app/live/live_hub.dart';
import 'package:quiz_app/app/router.dart';
import 'package:quiz_app/core/auth/user.dart';
import 'package:quiz_app/core/network/app_failure.dart';
import 'package:quiz_app/core/notifications/local_reminders.dart';
import 'package:quiz_app/features/arena/arena_providers.dart';
import 'package:quiz_app/features/arena/data/fake_tournament_repository.dart';
import 'package:quiz_app/features/arena/data/tournament_models.dart';
import 'package:quiz_app/features/arena/tournament_results_screen.dart';
import 'package:quiz_app/features/arena/tournament_screen.dart';
import 'package:quiz_app/features/battle/match/review_screen.dart';
import 'package:quiz_app/features/leaderboards/data/leaderboard_models.dart';
import 'package:quiz_app/features/profile/profile_screen.dart';
import 'package:quiz_app/features/wallet/data/wallet_repository.dart';

import '../../support/battle.dart' show reduceMotion;
import '../../support/fakes.dart';
import '../../support/rt_server.dart';

const _me = PlayerCard(id: 'u1', displayName: 'Aarav', handle: 'aarav');

Finder _tab(String label) => find.descendant(
  of: find.byWidgetPredicate((w) => w is AppSegmentedControl),
  matching: find.text(label),
);

void main() {
  late DateTime now;
  late FakeTournamentRepository arena;
  late MemoryReminderScheduler reminders;
  late TestRealtimeServer server;

  setUp(() {
    now = DateTime.utc(2026, 9, 28, 10);
    arena = FakeTournamentRepository.seeded(me: _me, now: () => now);
    reminders = MemoryReminderScheduler();
    server = TestRealtimeServer();
  });

  Future<ProviderContainer> pump(WidgetTester tester, String location) async {
    usePhoneViewport(tester, height: 2400);
    reduceMotion(tester);
    final container = await pumpApp(
      tester,
      prefs: await testPrefs(),
      arena: arena,
      reminders: reminders,
      realtime: server,
      wallet: FakeWalletRepository(balance: 245),
      location: location,
      overrides: [liveClockProvider.overrideWithValue(() => now)],
    );
    container.read(liveHubProvider.notifier).dismiss(TournamentAlertIds.checkIn('demo-check-in'));
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets('an open tournament: overview, rules, prizes for the field, Register', (
    tester,
  ) async {
    await pump(tester, Routes.tournament(SeededTournaments.open));
    expect(find.text('Physics Sunday Cup'), findsWidgets);
    expect(find.text('REGISTRATION'), findsOneWidget);
    expect(find.text('10 questions × 15 s per game, rated (overall and subject)'), findsOneWidget);
    expect(find.text('Win 1 point, draw 0.5, bye 1.'), findsOneWidget);
    expect(find.text('For NEET · Physics'), findsOneWidget);
    // 5 players: 70/30 of the pool so far (2,500 × 5 / 32 = 390).
    expect(find.text('1st'), findsOneWidget);
    expect(find.text('273'), findsOneWidget);
    expect(find.text('117'), findsOneWidget);
    expect(find.textContaining('For 5 players. Prize now 390 of 2,500'), findsOneWidget);
    expect(find.text('Round 5'), findsOneWidget, reason: 'the schedule of rounds');

    await tester.tap(find.text('Register · 25 coins'));
    await tester.pumpAndSettle();
    expect(find.text('Register for Physics Sunday Cup'), findsOneWidget);
  });

  testWidgets('before the start: standings wait, My games explains, Withdraw refunds', (
    tester,
  ) async {
    await arena.register(SeededTournaments.open, idempotencyKey: 'k');
    await pump(tester, Routes.tournament(SeededTournaments.open));
    expect(find.textContaining('You\'re registered. Check in from'), findsOneWidget);
    expect(find.text('Add to calendar'), findsOneWidget);

    await tester.tap(_tab('Standings'));
    await tester.pumpAndSettle();
    expect(find.text('Standings start with round 1'), findsOneWidget);
    await tester.tap(_tab('My games'));
    await tester.pumpAndSettle();
    expect(find.text('No games yet'), findsOneWidget);

    await tester.tap(find.text('Withdraw'));
    await tester.pumpAndSettle();
    expect(find.text('Before the start you get your 25 coins back in full.'), findsOneWidget);
    await tester.tap(find.widgetWithText(AppButton, 'Withdraw').last);
    await tester.pumpAndSettle();
    expect(find.text('Withdrawn. Your 25 coins are back.'), findsOneWidget);
    expect(reminders.cancelled, hasLength(3));
    expect(find.text('Register · 25 coins'), findsOneWidget);
  });

  testWidgets('in the check-in window: Check in, or Can\'t make it with a full refund', (
    tester,
  ) async {
    await pump(tester, Routes.tournament(SeededTournaments.checkIn));
    expect(find.text('CHECK-IN OPEN'), findsOneWidget);
    expect(find.textContaining('Check in by 10:08'), findsOneWidget);

    await tester.tap(find.text('Can\'t make it'));
    await tester.pumpAndSettle();
    expect(
      find.text('We\'ll take you off the list and return your 10 coins in full.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Stay in'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(AppButton, 'Check in'));
    await tester.pumpAndSettle();
    expect(find.textContaining('You\'re checked in. Round 1 starts in 10 min.'), findsOneWidget);
    expect(arena.find(SeededTournaments.checkIn)!.card.checkedIn, isTrue);
  });

  testWidgets('check-in closed after the window, with the reason', (tester) async {
    await pump(tester, Routes.tournament(SeededTournaments.checkIn));
    arena.failures[FakeArenaOp.checkIn] = const ConflictFailure('x', code: 'CHECK_IN_CLOSED');
    await tester.tap(find.widgetWithText(AppButton, 'Check in'));
    await tester.pumpAndSettle();
    expect(
      find.text('Check-in is closed. It\'s open from 15 to 2 minutes before the start.'),
      findsOneWidget,
    );
  });

  testWidgets('live: the lobby between rounds, live standings and my games', (tester) async {
    server.onMessage = (socket, message) {
      if (message['t'] != 'sub') return;
      socket.push(
        frame('t.standings', {
          'round': 1,
          'rows': [
            {'rank': 1, 'uid': 'x1', 'name': 'Zoya', 'points': 1, 'w': 1, 'd': 0, 'l': 0},
            {'rank': 2, 'uid': 'u1', 'name': 'Aarav', 'points': 1, 'w': 1, 'd': 0, 'l': 0},
          ],
          'me': {'rank': 2, 'uid': 'u1', 'name': 'Aarav', 'points': 1},
        }, 't:${SeededTournaments.live}'),
      );
    };
    final container = await pump(tester, Routes.tournament(SeededTournaments.live));
    expect(find.text('Round 2 of 3'), findsOneWidget);
    expect(find.text('Record'), findsOneWidget);
    expect(find.text('1–0'), findsWidgets);
    expect(find.text('#2 of 12'), findsNothing, reason: 'the rank comes from the detail');
    expect(find.text('Pairing now…'), findsOneWidget);
    expect(find.text('Top of the standings'), findsOneWidget);
    expect(find.text('Zoya'), findsOneWidget, reason: 'the live feed');
    expect(server.sentOfType('sub').single['d'], {'ch': 't:${SeededTournaments.live}'});

    await tester.tap(_tab('My games'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Round 1 · vs '), findsOneWidget);
    expect(find.text('Win · +1 point'), findsOneWidget);
    await tester.tap(find.text('Win · +1 point'));
    await tester.pumpAndSettle();
    expect(find.byType(ReviewScreen), findsOneWidget);
    container.read(routerProvider).pop();
    await tester.pumpAndSettle();

    await tester.tap(find.text('Leave tournament'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('can\'t win a prize and the entry fee isn\'t refunded'),
      findsOneWidget,
    );
    await tester.tap(find.widgetWithText(AppButton, 'Leave tournament').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('You left this tournament'), findsOneWidget);

    container.read(routerProvider).go(Routes.home);
    await tester.pumpAndSettle();
    expect(server.sentOfType('unsub'), hasLength(1));
  });

  testWidgets('standings page with REST and pin my row when it is further down', (tester) async {
    arena = FakeTournamentRepository(
      me: _me,
      now: () => now,
      pageSize: 5,
      tournaments: [
        FakeTournament(
          card: Tournament(
            id: 'done',
            title: 'Maths Masters',
            goal: TournamentGoal.jee,
            status: TournamentStatus.finished,
            startsAt: now.subtract(const Duration(days: 1)),
            rounds: 3,
            players: 9,
            capacity: 16,
            me: const TournamentEntry(registered: true, checkedIn: true),
          ),
          field: [
            for (var i = 0; i < 8; i++) FakeStanding(fakePlayer(i), points: 3 - i * 0.25),
            FakeStanding(_me),
          ],
          currentRound: 3,
          result: const TournamentFinal(rank: 9, players: 9),
        ),
      ],
    );
    await pump(tester, '${Routes.tournament('done')}?tab=standings');
    expect(find.text('3 pts'), findsOneWidget);
    expect(find.text('Aarav (you)'), findsOneWidget, reason: 'pinned below the first page');
    await tester.tap(find.text('Show more'));
    await tester.pumpAndSettle();
    expect(find.text('Aarav (you)'), findsOneWidget, reason: 'listed now, not pinned');
  });

  testWidgets('finished: my result leads to the final results', (tester) async {
    await pump(tester, Routes.tournament(SeededTournaments.finished));
    expect(find.text('You finished #3 of 24'), findsOneWidget);
    await tester.tap(find.text('You finished #3 of 24'));
    await tester.pumpAndSettle();

    expect(find.byType(TournamentResultsScreen), findsOneWidget);
    expect(find.text('You finished #3 of 24'), findsOneWidget);
    expect(find.text('+120'), findsOneWidget);
    expect(find.text('+50 XP'), findsOneWidget);
    expect(find.byType(Podium), findsOneWidget);
    await tester.tap(find.text('Final standings'));
    await tester.pumpAndSettle();
    expect(find.byType(TournamentScreen), findsWidgets);
  });

  testWidgets('a cancelled tournament says so; a missing one offers retry', (tester) async {
    await pump(tester, Routes.tournament(SeededTournaments.cancelled));
    expect(find.text('This tournament was cancelled.'), findsOneWidget);

    await pump(tester, Routes.tournament('nope'));
    expect(find.text('This tournament isn\'t available'), findsOneWidget);
  });

  testWidgets('Profile → Tournaments lists results and opens them', (tester) async {
    await pump(tester, Routes.profile);
    await tester.scrollUntilVisible(_tab('Tournaments'), 300);
    await tester.tap(_tab('Tournaments'));
    await tester.pumpAndSettle();
    expect(find.byType(ProfileScreen), findsOneWidget);
    expect(find.textContaining('#3 of 24 · +120 coins'), findsOneWidget);
    await tester.tap(find.textContaining('#3 of 24 · +120 coins'));
    await tester.pumpAndSettle();
    expect(find.byType(TournamentResultsScreen), findsOneWidget);
  });

  test('the goal used for lists is the viewer\'s exam', () {
    expect(TournamentGoal.jee.admits(Goal.neet), isFalse);
    expect(TournamentGoal.any.admits(Goal.jee), isTrue);
  });
}
