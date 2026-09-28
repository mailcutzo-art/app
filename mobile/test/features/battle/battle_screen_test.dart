import 'package:clock/clock.dart';
import 'package:design_system/design_system.dart' hide Presence;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_app/app/app.dart';
import 'package:quiz_app/app/router.dart';
import 'package:quiz_app/core/auth/session.dart';
import 'package:quiz_app/core/auth/user.dart';
import 'package:quiz_app/core/network/app_failure.dart';
import 'package:quiz_app/features/battle/battle_screen.dart';
import 'package:quiz_app/features/battle/battle_selection.dart';
import 'package:quiz_app/features/battle/data/battle_models.dart';
import 'package:quiz_app/features/battle/data/fake_battle_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/battle.dart';
import '../../support/fakes.dart';
import '../../support/match_frames.dart';
import '../../support/rt_server.dart';

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  FakeBattleRepository? battle,
  TestRealtimeServer? server,
  SharedPreferences? prefs,
  Stream<bool>? online,
  String location = Routes.battle,
}) async {
  final container = await pumpApp(
    tester,
    prefs: prefs ?? await testPrefs(),
    battle: battle ?? FakeBattleRepository(),
    realtime: server,
    online: online,
    location: location,
    settle: false,
  );
  await advance(tester, const Duration(milliseconds: 500));
  return container;
}

bool _chipSelected(WidgetTester tester, String label) =>
    tester.widget<AppChip>(find.widgetWithText(AppChip, label)).selected;

AppButton _button(WidgetTester tester, String label) =>
    tester.widget<AppButton>(find.widgetWithText(AppButton, label));

