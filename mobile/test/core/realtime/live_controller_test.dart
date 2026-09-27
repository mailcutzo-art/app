import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_app/app/app.dart';
import 'package:quiz_app/app/router.dart';
import 'package:quiz_app/core/auth/session.dart';
import 'package:quiz_app/core/config/app_config.dart';
import 'package:quiz_app/core/network/server_signals.dart';
import 'package:quiz_app/core/realtime/live_providers.dart';
import 'package:quiz_app/core/realtime/search_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/battle.dart';
import '../../support/fakes.dart';
import '../../support/match_frames.dart';
import '../../support/rt_server.dart';

Future<ProviderContainer> _pump(
  WidgetTester tester,
  TestRealtimeServer server, {
  String location = Routes.home,
  SharedPreferences? prefs,
  SessionController Function()? sessionController,
}) async {
  final container = await pumpApp(
    tester,
    prefs: prefs ?? await testPrefs(),
    realtime: server,
    location: location,
    settle: false,
    sessionController: sessionController,
  );
  await advance(tester, const Duration(milliseconds: 500));
  return container;
}

Map<String, Object?> _queued({int? joinedAt}) => frame('mm.queued', {
  'ticket_id': 't1',
  'mode': 'rated',
  'subject': 'physics',
  'chapter': null,
  'joined_at': joinedAt ?? serverNow(),
}, 'u');

/// Acks every request of [types], like the server does for requests without a natural reply.
void _ackAll(TestRealtimeServer server, Set<String> types) {
  server.onMessage = (socket, message) {
    if (types.contains(message['t'])) socket.push(frame('ack', {'ref': message['id']}, 'u'));
  };
}

