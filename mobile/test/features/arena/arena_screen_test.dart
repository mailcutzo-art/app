import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_app/app/live/live_hub.dart';
import 'package:quiz_app/app/router.dart';
import 'package:quiz_app/core/auth/session.dart';
import 'package:quiz_app/core/network/app_failure.dart';
import 'package:quiz_app/core/notifications/local_reminders.dart';
import 'package:quiz_app/features/arena/arena_providers.dart';
import 'package:quiz_app/features/arena/data/fake_tournament_repository.dart';
import 'package:quiz_app/features/arena/data/tournament_models.dart';
import 'package:quiz_app/features/arena/tournament_screen.dart';
import 'package:quiz_app/features/arena/widgets/arena_widgets.dart';
import 'package:quiz_app/features/leaderboards/data/leaderboard_models.dart';
import 'package:quiz_app/features/wallet/data/wallet_repository.dart';

import '../../support/battle.dart' show reduceMotion;
import '../../support/fakes.dart';

const arenaMe = PlayerCard(id: 'u1', displayName: 'Aarav', handle: 'aarav');

/// The card of the tournament titled [title].
Finder cardOf(String title) =>
    find.ancestor(of: find.text(title), matching: find.byType(ArenaTournamentCard));

/// The Arena filter [label].
Finder segment(String label) => find.descendant(
  of: find.byWidgetPredicate((w) => w is AppSegmentedControl),
  matching: find.text(label),
);

/// [label] inside the card titled [title].
Finder inCard(String title, String label) =>
    find.descendant(of: cardOf(title).first, matching: find.text(label));