void main() {
  testWidgets('shows a skeleton, then the quick battle card for the user\'s exam', (tester) async {
    usePhoneViewport(tester);
    reduceMotion(tester);
    final battle = FakeBattleRepository(latency: const Duration(seconds: 1));
    await _pump(tester, battle: battle);
    expect(find.byType(Shimmer), findsOneWidget);
    expect(find.text('Quick battle'), findsNothing);

    await advance(tester, const Duration(seconds: 1));
    expect(find.text('Quick battle'), findsOneWidget);
    expect(find.text('Pick a chapter, find an opponent, play live.'), findsOneWidget);
    for (final subject in ['Physics', 'Chemistry', 'Biology']) {
      expect(find.widgetWithText(AppChip, subject), findsOneWidget);
    }
    expect(find.widgetWithText(AppChip, 'Maths'), findsNothing);
    expect(battle.calls, [Goal.neet]);
    expect(find.text('1502?'), findsOneWidget);
    expect(find.text('Physics rating'), findsOneWidget);
    expect(find.text('Free · changes your Physics rating'), findsOneWidget);
    expect(find.widgetWithText(AppButton, 'Find opponent'), findsOneWidget);
    expect(find.widgetWithText(AppButton, 'Practice vs Bot'), findsOneWidget);
  });

  testWidgets('JEE students battle Maths, not Biology', (tester) async {
    usePhoneViewport(tester);
    reduceMotion(tester);
    const jee = Me(
      id: 'u1',
      displayName: 'Aarav Sharma',
      handle: 'aarav',
      avatar: Avatar(tone: 'lime', symbol: 'rocket'),
      goal: Goal.jee,
      onboardingCompleted: true,
    );
    final battle = FakeBattleRepository();
    await tester.pumpWidget(
      ProviderScope(
        overrides: testOverrides(
          session: const SignedIn(jee),
          prefs: await testPrefs(),
          battle: battle,
        ),
        child: const QuizApp(),
      ),
    );
    await tester.pump();
    ProviderScope.containerOf(tester.element(find.byType(QuizApp)))
        .read(routerProvider)
        .go(Routes.battle);
    await advance(tester, const Duration(milliseconds: 500));
    expect(find.widgetWithText(AppChip, 'Maths'), findsOneWidget);
    expect(find.widgetWithText(AppChip, 'Biology'), findsNothing);
    expect(battle.calls, [Goal.jee]);
  });

  testWidgets('a failed load offers a retry, and the rest of the tab still shows', (tester) async {
    usePhoneViewport(tester);
    reduceMotion(tester);
    final battle = FakeBattleRepository()..failure = const NetworkFailure();
    await _pump(tester, battle: battle);
    expect(find.text('Couldn\'t load battles'), findsOneWidget);
    expect(find.text('More ways to play'), findsOneWidget);

    battle.failure = null;
    await tester.tap(find.widgetWithText(AppButton, 'Retry'));
    await advance(tester, const Duration(milliseconds: 500));
    expect(find.text('Quick battle'), findsOneWidget);
  });

  testWidgets('pull to refresh loads it again', (tester) async {
    usePhoneViewport(tester);
    reduceMotion(tester);
    final battle = FakeBattleRepository();
    await _pump(tester, battle: battle);
    await tester.fling(find.text('Quick battle'), const Offset(0, 400), 1200);
    await advance(tester, const Duration(seconds: 2));
    expect(battle.calls, hasLength(2));
  });

  testWidgets('Casual shows the fee and the balance', (tester) async {
    usePhoneViewport(tester);
    reduceMotion(tester);
    await _pump(tester);
    await tester.tap(find.text('Casual'));
    await advance(tester, const Duration(milliseconds: 300));
    expect(find.text('5 coins to enter · winner takes 10'), findsOneWidget);
    expect(find.text('245'), findsOneWidget);
  });

  testWidgets('without 5 coins Casual is disabled, with a hint', (tester) async {
    usePhoneViewport(tester);
    reduceMotion(tester);
    await _pump(tester, battle: FakeBattleRepository(setup: (g) => sampleBattleSetup(g, coins: 3)));
    expect(find.text('Earn coins from missions'), findsOneWidget);
    await tester.tap(find.text('Casual'), warnIfMissed: false);
    await advance(tester, const Duration(milliseconds: 300));
    expect(find.text('Free · changes your Physics rating'), findsOneWidget, reason: 'still Rated');
  });

  testWidgets('a subject without games shows "—" and New', (tester) async {
    usePhoneViewport(tester);
    reduceMotion(tester);
    await _pump(tester);
    await tester.tap(find.widgetWithText(AppChip, 'Chemistry'));
    await advance(tester, const Duration(milliseconds: 300));
    expect(_chipSelected(tester, 'Chemistry'), isTrue);
    expect(find.text('—'), findsOneWidget);
    expect(find.text('New · Chemistry'), findsOneWidget);
    expect(find.text('2 players searching · usually 25 s'), findsOneWidget);
    expect(find.text('Chemistry this week: Kabir leads'), findsOneWidget);
  });

  testWidgets('the choice is remembered on the device', (tester) async {
    usePhoneViewport(tester);
    reduceMotion(tester);
    final prefs = await testPrefs();
    await _pump(tester, prefs: prefs);
    await tester.tap(find.widgetWithText(AppChip, 'Biology'));
    await advance(tester, const Duration(milliseconds: 300));
    expect(prefs.getString(BattleSelectionController.key('u1')), contains('biology'));

    // A new start, and the server doesn't remember: the device's copy is used.
    await tester.pumpWidget(const SizedBox());
    await _pump(tester, prefs: prefs);
    expect(_chipSelected(tester, 'Biology'), isTrue);
  });

  testWidgets('the server\'s last choice is preselected', (tester) async {
    usePhoneViewport(tester);
    reduceMotion(tester);
    await _pump(
      tester,
      battle: FakeBattleRepository(
        setup: (g) => sampleBattleSetup(
          g,
          last: const BattleSelection(subject: 'physics', chapter: 'laws-of-motion'),
        ),
      ),
    );
    expect(find.text('Laws of Motion'), findsOneWidget);
  });

  testWidgets('a coach tip opens the tab on its subject', (tester) async {
    usePhoneViewport(tester);
    reduceMotion(tester);
    await _pump(tester, location: Routes.battleWith(subject: 'chemistry'));
    await advance(tester, const Duration(milliseconds: 300));
    expect(_chipSelected(tester, 'Chemistry'), isTrue);
  });

  testWidgets('a cooldown counts down on a disabled button', (tester) async {
    usePhoneViewport(tester);
    reduceMotion(tester);
    final until = clock.now().add(const Duration(minutes: 4, seconds: 32));
    await _pump(
      tester,
      battle: FakeBattleRepository(setup: (g) => sampleBattleSetup(g, cooldownUntil: until)),
    );
    expect(find.text('Too many cancelled matches'), findsOneWidget);
    expect(find.text('Try again in 4:31'), findsOneWidget);
    expect(_button(tester, 'Try again in 4:31').onPressed, isNull);
    await advance(tester, const Duration(seconds: 2));
    expect(find.text('Try again in 4:29'), findsOneWidget);
  });

  testWidgets('already busy: Go there instead of Find opponent', (tester) async {
    usePhoneViewport(tester);
    reduceMotion(tester);
    final container = await _pump(
      tester,
      battle: FakeBattleRepository(
        setup: (g) => sampleBattleSetup(
          g,
          active: const BattleActive(kind: 'match', id: 'm7', title: 'Quick battle vs Riya'),
        ),
      ),
    );
    expect(find.text('You\'re in a match · Quick battle vs Riya'), findsOneWidget);
    expect(find.widgetWithText(AppButton, 'Find opponent'), findsNothing);
    await tester.tap(find.text('Go there'));
    await advance(tester, const Duration(milliseconds: 300));
    expect(location(container), Routes.battleMatch('m7'));
  });

  testWidgets('offline, live play is disabled with "You\'re offline"', (tester) async {
    usePhoneViewport(tester);
    reduceMotion(tester);
    await _pump(tester, online: Stream.value(false));
    expect(find.text('You\'re offline · battles need a connection'), findsOneWidget);
    expect(find.text('You\'re offline. Connect to play live.'), findsOneWidget);
    expect(_button(tester, 'Find opponent').onPressed, isNull);
    expect(_button(tester, 'Practice vs Bot').onPressed, isNull);
  });

  testWidgets('a friend\'s room link opens joining that room', (tester) async {
    usePhoneViewport(tester);
    reduceMotion(tester);
    final container = await _pump(tester, location: '/j/K7M2QX');
    expect(location(container), Routes.joinRoom('K7M2QX'));
    expect(find.text('Join a room'), findsOneWidget);
  });

  testWidgets('Play a friend, Group battle and Join with code open their screens', (tester) async {
    usePhoneViewport(tester, height: 1400);
    reduceMotion(tester);
    final container = await _pump(tester);
    expect(find.text('Soon'), findsNothing);

    await tester.tap(find.text('Play a friend'));
    await advance(tester, const Duration(milliseconds: 600));
    expect(location(container), Routes.roomSetup('friend'));
    container.read(routerProvider).go(Routes.battle);
    await advance(tester, const Duration(milliseconds: 600));

    await tester.tap(find.text('Group battle'));
    await advance(tester, const Duration(milliseconds: 600));
    expect(location(container), Routes.roomSetup('group'));
    container.read(routerProvider).go(Routes.battle);
    await advance(tester, const Duration(milliseconds: 600));

    await tester.tap(find.text('Join with code'));
    await advance(tester, const Duration(milliseconds: 600));
    expect(location(container), Routes.joinRoom());
  });

  testWidgets('a refused join says why on the card', (tester) async {
    usePhoneViewport(tester);
    reduceMotion(tester);
    final server = TestRealtimeServer()
      ..onMessage = (socket, message) {
        if (message['t'] != 'mm.join') return;
        socket.push(
          frame('error', {
            'ref': message['id'],
            'code': 'INSUFFICIENT_COINS',
            'message': 'Not enough coins.',
          }, 'u'),
        );
      };
    await _pump(tester, server: server);
    await tester.tap(find.text('Find opponent'));
    await advance(tester, const Duration(milliseconds: 500));
    expect(
      find.text('You need 5 coins for a casual battle. Earn coins from missions.'),
      findsOneWidget,
    );
  });

  testWidgets('Practice vs Bot goes straight into the game', (tester) async {
    usePhoneViewport(tester);
    reduceMotion(tester);
    final match = MatchFrames(them: 'bot', kind: 'bot');
    final server = TestRealtimeServer()
      ..onMessage = (socket, message) {
        if (message['t'] != 'mm.join') return;
        socket
          ..push(match.found(mode: 'bot', bot: true))
          ..push(match.snapshot(phase: 'ready_wait'));
      };
    final container = await _pump(tester, server: server);
    await tester.tap(find.text('Practice vs Bot'));
    await advance(tester, const Duration(milliseconds: 500));
    expect(server.sentOfType('mm.join').single['d'], containsPair('mode', 'bot'));
    expect(location(container), Routes.battleMatch('m1'));
    expect(
      find.text('Match found!'),
      findsNothing,
      reason: 'no takeover for a game just asked for',
    );
    expect(find.text('PRACTICE BOT'), findsOneWidget);
  });

  testWidgets('while searching, the button leads back to the search', (tester) async {
    usePhoneViewport(tester);
    reduceMotion(tester);
    final server = TestRealtimeServer();
    final container = await _pump(tester, server: server);
    server.push(
      frame('mm.queued', {
        'ticket_id': 't1',
        'mode': 'rated',
        'subject': 'physics',
        'joined_at': serverNow(),
      }, 'u'),
    );
    await advance(tester, const Duration(milliseconds: 300));
    await tester.tap(find.text('Back to your search'));
    await advance(tester, const Duration(milliseconds: 300));
    expect(location(container), Routes.battleSearch);
  });

  test('the online and leader lines', () {
    expect(
      onlineLine(const OnlineStat(searching: 3, p50WaitS: 20)),
      '3 players searching · usually 20 s',
    );
    expect(onlineLine(const OnlineStat(searching: 1)), '1 player searching');
    expect(onlineLine(null), 'Opponents are matched by rating');
    expect(
      leaderLine('Physics', const SubjectLeaders(leaderName: 'Riya', myPosition: 12)),
      'Physics this week: Riya leads · you\'re #12',
    );
    expect(
      leaderLine('Physics', const SubjectLeaders(leaderIsMe: true)),
      'Physics this week: you lead!',
    );
    expect(
      leaderLine('Physics', const SubjectLeaders(myPosition: 3)),
      'Physics this week: you\'re #3',
    );
    expect(leaderLine('Physics', null), isNull);
    expect(activeRoute(const BattleActive(kind: 'queue')), Routes.battleSearch);
    expect(activeRoute(const BattleActive(kind: 'tournament', id: 't1')), '/arena?t=t1');
    expect(
      activeRoute(const BattleActive(kind: 'room', route: '/battle?room=r1')),
      '/battle?room=r1',
    );
  });
}
