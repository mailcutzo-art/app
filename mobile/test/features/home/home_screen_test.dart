import 'package:design_system/design_system.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_app/core/network/api_client.dart';
import 'package:quiz_app/core/network/app_failure.dart';
import 'package:quiz_app/features/home/data/home_models.dart';
import 'package:quiz_app/features/home/data/home_repository.dart';
import 'package:quiz_app/features/leaderboards/leaderboards.dart';
import 'package:quiz_app/features/missions/missions.dart';

import '../../support/fakes.dart';

Map<String, Object?> _ok(Object? data) => {'status': 'ok', 'data': data};

Map<String, Object?> _homeJson() => {
  'hero': _ok({
    'rating': {'display': '1523?', 'value': 1523, 'provisional': true},
    'rank': {'board': 'rating:overall', 'position': null, 'games_to_rank': 7},
    'coins': 245,
    'level': {'level': 4, 'into_level': 120, 'for_next': 250},
  }),
  'live': _ok(null),
  'continue': _ok({
    'session_id': 's1',
    'title': 'Physics · Kinematics',
    'answered': 3,
    'count': 10,
  }),
  'tip': {
    'status': 'error',
    'error': {'code': 'INTERNAL', 'message': 'Something went wrong.'},
  },
  'missions': _ok({
    'day': '2026-09-27',
    'items': [
      {
        'id': 'm1',
        'title': 'Answer 20 practice questions',
        'progress': 12,
        'target': 20,
        'xp': 20,
        'done': false,
        'action': {'route': '/learn'},
      },
    ],
    'bonus': {'xp': 100, 'coins': 25, 'done': false},
    'streak': {'days': 4, 'today_done': false, 'freezes': 1},
  }),
  'leaders': _ok({
    'board': 'weekly_xp',
    'top': [
      {
        'position': 1,
        'user': {'id': 'p1', 'display_name': 'Meera', 'handle': 'meera'},
        'value': 2200,
        'value_display': '2,200 XP',
      },
    ],
    'me': null,
  }),
  'tournament': _ok(null),
  'welcome': {'coins': 100},
  'maintenance_banner': {'message': 'Down for 10 minutes at 2 AM'},
};

void main() {
  group('models', () {
    test('each section reads on its own', () {
      final feed = HomeFeed.fromJson(_homeJson());
      final hero = feed.hero.data!;
      expect(hero.rating.display, '1523?');
      expect(hero.rank.gamesToRank, 7);
      expect(hero.coins, 245);
      expect(hero.level!.forNext, 250);
      expect(feed.live, isA<SectionOk<HomeLive?>>());
      expect(feed.continuePractice.data!.sessionId, 's1');
      expect((feed.tip as SectionFailed).code, 'INTERNAL');
      expect(feed.missions.data!.streak.days, 4);
      expect(feed.leaders.data!.top.single.user.displayName, 'Meera');
      expect(feed.tournament.data, isNull);
      expect(feed.welcomeCoins, 100);
      expect(feed.maintenanceBanner, 'Down for 10 minutes at 2 AM');
    });

    test('an unreadable or missing section fails alone', () {
      final json = _homeJson()
        ..['hero'] = _ok({'coins': 'lots'})
        ..remove('leaders')
        ..['welcome'] = null;
      final feed = HomeFeed.fromJson(json);
      expect(feed.hero, isA<SectionFailed<HomeHero>>());
      expect(feed.leaders, isA<SectionFailed<HomeLeaders>>());
      expect(feed.missions.data, isNotNull);
      expect(feed.welcomeCoins, isNull);
    });
  });

  test('ApiHomeRepository reads GET /v1/home', () async {
    final adapter = FakeAdapter((_) => jsonBody(_homeJson()));
    final repo = ApiHomeRepository(
      ApiClient(Dio(BaseOptions(baseUrl: 'http://api.test'))..httpClientAdapter = adapter),
    );
    expect((await repo.home()).hero.data!.coins, 245);
    expect(adapter.requests.single.path, '/v1/home');
  });

  group('the Home screen', () {
    testWidgets('shows skeletons, then every section', (tester) async {
      usePhoneViewport(tester, height: 2400);
      final home = FakeHomeRepository.seeded(latency: const Duration(milliseconds: 300));
      await pumpApp(tester, prefs: await testPrefs(), home: home, settle: false);
      expect(find.byType(Shimmer), findsWidgets);

      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(find.text('Hi, Aarav!'), findsOneWidget);
      expect(find.text('1523?'), findsOneWidget);
      expect(find.text('Play 7 more rated games to get ranked'), findsOneWidget);
      expect(find.text('245'), findsOneWidget);
      expect(find.byType(StreakChip), findsOneWidget);
      expect(find.text('Play 1v1'), findsOneWidget);
      expect(find.text('Play with Friend'), findsOneWidget);
      expect(find.text('Group Battle'), findsOneWidget);
      expect(find.text('Physics · Motion in a Straight Line'), findsOneWidget);
      expect(find.byType(MissionsCard), findsOneWidget);
      expect(find.text('Coach tip'), findsOneWidget);
      expect(find.byType(BoardRowTile), findsNWidgets(4), reason: 'the top 3 and my row');
      expect(find.text('Physics Sunday Cup'), findsOneWidget);
      expect(find.byType(ErrorState), findsNothing);
    });

    testWidgets('a failed section shows its own retry; the rest still show', (tester) async {
      usePhoneViewport(tester, height: 2400);
      final home = FakeHomeRepository.seeded()..failedSections.add(FakeHomeSection.missions);
      await pumpApp(tester, prefs: await testPrefs(), home: home);
      expect(find.text('Couldn\'t load today\'s missions'), findsOneWidget);
      expect(find.byType(MissionsCard), findsNothing);
      expect(find.text('1523?'), findsOneWidget);
      expect(find.byType(BoardRowTile), findsNWidgets(4));

      home.failedSections.clear();
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.byType(MissionsCard), findsOneWidget);
      expect(find.byType(ErrorState), findsNothing);
    });

    testWidgets('when Home fails as a whole, the hero offers a retry', (tester) async {
      usePhoneViewport(tester);
      final home = FakeHomeRepository.seeded()..failure = const NetworkFailure();
      await pumpApp(tester, prefs: await testPrefs(), home: home);
      expect(find.text('Couldn\'t load Home'), findsOneWidget);
      expect(find.text('Hi, Aarav!'), findsOneWidget);

      home.failure = null;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('1523?'), findsOneWidget);
    });

    testWidgets('the welcome bonus is celebrated once', (tester) async {
      usePhoneViewport(tester);
      final home = FakeHomeRepository.seeded(welcomeCoins: 100);
      await pumpApp(tester, prefs: await testPrefs(), home: home);
      expect(find.text('Welcome to Quiz Arena!'), findsOneWidget);
      expect(find.text('+100 coins'), findsOneWidget);

      await tester.tap(find.text('Let\'s play'));
      await tester.pumpAndSettle();
      expect(find.text('Welcome to Quiz Arena!'), findsNothing);

      // Pull to refresh: the server doesn't send it again.
      await tester.fling(find.text('Hi, Aarav!'), const Offset(0, 400), 1200);
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(home.calls, 2);
      expect(find.text('Welcome to Quiz Arena!'), findsNothing);
    });
  });
}
