import 'package:design_system/design_system.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_app/app/router.dart';
import 'package:quiz_app/core/network/app_failure.dart';
import 'package:quiz_app/features/battle/match/review_screen.dart';
import 'package:quiz_app/features/profile/data/fake_profile_repository.dart';
import 'package:quiz_app/features/profile/data/profile_models.dart';
import 'package:quiz_app/features/profile/widgets/history_rows.dart';
import 'package:quiz_app/features/settings/settings_screen.dart';
import 'package:quiz_app/features/wallet/data/wallet_repository.dart';
import 'package:quiz_app/features/wallet/wallet_screen.dart';

import '../../support/fakes.dart';

void main() {
  late FakeProfileRepository profile;

  setUp(() => profile = FakeProfileRepository.seeded());

  Future<void> open(WidgetTester tester, {bool settle = true}) async {
    usePhoneViewport(tester, height: 2400);
    await pumpApp(
      tester,
      prefs: await testPrefs(),
      profile: profile,
      wallet: FakeWalletRepository.seeded(),
      location: Routes.profile,
      settle: settle,
    );
  }

  testWidgets('shows skeletons, then every section', (tester) async {
    profile.latency = const Duration(milliseconds: 300);
    await open(tester, settle: false);
    expect(find.byType(Shimmer), findsWidgets);
    expect(find.text('Aarav Sharma'), findsOneWidget, reason: 'the header needs no request');

    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(find.byType(Shimmer), findsNothing);
    // Header: level and XP.
    expect(find.text('@aarav'), findsOneWidget);
    expect(find.text('LEVEL 4'), findsOneWidget);
    expect(find.text('120 / 250 XP'), findsOneWidget);
    // Wallet entry with the balance.
    expect(find.text('245 coins'), findsOneWidget);
    // Stats.
    expect(find.text('Overall'), findsOneWidget);
    expect(find.text('#214'), findsOneWidget);
    expect(find.text('Unranked'), findsOneWidget, reason: 'the provisional Chemistry rating');
    expect(find.text('19 · 2 · 12'), findsOneWidget);
    expect(find.text('68%'), findsOneWidget);
    expect(find.text('1,240'), findsOneWidget);
    expect(find.text('4 days'), findsOneWidget);
    // Chart, opponents, history.
    expect(find.byType(DotMatrixChart), findsOneWidget);
    expect(find.byType(OpponentRow), findsOneWidget);
    expect(find.byType(MatchHistoryRow), findsNWidgets(3));
    expect(find.text('vs Riya'), findsOneWidget);
    expect(find.text('Group battle · #2'), findsOneWidget);
  });

  testWidgets('sections fail on their own and retry on their own', (tester) async {
    profile.failures[FakeProfileOp.stats] = const NetworkFailure();
    await open(tester);

    expect(find.text('Couldn\'t load your stats'), findsOneWidget);
    expect(find.text('Couldn\'t load your rating history'), findsOneWidget);
    expect(find.text('LEVEL 4'), findsNothing);
    expect(find.byType(MatchHistoryRow), findsNWidgets(3), reason: 'history still loads');
    expect(find.byType(OpponentRow), findsOneWidget);

    profile.failures.clear();
    await tester.tap(find.text('Retry').first);
    await tester.pumpAndSettle();
    expect(find.text('Couldn\'t load your stats'), findsNothing);
    expect(find.text('LEVEL 4'), findsOneWidget);
  });

  testWidgets('a new player sees empty states', (tester) async {
    profile = FakeProfileRepository(
      stats: (_) => const PlayerStats(level: LevelInfo(level: 1, forNext: 100)),
    );
    await open(tester);
    expect(find.text('Play rated battles to earn a rating.'), findsOneWidget);
    expect(find.text('No rating history yet'), findsOneWidget);
    expect(find.text('No opponents yet'), findsOneWidget);
    expect(find.text('No battles yet'), findsOneWidget);
    expect(find.text('—'), findsOneWidget, reason: 'no accuracy before any answer');
  });

  testWidgets('the chart range asks for that range once', (tester) async {
    await open(tester);
    expect(profile.statsCalls, [StatsRange.days30]);

    await tester.tap(find.text('90 days'));
    await tester.pumpAndSettle();
    expect(profile.statsCalls, [StatsRange.days30, StatsRange.days90]);
    expect(find.byType(DotMatrixChart), findsOneWidget);

    await tester.tap(find.text('30 days'));
    await tester.pumpAndSettle();
    expect(profile.statsCalls, hasLength(2), reason: 'the 30-day stats are already loaded');
  });

  testWidgets('a played game opens its review; a cancelled one has none', (tester) async {
    await open(tester);
    final cancelled = tester.widget<MatchHistoryRow>(
      find.ancestor(of: find.text('vs Kabir'), matching: find.byType(MatchHistoryRow)),
    );
    expect(cancelled.onTap, isNull);

    await tester.tap(find.text('vs Riya'));
    await tester.pumpAndSettle();
    expect(find.byType(ReviewScreen), findsOneWidget);
  });

  testWidgets('practice history shows scores and continues open sessions', (tester) async {
    final container = await (() async {
      usePhoneViewport(tester, height: 2400);
      return pumpApp(tester, prefs: await testPrefs(), profile: profile, location: Routes.profile);
    })();
    await tester.tap(find.text('Practice'));
    await tester.pumpAndSettle();
    expect(find.byType(PracticeHistoryRow), findsNWidgets(2));
    expect(find.text('50/80'), findsOneWidget);
    expect(find.text('CONTINUE'), findsOneWidget);

    await tester.tap(find.text('Physics · Laws of Motion'));
    await tester.pump();
    expect(currentPath(container.read(routerProvider)), Routes.practiceSession('demo-p2'));
  });

  testWidgets('Show more loads the next page of battles', (tester) async {
    final now = DateTime.now();
    profile = FakeProfileRepository(
      matches: [...sampleMatches(now), ...sampleMatches(now)],
      pageSize: 4,
    );
    await open(tester);
    expect(find.byType(MatchHistoryRow), findsNWidgets(4));

    await tester.tap(find.text('Show more'));
    await tester.pumpAndSettle();
    expect(find.byType(MatchHistoryRow), findsNWidgets(6));
    expect(find.text('Show more'), findsNothing);
    expect(profile.matchCalls, [null, '4']);
  });

  testWidgets('Wallet and Settings open from the profile', (tester) async {
    await open(tester);
    await tester.tap(find.text('Wallet'));
    await tester.pumpAndSettle();
    expect(find.byType(WalletScreen), findsOneWidget);

    await tester.tap(
      find.byWidgetPredicate((w) => w is AppIconButton && w.semanticLabel == 'Back').last,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);
  });
}