void main() {
  late DateTime now;
  late FakeTournamentRepository arena;

  setUp(() {
    now = DateTime.utc(2026, 9, 28, 10);
    arena = FakeTournamentRepository.seeded(me: arenaMe, now: () => now);
  });

  Future<ProviderContainer> pump(
    WidgetTester tester, {
    String location = Routes.arena,
    bool settle = true,
    FakeWalletRepository? wallet,
    MemoryReminderScheduler? reminders,
    MemoryCalendarExporter? calendar,
  }) async {
    usePhoneViewport(tester, height: 2400);
    // The LIVE badge pulses for ever otherwise.
    reduceMotion(tester);
    final container = await pumpApp(
      tester,
      prefs: await testPrefs(),
      arena: arena,
      wallet: wallet ?? FakeWalletRepository(balance: 245, held: 5),
      reminders: reminders,
      calendar: calendar,
      location: location,
      settle: settle,
      overrides: [liveClockProvider.overrideWithValue(() => now)],
    );
    // The check-in window of the seeded blitz is open: its banner comes up on connect.
    container.read(liveHubProvider.notifier).dismiss(TournamentAlertIds.checkIn('demo-check-in'));
    if (settle) await tester.pumpAndSettle();
    return container;
  }

  testWidgets('skeletons, then My tournaments pinned above the open ones', (tester) async {
    arena.latency = const Duration(milliseconds: 300);
    await pump(tester, settle: false);
    expect(find.byType(Shimmer), findsWidgets);

    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(find.text('My tournaments'), findsOneWidget);
    // Pinned: the blitz in its check-in window, and the live one.
    expect(inCard('Physics Blitz', 'Check in'), findsOneWidget);
    expect(inCard('Biology Night Arena', 'Open'), findsOneWidget);
    expect(find.byType(LiveBadge), findsOneWidget);

    // Open: the pool still growing, the full one, and no JEE-only tournament for a NEET player.
    expect(find.textContaining('5 of 8 needed'), findsOneWidget);
    expect(find.textContaining('Prize now 390 of 2,500 · grows with players'), findsOneWidget);
    expect(inCard('Physics Sunday Cup', 'Register'), findsOneWidget);
    expect(inCard('All-India Arena Finals', 'Full'), findsOneWidget);
    expect(find.text('JEE Maths Night'), findsNothing);
    expect(arena.listCalls, [ArenaFilter.open]);

    final pinnedTop = tester.getTopLeft(cardOf('Physics Blitz').first).dy;
    final openTop = tester.getTopLeft(cardOf('Physics Sunday Cup')).dy;
    expect(pinnedTop < openTop, isTrue);
  });

  testWidgets('the filters show upcoming, live and finished tournaments', (tester) async {
    await pump(tester);
    await tester.tap(segment('Upcoming'));
    await tester.pumpAndSettle();
    expect(find.text('Chemistry Weekend Cup'), findsOneWidget);
    expect(inCard('Chemistry Sprint', 'Locked'), findsOneWidget);
    expect(find.text('LOCKED'), findsOneWidget);

    await tester.tap(segment('Live'));
    await tester.pumpAndSettle();
    expect(find.text('Biology Night Arena'), findsNWidgets(2), reason: 'pinned and listed');

    await tester.tap(segment('Finished'));
    await tester.pumpAndSettle();
    expect(inCard('Chemistry Morning Cup', 'View'), findsOneWidget);
    expect(find.text('CANCELLED'), findsOneWidget);
    expect(inCard('Physics Sunday Cup', 'Results'), findsOneWidget);
  });

  testWidgets('"Browse live contests" shows live and upcoming together', (tester) async {
    await pump(tester, location: Routes.browseLive);
    expect(find.text('Live now'), findsOneWidget);
    expect(find.text('Showing live and upcoming tournaments'), findsOneWidget);
    expect(find.text('Chemistry Weekend Cup'), findsOneWidget);
    expect(arena.listCalls, containsAll([ArenaFilter.live, ArenaFilter.upcoming]));

    await tester.tap(segment('Open'));
    await tester.pumpAndSettle();
    expect(find.text('Live now'), findsNothing);
    expect(find.text('Physics Sunday Cup'), findsOneWidget);
  });

  testWidgets('an empty filter explains itself; a failed one retries', (tester) async {
    arena = FakeTournamentRepository(me: arenaMe, now: () => now)
      ..failures[FakeArenaOp.list] = const NetworkFailure();
    await pump(tester);
    expect(find.text('My tournaments'), findsNothing, reason: 'hidden with no entries');
    expect(find.text('Couldn\'t load tournaments'), findsOneWidget);

    arena.failures.clear();
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('No open tournaments right now'), findsOneWidget);
  });

  testWidgets('Register holds the fee, sets reminders and offers the calendar', (tester) async {
    final reminders = MemoryReminderScheduler();
    final calendar = MemoryCalendarExporter();
    await pump(tester, reminders: reminders, calendar: calendar);
    await tester.tap(inCard('Physics Sunday Cup', 'Register'));
    await tester.pumpAndSettle();

    expect(find.text('Register for Physics Sunday Cup'), findsOneWidget);
    expect(find.text('Entry fee'), findsOneWidget);
    expect(find.text('Your coins'), findsOneWidget);
    expect(find.text('240'), findsOneWidget, reason: 'balance minus what is held');
    expect(find.textContaining('held, not spent'), findsOneWidget);

    await tester.tap(find.text('Register · 25 coins'));
    await tester.pumpAndSettle();
    expect(find.text('You\'re in!'), findsOneWidget);
    expect(find.textContaining('Reminders are set for 1 hour and 15 minutes'), findsOneWidget);
    expect(reminders.scheduled, hasLength(3));
    expect(arena.registerKeys, hasLength(1));

    await tester.tap(find.text('Add to calendar'));
    await tester.pumpAndSettle();
    expect(calendar.added.single.title, 'Physics Sunday Cup');

    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(inCard('Physics Sunday Cup', 'Registered'), findsWidgets);
    expect(find.text('Physics Sunday Cup'), findsNWidgets(2), reason: 'now pinned too');
  });

  testWidgets('a refused registration says why; too few coins disables it', (tester) async {
    arena.coins = 10;
    await pump(tester);
    await tester.tap(inCard('Physics Sunday Cup', 'Register'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Register · 25 coins'));
    await tester.pumpAndSettle();
    expect(
      find.text('You need 25 coins to enter. Win battles and missions to earn more.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    await pump(tester, wallet: FakeWalletRepository(balance: 12));
    await tester.tap(inCard('Physics Sunday Cup', 'Register'));
    await tester.pumpAndSettle();
    expect(find.text('You need 25 coins. You have 12.'), findsOneWidget);
    final button = tester.widget<AppButton>(find.widgetWithText(AppButton, 'Register · 25 coins'));
    expect(button.onPressed, isNull);
  });

  testWidgets('Check in on a card, and tapping a card opens the tournament', (tester) async {
    await pump(tester);
    await tester.tap(inCard('Physics Blitz', 'Check in'));
    await tester.pumpAndSettle();
    expect(find.textContaining('You\'re checked in'), findsOneWidget);
    expect(inCard('Physics Blitz', 'Checked in'), findsOneWidget);

    await tester.tap(find.text('Biology Speed Run'));
    await tester.pumpAndSettle();
    expect(find.byType(TournamentScreen), findsOneWidget);
    expect(find.text('Free entry. Four quick rounds of Biology.'), findsOneWidget);
  });

  group('NextTournamentCard', () {
    Future<void> pumpCard(WidgetTester tester) async {
      reduceMotion(tester);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ...testOverrides(session: SignedIn(fakeUser()), prefs: await testPrefs(), arena: arena),
            liveClockProvider.overrideWithValue(() => now),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const Scaffold(body: SingleChildScrollView(child: NextTournamentCard())),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('shows the viewer\'s live tournament first', (tester) async {
      await pumpCard(tester);
      expect(find.text('Biology Night Arena'), findsOneWidget);
      expect(find.text('Open'), findsOneWidget);
    });

    testWidgets('without entries, the soonest open one with the biggest pool', (tester) async {
      arena = FakeTournamentRepository(
        me: arenaMe,
        now: () => now,
        tournaments: [
          for (final t in seededTournaments(arenaMe, now))
            if (t.card.status.takesEntries && !t.card.entered) t,
        ],
      );
      await pumpCard(tester);
      expect(find.text('Physics Sunday Cup'), findsOneWidget);
      expect(find.text('Register'), findsOneWidget);
    });

    testWidgets('nothing at all when there is no tournament', (tester) async {
      arena = FakeTournamentRepository(me: arenaMe, now: () => now);
      await pumpCard(tester);
      expect(find.byType(ArenaTournamentCard), findsNothing);
      expect(find.byType(ErrorState), findsNothing);
    });
  });
}
