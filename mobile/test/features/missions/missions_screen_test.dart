import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_app/app/router.dart';
import 'package:quiz_app/core/network/app_failure.dart';
import 'package:quiz_app/features/learn/learn_screen.dart';
import 'package:quiz_app/features/missions/data/fake_missions_repository.dart';
import 'package:quiz_app/features/missions/missions.dart';
import 'package:quiz_app/features/missions/streak_screen.dart';

import '../../support/fakes.dart';

void main() {
  late FakeMissionsRepository missions;

  setUp(() => missions = FakeMissionsRepository.seeded(today: DateTime.utc(2026, 9, 27)));

  Future<ProviderContainer> pumpMissions(WidgetTester tester) async {
    usePhoneViewport(tester, height: 1400);
    return pumpApp(tester, prefs: await testPrefs(), missions: missions, location: Routes.missions);
  }

  testWidgets('today\'s three with progress, XP, the done one and the bonus', (tester) async {
    await pumpMissions(tester);

    expect(find.text('Today\'s missions'), findsOneWidget);
    expect(find.textContaining('1 of 3 done'), findsOneWidget);
    expect(find.text('Answer 20 practice questions'), findsOneWidget);
    expect(find.text('12 / 20'), findsOneWidget);
    expect(find.text('+20 XP'), findsOneWidget);
    expect(find.text('Done'), findsOneWidget);
    expect(find.text('Finish all 3'), findsOneWidget);
    expect(find.text('+100 XP'), findsOneWidget);
    expect(find.byType(StreakChip), findsOneWidget);
    expect(find.text('4-day streak'), findsOneWidget);
    // Done missions can't be swapped.
    expect(find.bySemanticsLabel('Swap mission'), findsNWidgets(2));
  });

  testWidgets('a mission opens where it is done; the recommended one is the first left', (
    tester,
  ) async {
    await pumpMissions(tester);

    await tester.tap(find.text('Start recommended mission'));
    await tester.pumpAndSettle();
    expect(find.byType(LearnScreen), findsOneWidget);
  });

  testWidgets('one free swap, after a confirm', (tester) async {
    await pumpMissions(tester);

    await tester.tap(find.bySemanticsLabel('Swap mission').first);
    await tester.pumpAndSettle();
    expect(find.text('Swap this mission?'), findsOneWidget);
    await tester.tap(find.text('Keep it'));
    await tester.pumpAndSettle();
    expect(missions.swapCalls, isEmpty);

    await tester.tap(find.bySemanticsLabel('Swap mission').first);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(AppButton, 'Swap'));
    await tester.pumpAndSettle();

    expect(missions.swapCalls, ['m-practice']);
    expect(find.text('10 questions in any chapter'), findsOneWidget);
    expect(find.text('Answer 20 practice questions'), findsNothing);
    expect(find.text('You\'ve used today\'s free swap.'), findsOneWidget);
    expect(find.bySemanticsLabel('Swap mission'), findsNothing);
  });

  testWidgets('a refused swap says why and keeps the mission', (tester) async {
    missions.failures[FakeMissionsOp.swap] = const ConflictFailure(
      'You\'ve used today\'s free swap.',
      code: 'SWAP_USED',
    );
    await pumpMissions(tester);

    await tester.tap(find.bySemanticsLabel('Swap mission').first);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(AppButton, 'Swap'));
    await tester.pumpAndSettle();

    expect(find.text('You\'ve used today\'s free swap.'), findsOneWidget, reason: 'the toast');
    expect(find.text('Answer 20 practice questions'), findsOneWidget);
  });

  testWidgets('the streak row opens the calendar', (tester) async {
    await pumpMissions(tester);

    await tester.tap(find.text('4-day streak'));
    await tester.pumpAndSettle();
    expect(find.byType(StreakScreen), findsOneWidget);
  });

  testWidgets('a failed load offers a retry', (tester) async {
    missions.failures[FakeMissionsOp.missions] = const NetworkFailure();
    await pumpMissions(tester);

    expect(find.text('Couldn\'t load missions'), findsOneWidget);
    missions.failures.clear();
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(find.text('Answer 20 practice questions'), findsOneWidget);
  });

  group('MissionsCard and StreakChip, for Home', () {
    Future<void> pumpCard(WidgetTester tester, Widget child) => tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Padding(padding: const EdgeInsets.all(20), child: child),
        ),
      ),
    );

    testWidgets('shows the three with progress, the streak and the bonus', (tester) async {
      final tapped = <String>[];
      var streakTaps = 0;
      await pumpCard(
        tester,
        MissionsCard(
          missions: missions.day,
          onMissionTap: (mission) => tapped.add(mission.id),
          onStreakTap: () => streakTaps++,
        ),
      );

      expect(find.text('1 of 3 done'), findsOneWidget);
      expect(find.text('12/20'), findsOneWidget);
      expect(find.text('+25 XP'), findsOneWidget, reason: 'the done mission shows its XP');
      expect(find.text('All 3: +100 XP and 25 coins'), findsOneWidget);
      expect(find.text('4 days'), findsOneWidget);

      await tester.tap(find.text('Answer 20 practice questions'));
      await tester.tap(find.text('Play 1 rated battle or tournament game'));
      await tester.tap(find.text('4 days'));
      expect(tapped, ['m-practice'], reason: 'done missions don\'t open');
      expect(streakTaps, 1);
    });

    testWidgets('the chip is lit once today counts', (tester) async {
      await pumpCard(
        tester,
        const StreakChip(streak: StreakSummary(days: 5, todayDone: true), onTap: _noop),
      );
      expect(find.bySemanticsLabel(RegExp('^5-day streak, today done')), findsOneWidget);

      await pumpCard(tester, const StreakChip(streak: StreakSummary.none, onTap: _noop));
      expect(find.text('Start a streak'), findsOneWidget);
    });
  });
}

void _noop() {}
