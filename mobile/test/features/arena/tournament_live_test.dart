import 'package:design_system/design_system.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_app/app/live/live_hub.dart';
import 'package:quiz_app/app/router.dart';
import 'package:quiz_app/core/notifications/local_reminders.dart';
import 'package:quiz_app/features/arena/arena_providers.dart';
import 'package:quiz_app/features/arena/data/fake_tournament_repository.dart';
import 'package:quiz_app/features/arena/tournament_live.dart';
import 'package:quiz_app/features/arena/tournament_reminders.dart';
import 'package:quiz_app/features/arena/tournament_results_screen.dart';
import 'package:quiz_app/features/arena/tournament_screen.dart';
import 'package:quiz_app/features/leaderboards/data/leaderboard_models.dart';

import '../../support/battle.dart' show reduceMotion;
import '../../support/fakes.dart';
import '../../support/rt_server.dart';

const _me = PlayerCard(id: 'u1', displayName: 'Aarav', handle: 'aarav');

Map<String, Object?> _aman() => {
  'uid': 'p7',
  'handle': 'aman_7',
  'display_name': 'Aman',
  'avatar': {'tone': 'sky', 'symbol': 'atom'},
  'level': 6,
  'is_bot': false,
};

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

  Future<ProviderContainer> pump(WidgetTester tester, {String location = Routes.home}) async {
    usePhoneViewport(tester, height: 1400);
    reduceMotion(tester);
    return pumpApp(
      tester,
      prefs: await testPrefs(),
      arena: arena,
      reminders: reminders,
      realtime: server,
      location: location,
      overrides: [liveClockProvider.overrideWithValue(() => now)],
    );
  }

  /// Lets frames from the server arrive and the live layer animate in.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  String location(ProviderContainer container) =>
      container.read(routerProvider).routerDelegate.currentConfiguration.uri.toString();

  void dismissRecoveredCheckIn(ProviderContainer container) => container
      .read(liveHubProvider.notifier)
      .dismiss(TournamentAlertIds.checkIn(SeededTournaments.checkIn));

  testWidgets('a check-in missed while away comes back after connecting', (tester) async {
    await pump(tester);
    await settle(tester);
    expect(find.text('Check in for Physics Blitz'), findsOneWidget);
    expect(find.text('Can\'t make it'), findsOneWidget);
  });

  testWidgets('t.check_in: Check in on the banner checks in, never by itself', (tester) async {
    final container = await pump(tester);
    await settle(tester);
    dismissRecoveredCheckIn(container);
    await settle(tester);
    server.push(
      frame('t.check_in', {
        'tournament_id': SeededTournaments.checkIn,
        'title': 'Physics Blitz',
        'starts_at': serverNow() + const Duration(minutes: 10).inMilliseconds,
        'closes_at': serverNow() + const Duration(minutes: 8).inMilliseconds,
      }, 'u'),
    );
    await settle(tester);
    expect(find.text('Check in for Physics Blitz'), findsOneWidget);
    expect(find.textContaining('Expires in 8:00'), findsOneWidget);
    expect(arena.find(SeededTournaments.checkIn)!.card.checkedIn, isFalse);

    await tester.tap(find.text('Check in'));
    await settle(tester);
    expect(arena.find(SeededTournaments.checkIn)!.card.checkedIn, isTrue);
    expect(find.text('Check in for Physics Blitz'), findsNothing);
    expect(location(container), Routes.home, reason: 'no navigation');
  });

  testWidgets('Can\'t make it on the banner withdraws with a full refund', (tester) async {
    await pump(tester);
    await settle(tester);
    final coins = arena.coins;
    await tester.tap(find.text('Can\'t make it'));
    await settle(tester);
    expect(arena.find(SeededTournaments.checkIn)!.card.me, isNull);
    expect(arena.coins, coins + 10);
    expect(reminders.cancelled, hasLength(3));
  });

  testWidgets('t.pairing takes over any screen; Join opens the round\'s game', (tester) async {
    final container = await pump(tester);
    await settle(tester);
    dismissRecoveredCheckIn(container);
    server.push(
      frame('t.pairing', {
        'tournament_id': SeededTournaments.live,
        'round': 2,
        'match_id': 'm9',
        'ch': 'm:m9',
        'opponent': _aman(),
        'ready_by': serverNow() + 90000,
      }, 'u'),
    );
    await settle(tester);
    expect(find.text('Round 2: you vs Aman'), findsOneWidget);
    expect(find.text('1:30'), findsOneWidget, reason: 'the join countdown');
    expect(container.read(tournamentLiveProvider).tournamentOf('m9'), SeededTournaments.live);
    expect(server.sentOfType('sync').map((m) => (m['d']! as Map)['ch']), contains('m:m9'));

    await tester.tap(find.text('Join'));
    await settle(tester);
    expect(location(container), Routes.battleMatch('m9'));
    expect(find.text('Round 2: you vs Aman'), findsNothing);
  });

  testWidgets('the round call wins over a check-in banner (prompt priority)', (tester) async {
    await pump(tester);
    await settle(tester);
    expect(find.text('Check in for Physics Blitz'), findsOneWidget);
    server.push(
      frame('t.pairing', {
        'tournament_id': SeededTournaments.live,
        'round': 2,
        'match_id': 'm9',
        'opponent': _aman(),
      }, 'u'),
    );
    await settle(tester);
    expect(find.text('Round 2: you vs Aman'), findsOneWidget);
    expect(find.text('Check in for Physics Blitz'), findsNothing, reason: 'waits its turn');
  });

  testWidgets('t.bye, t.at_risk and t.cancelled explain what happened', (tester) async {
    final container = await pump(tester);
    await settle(tester);
    dismissRecoveredCheckIn(container);

    server.push(frame('t.bye', {'tournament_id': SeededTournaments.live, 'round': 2}, 'u'));
    await settle(tester);
    expect(find.text('Round 2: you have a bye'), findsOneWidget);
    expect(find.text('You have a bye this round (+1 point)'), findsOneWidget);
    container
        .read(liveHubProvider.notifier)
        .dismiss(TournamentAlertIds.bye(SeededTournaments.live, 2));

    server.push(
      frame('t.at_risk', {'tournament_id': SeededTournaments.open, 'players': 5, 'needed': 3}, 'u'),
    );
    await settle(tester);
    expect(find.text('At risk: 3 more players needed'), findsOneWidget);
    await tester.tap(find.text('Invite friends'));
    await settle(tester);
    expect(location(container), Routes.social);

    await container
        .read(tournamentRemindersProvider)
        .scheduleFor(arena.find(SeededTournaments.checkIn)!.card);
    expect(reminders.scheduled, isNotEmpty);
    server.push(
      frame('t.cancelled', {
        'tournament_id': SeededTournaments.checkIn,
        'reason': 'not_enough_players',
        'refunded': 10,
      }, 'u'),
    );
    await settle(tester);
    expect(find.text('Cancelled: Physics Blitz'), findsOneWidget);
    expect(find.text('Not enough players. Your 10 coins are back.'), findsOneWidget);
    expect(reminders.scheduled, isEmpty, reason: 'its reminders are removed');
  });

  testWidgets('t.finished: the result, and See results opens them', (tester) async {
    final container = await pump(tester);
    await settle(tester);
    dismissRecoveredCheckIn(container);
    server.push(
      frame('t.finished', {
        'tournament_id': SeededTournaments.finished,
        'rank': 3,
        'players': 24,
        'points': 3.5,
        'prize': 120,
        'xp': 50,
      }, 'u'),
    );
    await settle(tester);
    expect(find.text('You finished #3 of 24'), findsOneWidget);
    expect(find.text('Physics Sunday Cup · +120 coins · +50 XP'), findsOneWidget);
    await tester.tap(find.text('See results'));
    await tester.pumpAndSettle();
    expect(find.byType(TournamentResultsScreen), findsOneWidget);
  });

  testWidgets('"Tournament live" pill from welcome.active, except on the tournament', (
    tester,
  ) async {
    server.active = [
      {'kind': 'tournament', 'id': SeededTournaments.live, 'title': 'Biology Night Arena'},
    ];
    final container = await pump(tester);
    await settle(tester);
    dismissRecoveredCheckIn(container);
    await settle(tester);
    expect(find.text('Tournament live'), findsOneWidget);

    await tester.tap(find.text('Tournament live'));
    await tester.pumpAndSettle();
    expect(find.byType(TournamentScreen), findsOneWidget);
    expect(find.text('Tournament live'), findsNothing);

    container.read(routerProvider).go(Routes.arena);
    await tester.pumpAndSettle();
    expect(find.text('Tournament live'), findsOneWidget);

    server.push(
      frame('t.finished', {'tournament_id': SeededTournaments.live, 'rank': 1, 'players': 12}, 'u'),
    );
    await settle(tester);
    expect(find.text('Tournament live'), findsNothing);
    expect(find.byType(LiveBadge), findsWidgets, reason: 'the Arena still shows it');
  });

  testWidgets('t.standings reaches the subscribed screen; t.round moves the lobby', (tester) async {
    final container = await pump(tester, location: Routes.tournament(SeededTournaments.live));
    await settle(tester);
    dismissRecoveredCheckIn(container);
    expect(server.sentOfType('sub'), hasLength(1));
    server.push(
      frame('t.round', {
        'round': 2,
        'status': 'pairing',
        'starts_at': serverNow() + 48000,
      }, 't:${SeededTournaments.live}'),
    );
    server.push(
      frame('t.standings', {
        'round': 1,
        'rows': [
          {'rank': 1, 'uid': 'x1', 'name': 'Zoya', 'points': 1},
        ],
        'me': null,
      }, 't:${SeededTournaments.live}'),
    );
    await settle(tester);
    expect(find.text('Pairing in 0:48'), findsOneWidget);
    expect(find.text('Zoya'), findsOneWidget);

    // A reconnect subscribes again (t: channels aren't resumed).
    server.socket.closeFromServer(1012);
    await tester.pump(const Duration(seconds: 3));
    await settle(tester);
    expect(server.sentOfType('sub').length, greaterThanOrEqualTo(2));
  });
}