void main() {
  testWidgets('holds the shell lease in the foreground, lets go in the background', (tester) async {
    usePhoneViewport(tester);
    final server = TestRealtimeServer();
    await _pump(tester, server);

    expect(server.sockets, hasLength(1));
    final hello = server.sentOfType('hello').single['d']! as Map;
    expect(hello['build'], 1);
    expect(hello['ticket'], 'test-ticket');
    expect(hello['takeover'], isFalse);
    expect(server.sentOfType('client.state').last['d'], {'state': 'foreground'});

    toBackground(tester);
    await advance(tester, const Duration(seconds: 1));
    expect(server.sentOfType('client.state').last['d'], {'state': 'background'});
    expect(server.socket.isClosed, isFalse, reason: 'a quick app switch keeps the socket');
    await advance(tester, const Duration(seconds: 30));
    expect(server.socket.isClosed, isTrue, reason: 'let go after the linger');

    toForeground(tester);
    await advance(tester, const Duration(seconds: 1));
    expect(server.sockets, hasLength(2));
    expect(server.socket.sent.map((m) => m['t']), containsAllInOrder(['hello', 'client.state']));
    expect(server.sentOfType('client.state').last['d'], {'state': 'foreground'});
  });

  testWidgets('no connection before onboarding is done', (tester) async {
    final server = TestRealtimeServer();
    await tester.pumpWidget(
      ProviderScope(
        overrides: testOverrides(
          session: SignedIn(fakeUser(onboarded: false)),
          prefs: await testPrefs(),
          realtime: server,
        ),
        child: const QuizApp(),
      ),
    );
    await advance(tester, const Duration(seconds: 1));
    expect(server.sockets, isEmpty);
  });

  testWidgets('a revoked session lands on sign-in with a message', (tester) async {
    usePhoneViewport(tester);
    FlutterSecureStorage.setMockInitialValues({});
    final server = TestRealtimeServer();
    await _pump(
      tester,
      server,
      sessionController: () => ExpiringSessionController(SignedIn(fakeUser())),
    );
    server.socket.closeFromServer(4403);
    await advance(tester, const Duration(seconds: 1));
    expect(find.text('Continue with Google'), findsOneWidget);
    expect(find.text('Your session has ended. Please sign in again.'), findsOneWidget);
  });

  testWidgets('superseded: "You\'re playing on another device" with Play here', (tester) async {
    usePhoneViewport(tester);
    final server = TestRealtimeServer();
    await _pump(tester, server);
    server.socket.closeFromServer(4409);
    await advance(tester, const Duration(seconds: 1));
    expect(find.text('You\'re playing on another device'), findsOneWidget);
    expect(server.sockets, hasLength(1), reason: 'no silent reconnect');

    await tester.tap(find.text('Play here'));
    await advance(tester, const Duration(seconds: 1));
    expect(server.sockets, hasLength(2));
    expect((server.socket.sent.first['d']! as Map)['takeover'], isTrue);
    expect(find.text('You\'re playing on another device'), findsNothing);
  });

  testWidgets('a build too old for the server shows the update screen', (tester) async {
    usePhoneViewport(tester);
    final server = TestRealtimeServer();
    await _pump(tester, server);
    server.socket.closeFromServer(4426);
    await advance(tester, const Duration(seconds: 1));
    expect(find.text('Time for an update'), findsOneWidget);
  });

  testWidgets('a search shows the pill on every screen but its own', (tester) async {
    usePhoneViewport(tester);
    final server = TestRealtimeServer();
    final container = await _pump(tester, server);
    server.push(_queued(joinedAt: serverNow() - 12000));
    await advance(tester, const Duration(milliseconds: 300));
    expect(find.text('Searching · 0:12'), findsOneWidget);
    await advance(tester, const Duration(seconds: 2));
    expect(find.text('Searching · 0:14'), findsOneWidget);

    await tester.tap(find.text('Searching · 0:14'));
    await advance(tester, const Duration(milliseconds: 500));
    expect(location(container), Routes.battleSearch);
    expect(find.textContaining('Searching ·'), findsNothing);
    expect(find.text('Finding an opponent…'), findsOneWidget);
  });

  testWidgets('mm.timeout elsewhere: "No one found yet" with Play the bot and Keep searching', (
    tester,
  ) async {
    usePhoneViewport(tester);
    final server = TestRealtimeServer();
    _ackAll(server, {'mm.respond'});
    final container = await _pump(tester, server);
    server
      ..push(_queued())
      ..push(
        frame('mm.timeout', {
          'waited_s': 45,
          'options': ['keep', 'bot', 'invite', 'cancel'],
        }, 'u'),
      );
    await advance(tester, const Duration(milliseconds: 500));
    expect(find.text('No one found yet'), findsOneWidget);
    expect(find.text('Play the bot'), findsOneWidget);

    await tester.tap(find.text('Keep searching'));
    await advance(tester, const Duration(milliseconds: 500));
    expect(server.sentOfType('mm.respond').single['d'], {'choice': 'keep'});
    expect(find.text('No one found yet'), findsNothing);
    expect(container.read(searchProvider).phase, SearchPhase.queued);
  });

  testWidgets('a stopped search says why, with the refund; the search screen explains too', (
    tester,
  ) async {
    usePhoneViewport(tester);
    final server = TestRealtimeServer();
    final container = await _pump(tester, server);
    server
      ..push(_queued())
      ..push(frame('mm.cancelled', {'reason': 'background', 'refunded': 5}, 'u'));
    await advance(tester, const Duration(milliseconds: 500));
    expect(find.text('Your search stopped while you were away'), findsOneWidget);
    expect(find.text('It doesn\'t count against you · 5 coins returned'), findsOneWidget);
    expect(find.textContaining('Searching ·'), findsNothing);

    container.read(routerProvider).go(Routes.battleSearch);
    await advance(tester, const Duration(milliseconds: 500));
    expect(find.text('Search again'), findsOneWidget);
    expect(find.text('Your search stopped while you were away'), findsWidgets);
  });

  testWidgets('a user cancel says nothing', (tester) async {
    usePhoneViewport(tester);
    final server = TestRealtimeServer();
    await _pump(tester, server);
    server
      ..push(_queued())
      ..push(frame('mm.cancelled', {'reason': 'user', 'refunded': 0}, 'u'));
    await advance(tester, const Duration(milliseconds: 500));
    expect(find.textContaining('search stopped'), findsNothing);
  });

  testWidgets('mm.requeued: "Your opponent didn\'t join" and "Searching again…"', (tester) async {
    usePhoneViewport(tester);
    final server = TestRealtimeServer();
    await _pump(tester, server);
    server
      ..push(_queued())
      ..push(frame('mm.requeued', {'reason': 'opponent_not_ready', 'waited_s': 31}, 'u'));
    await advance(tester, const Duration(milliseconds: 500));
    expect(find.text('Your opponent didn\'t join'), findsOneWidget);
    expect(find.text('Searching again…'), findsOneWidget);
    expect(find.textContaining('Searching · 0:3'), findsOneWidget, reason: 'waiting time kept');
  });

  testWidgets('after a cold start, a live game asks to rejoin and reopens from a snapshot', (
    tester,
  ) async {
    usePhoneViewport(tester);
    final match = MatchFrames();
    final server = TestRealtimeServer()
      ..active = [
        {'kind': 'match', 'ch': 'm:m1', 'state': 'q_open'},
      ];
    final container = await _pump(tester, server);
    expect(find.text('Your game is still on'), findsOneWidget);
    expect(server.sentOfType('sync').single['d'], {'ch': 'm:m1', 'last_seq': 0});

    await tester.tap(find.text('Rejoin'));
    await advance(tester, const Duration(milliseconds: 300));
    expect(location(container), Routes.battleMatch('m1'));
    final shownAt = serverNow() - 3000;
    match.seq = 9;
    server.push(
      match.snapshot(
        phase: 'q_open',
        q: 3,
        scores: {'u1': 240, 'riya': 130},
        question: match.showData(3, shownAt: shownAt),
      ),
    );
    await advance(tester, const Duration(milliseconds: 300));
    expect(find.text('Question 3: how far does a car go?'), findsOneWidget);
    expect(find.text('Your game is still on'), findsNothing);
  });

  testWidgets('a search the server let go while away is explained after reconnecting', (
    tester,
  ) async {
    usePhoneViewport(tester);
    final server = TestRealtimeServer();
    final container = await _pump(tester, server);
    server.push(_queued());
    await advance(tester, const Duration(milliseconds: 300));
    expect(container.read(searchProvider).isSearching, isTrue);

    server.socket.closeFromServer();
    await advance(tester, const Duration(seconds: 3));
    expect(server.sockets, hasLength(2), reason: 'reconnected');
    expect(find.text('Your search stopped while you were away'), findsOneWidget);
    expect(container.read(searchProvider).lastEnd?.reason, 'away');
  });

  testWidgets('a game that ended while the app was closed offers its result', (tester) async {
    usePhoneViewport(tester);
    final server = TestRealtimeServer();
    final container = await _pump(
      tester,
      server,
      prefs: await testPrefs({'battle.active_match.u1': 'm5'}),
    );
    expect(find.text('Your last game ended'), findsOneWidget);
    await tester.tap(find.text('See result'));
    await advance(tester, const Duration(milliseconds: 300));
    expect(location(container), Routes.battleMatch('m5'));
  });

  testWidgets('maintenance waits until the live game and its result are done', (tester) async {
    usePhoneViewport(tester, height: 2400);
    final match = MatchFrames();
    final server = TestRealtimeServer();
    final container = await _pump(tester, server, location: Routes.battleSearch);
    server
      ..push(match.found())
      ..push(
        match.snapshot(
          phase: 'q_open',
          q: 1,
          question: match.showData(1, shownAt: serverNow()),
        ),
      );
    await advance(tester, const Duration(milliseconds: 300));
    expect(container.read(liveGameProvider), isTrue);

    container.read(serverSignalsProvider.notifier).maintenance();
    await advance(tester, const Duration(milliseconds: 300));
    expect(location(container), Routes.battleMatch('m1'), reason: 'never interrupts the game');
    expect(find.text('Question 1: how far does a car go?'), findsOneWidget);

    server.push(match.end(result: 'win', myTotals: (140, 1)));
    await advance(tester, const Duration(milliseconds: 500));
    expect(find.text('Victory!'), findsOneWidget, reason: 'the result still shows');

    await tester.tap(find.text('Done'));
    await advance(tester, const Duration(milliseconds: 500));
    expect(container.read(liveGameProvider), isFalse);
    expect(location(container), Routes.maintenance);
  });

  testWidgets('a connection too old for the server ends the live game at once', (tester) async {
    usePhoneViewport(tester);
    final match = MatchFrames();
    final server = TestRealtimeServer();
    final container = await _pump(tester, server, location: Routes.battleSearch);
    server
      ..push(match.found())
      ..push(match.snapshot(phase: 'ready_wait', endsAt: serverNow() + 10000));
    await advance(tester, const Duration(milliseconds: 300));
    expect(container.read(liveGameProvider), isTrue);

    server.socket.closeFromServer(4426);
    await advance(tester, const Duration(milliseconds: 500));
    expect(container.read(liveGameProvider), isFalse);
    expect(find.text('Time for an update'), findsOneWidget);
  });

  testWidgets('signing out takes the live pill and alerts away', (tester) async {
    usePhoneViewport(tester);
    final server = TestRealtimeServer();
    final container = await _pump(tester, server);
    server.push(_queued());
    await advance(tester, const Duration(milliseconds: 300));
    expect(find.textContaining('Searching ·'), findsOneWidget);

    await container.read(sessionProvider.notifier).signOut();
    await advance(tester, const Duration(seconds: 1));
    expect(find.text('Continue with Google'), findsOneWidget);
    expect(find.textContaining('Searching ·'), findsNothing);
    expect(server.socket.isClosed, isTrue);
  });
}
