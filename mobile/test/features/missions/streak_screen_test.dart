import 'package:design_system/design_system.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_app/app/router.dart';
import 'package:quiz_app/core/network/app_failure.dart';
import 'package:quiz_app/features/missions/achievements_screen.dart';
import 'package:quiz_app/features/missions/data/fake_missions_repository.dart';
import 'package:quiz_app/features/missions/streak_screen.dart';

import '../../support/fakes.dart';

void main() {
  late FakeMissionsRepository missions;

  setUp(() => missions = FakeMissionsRepository.seeded(today: DateTime.utc(2026, 9, 27)));

  Future<void> pumpAt(WidgetTester tester, String location) async {
    usePhoneViewport(tester, height: 1600);
    await pumpApp(tester, prefs: await testPrefs(), missions: missions, location: location);
  }

  Future<void> buy(WidgetTester tester) async {
    await tester.scrollUntilVisible(find.text('Buy freeze · 50 coins'), 300);
    await tester.tap(find.text('Buy freeze · 50 coins'));
    await tester.pumpAndSettle();
  }

  group('streak', () {
    testWidgets('current and best, 30 days of calendar, and freezes held', (tester) async {
      await pumpAt(tester, Routes.streak);

      expect(find.text('4 days'), findsOneWidget);
      expect(find.text('12'), findsWidgets, reason: 'the best streak');
      expect(find.text('Last 30 days'), findsOneWidget);
      expect(find.text('1 freeze used'), findsOneWidget);
      expect(find.byType(StreakCalendarGrid), findsOneWidget);
      expect(find.bySemanticsLabel('Sep 27, today: not done yet'), findsOneWidget);
      expect(find.bySemanticsLabel('Sep 25: saved by a freeze'), findsOneWidget);
      expect(find.bySemanticsLabel('Sep 26: active'), findsOneWidget);
      expect(find.text('1 of 2 held'), findsOneWidget);
    });

    testWidgets('buying a freeze asks first, then pays once', (tester) async {
      await pumpAt(tester, Routes.streak);

      await buy(tester);
      expect(find.text('Buy a streak freeze?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(missions.freezeKeys, isEmpty);

      await buy(tester);
      await tester.tap(find.text('Buy for 50 coins'));
      await tester.pumpAndSettle();

      expect(missions.freezeKeys, hasLength(1));
      expect(missions.coins, 195);
      expect(find.text('Freeze added. You hold 2.'), findsOneWidget);
      expect(find.text('2 of 2 held'), findsOneWidget);
      expect(find.text('You hold the most freezes'), findsOneWidget);
    });

    testWidgets('a retry after a lost response reuses the idempotency key', (tester) async {
      missions.failures[FakeMissionsOp.buyFreeze] = const NetworkFailure();
      await pumpAt(tester, Routes.streak);

      await buy(tester);
      await tester.tap(find.text('Buy for 50 coins'));
      await tester.pumpAndSettle();
      expect(find.text(const NetworkFailure().message), findsOneWidget);

      missions.failures.clear();
      await buy(tester);
      await tester.tap(find.text('Buy for 50 coins'));
      await tester.pumpAndSettle();
      expect(missions.freezeKeys, hasLength(2));
      expect(missions.freezeKeys.toSet(), hasLength(1));
    });

    testWidgets('a known balance below the price says so before asking', (tester) async {
      missions.coins = 20;
      await pumpAt(tester, Routes.streak);

      await buy(tester);
      expect(find.text('Not enough coins'), findsOneWidget);
      expect(find.text('Buy a streak freeze?'), findsNothing);
      expect(missions.freezeKeys, isEmpty);
    });

    testWidgets('INSUFFICIENT_COINS from the server says so too', (tester) async {
      // The server has the last word when the app's balance is out of date.
      missions.failures[FakeMissionsOp.buyFreeze] = const ConflictFailure(
        'Not enough coins.',
        code: 'INSUFFICIENT_COINS',
      );
      await pumpAt(tester, Routes.streak);

      await buy(tester);
      await tester.tap(find.text('Buy for 50 coins'));
      await tester.pumpAndSettle();
      expect(find.text('Not enough coins'), findsOneWidget);
      expect(find.text('Play a battle'), findsOneWidget);
    });

    testWidgets('a failed load offers a retry', (tester) async {
      missions.failures[FakeMissionsOp.streak] = const ServerFailure();
      await pumpAt(tester, Routes.streak);

      expect(find.text('Couldn\'t load your streak'), findsOneWidget);
      missions.failures.clear();
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(find.text('4 days'), findsOneWidget);
    });
  });

  group('achievements', () {
    testWidgets('earned first, then the rest with progress', (tester) async {
      await pumpAt(tester, Routes.achievements);

      expect(find.text('2 of 6 earned'), findsOneWidget);
      expect(find.text('Earned'), findsOneWidget);
      expect(find.text('In progress'), findsOneWidget);
      expect(find.text('On fire'), findsOneWidget);
      expect(find.text('Earned 24 Sep 2026'), findsOneWidget);
      expect(find.text('312 / 500'), findsOneWidget);
      expect(find.byType(AchievementTile), findsNWidgets(6));
    });

    testWidgets('none yet', (tester) async {
      missions.achievementList = [];
      await pumpAt(tester, Routes.achievements);
      expect(find.text('No achievements yet'), findsOneWidget);
    });

    testWidgets('a failed load offers a retry', (tester) async {
      missions.failures[FakeMissionsOp.achievements] = const NetworkFailure();
      await pumpAt(tester, Routes.achievements);
      expect(find.text('Couldn\'t load achievements'), findsOneWidget);
      expect(find.byType(ErrorState), findsOneWidget);
    });
  });
}
