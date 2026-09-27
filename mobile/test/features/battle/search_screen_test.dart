import 'package:design_system/design_system.dart' hide Presence;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_app/app/router.dart';
import 'package:quiz_app/core/realtime/live_providers.dart';
import 'package:quiz_app/core/realtime/search_state.dart';
import 'package:quiz_app/features/battle/data/battle_models.dart';
import 'package:quiz_app/features/battle/data/fake_battle_repository.dart';
import 'package:quiz_app/features/battle/search_screen.dart';

import '../../support/battle.dart';
import '../../support/fakes.dart';
import '../../support/match_frames.dart';
import '../../support/rt_server.dart';

/// A server that queues every `mm.join` and acks `mm.cancel` and `mm.respond`, like the real one.
/// [also] sees every message after that.
TestRealtimeServer _server({void Function(TestSocket socket, Map<String, Object?> message)? also}) {
  final server = TestRealtimeServer();
  server.onMessage = (socket, message) {
    final data = (message['d'] as Map?)?.cast<String, Object?>() ?? const {};
    switch (message['t']) {
      case 'mm.join' when data['mode'] != 'bot':
        socket.push(
          frame('mm.queued', {
            'ticket_id': 't${server.sentOfType('mm.join').length}',
            'mode': data['mode'],
            'subject': data['subject'],
            'chapter': data['chapter'],
            'joined_at': serverNow(),
          }, 'u'),
        );
      case 'mm.cancel':
        socket
          ..push(frame('ack', {'ref': message['id']}, 'u'))
          ..push(frame('mm.cancelled', {'reason': 'user', 'refunded': 0}, 'u'));
      case 'mm.respond':
        socket.push(frame('ack', {'ref': message['id']}, 'u'));
        if (data['choice'] == 'cancel') {
          socket.push(frame('mm.cancelled', {'reason': 'user', 'refunded': 0}, 'u'));
        }
    }
    also?.call(socket, message);
  };
  return server;
}

/// Opens the Battle tab on Physics · Motion in a Straight Line and starts a search in [mode].
Future<ProviderContainer> _search(
  WidgetTester tester,
  TestRealtimeServer server, {
  String mode = 'Rated',
}) async {
  final container = await pumpApp(
    tester,
    prefs: await testPrefs(),
    realtime: server,
    battle: FakeBattleRepository(
      setup: (goal) => sampleBattleSetup(
        goal,
        last: const BattleSelection(subject: 'physics', chapter: 'kinematics'),
      ),
    ),
    location: Routes.battle,
    settle: false,
  );
  await advance(tester, const Duration(milliseconds: 500));
  if (mode != 'Rated') {
    await tester.tap(find.text(mode));
    await advance(tester, const Duration(milliseconds: 300));
  }
  await tester.tap(find.text('Find opponent'));
  await advance(tester, const Duration(milliseconds: 500));
  return container;
}

Map<String, Object?> _timeout({int waited = 20, List<String>? options}) => frame('mm.timeout', {
  'waited_s': waited,
  'options': options ?? ['keep', 'bot', 'invite', 'cancel'],
}, 'u');

AppButton _button(WidgetTester tester, String label) =>
    tester.widget<AppButton>(find.widgetWithText(AppButton, label));

void main() {
  testWidgets('shows who it looks for, how long it has been, and how busy it is', (tester) async {
    usePhoneViewport(tester);
    reduceMotion(tester);
    final server = _server();
    final container = await _search(tester, server);
    expect(location(container), Routes.battleSearch);
    expect(server.sentOfType('mm.join').single['d'], {
      'mode': 'rated',
      'subject': 'physics',
      'chapter': 'kinematics',
      'idem': isA<String>(),
    });

    expect(find.byType(SearchingPulse), findsOneWidget);
    expect(find.text('Finding an opponent…'), findsOneWidget);
    expect(find.text('0:00'), findsOneWidget);
    for (final badge in ['RATED', 'PHYSICS', 'MOTION IN A STRAIGHT LINE']) {
      expect(find.text(badge), findsOneWidget);
    }
    expect(find.text('Looking for a Physics player in Motion in a Straight Line…'), findsOneWidget);
    expect(find.text('3 players searching · usually 20 s'), findsOneWidget);
    expect(find.text('Keep browsing'), findsOneWidget);
    expect(find.textContaining('Searching ·'), findsNothing, reason: 'no pill on its own screen');

    await advance(tester, const Duration(seconds: 5));
    expect(find.text('0:05'), findsOneWidget);

    server.push(
      frame('mm.status', {'waited_s': 15, 'widened': true, 'online': 4, 'p50_wait_s': 18}, 'u'),
    );
    await advance(tester, const Duration(milliseconds: 300));
    expect(find.text('Widened to all of Physics'), findsOneWidget);
    expect(find.text('4 players searching · usually 18 s'), findsOneWidget);
    expect(find.text('0:05'), findsOneWidget, reason: 'the clock keeps its start');
  });

  testWidgets('a casual search says so', (tester) async {
    usePhoneViewport(tester);
    reduceMotion(tester);
    final server = _server();
    await _search(tester, server, mode: 'Casual');
    expect((server.sentOfType('mm.join').single['d']! as Map)['mode'], 'casual');
    expect(find.text('CASUAL'), findsOneWidget);
  });

  testWidgets('Cancel stops the search and goes back to the Battle tab', (tester) async {
    usePhoneViewport(tester);
    reduceMotion(tester);
    final server = _server();
    final container = await _search(tester, server);
    await tester.tap(find.widgetWithText(AppButton, 'Cancel'));
    await advance(tester, const Duration(milliseconds: 500));
    expect(server.sentOfType('mm.cancel'), hasLength(1));
    expect(location(container), Routes.battle);
    expect(container.read(searchProvider).isSearching, isFalse);
    expect(find.textContaining('Searching ·'), findsNothing);
    expect(find.textContaining('search stopped'), findsNothing, reason: 'nothing to explain');
  });

  testWidgets('a match made while cancelling opens the match instead', (tester) async {
    usePhoneViewport(tester);
    reduceMotion(tester);
    final server = TestRealtimeServer();
    final container = await _search(
      tester,
      server
        ..onMessage = (socket, message) {
          final data = (message['d'] as Map?)?.cast<String, Object?>() ?? const {};
          switch (message['t']) {
            case 'mm.join':
              socket.push(
                frame('mm.queued', {
                  'ticket_id': 't1',
                  'mode': data['mode'],
                  'subject': data['subject'],
                  'chapter': data['chapter'],
                  'joined_at': serverNow(),
                }, 'u'),
              );
            case 'mm.cancel':
              socket.push(
                frame('error', {
                  'ref': message['id'],
                  'code': 'ALREADY_MATCHED',
                  'message': 'You already have a match.',
                  'details': {'match_id': 'm9'},
                }, 'u'),
              );
          }
        },
    );
    await tester.tap(find.widgetWithText(AppButton, 'Cancel'));
    await advance(tester, const Duration(milliseconds: 500));
    expect(location(container), Routes.battleMatch('m9'));
    expect(server.sentOfType('sync').last['d'], {'ch': 'm:m9', 'last_seq': 0});
  });

  testWidgets('no one found yet: the options, and Keep searching', (tester) async {
    usePhoneViewport(tester);
    reduceMotion(tester);
    final server = _server();
    final container = await _search(tester, server);
    server.push(_timeout());
    await advance(tester, const Duration(milliseconds: 600));

    expect(find.text('No one found yet'), findsOneWidget);
    expect(find.text('You\'ve waited 0:20. What would you like to do?'), findsOneWidget);
    expect(find.text('Play a Practice Bot'), findsOneWidget);
    expect(find.text('Unrated, no coins · starts right away'), findsOneWidget);
    expect(_button(tester, 'Invite a friend · Coming soon').onPressed, isNull);
    expect(find.text('Cancel search'), findsOneWidget);
    expect(find.text('Play the bot'), findsNothing, reason: 'no banner on the search screen');

    await tester.tap(find.text('Keep searching'));
    await advance(tester, const Duration(milliseconds: 600));
    expect(server.sentOfType('mm.respond').single['d'], {'choice': 'keep'});
    expect(find.text('No one found yet'), findsNothing);
    expect(find.text('Finding an opponent…'), findsOneWidget);
    expect(container.read(searchProvider).phase, SearchPhase.queued);
  });

  testWidgets('closing the options keeps searching', (tester) async {
    usePhoneViewport(tester);
    reduceMotion(tester);
    final server = _server();
    await _search(tester, server);
    server.push(_timeout());
    await advance(tester, const Duration(milliseconds: 600));
    await tester.tapAt(const Offset(200, 40));
    await advance(tester, const Duration(milliseconds: 600));
    expect(find.text('No one found yet'), findsNothing);
    expect(server.sentOfType('mm.respond').single['d'], {'choice': 'keep'});
  });

  testWidgets('Play a Practice Bot from the options starts the bot game', (tester) async {
    usePhoneViewport(tester);
    reduceMotion(tester);
    final match = MatchFrames(them: 'bot', kind: 'bot');
    final server = _server(
      also: (socket, message) {
        if (message['t'] == 'mm.respond') {
          socket
            ..push(match.found(mode: 'bot', bot: true))
            ..push(match.snapshot(phase: 'ready_wait'));
        }
      },
    );
    final container = await _search(tester, server);
    server.push(_timeout());
    await advance(tester, const Duration(milliseconds: 600));
    await tester.tap(find.text('Play a Practice Bot'));
    await advance(tester, const Duration(milliseconds: 600));
    expect(server.sentOfType('mm.respond').single['d'], {'choice': 'bot'});
    expect(location(container), Routes.battleMatch('m1'));
    expect(find.text('PRACTICE BOT'), findsOneWidget);
    expect(find.text('Match found!'), findsNothing);
  });

  testWidgets('in a casual search, the bot option says the coins come back', (tester) async {
    usePhoneViewport(tester);
    reduceMotion(tester);
    final server = _server();
    await _search(tester, server, mode: 'Casual');
    server.push(_timeout());
    await advance(tester, const Duration(milliseconds: 600));
    expect(find.text('Unrated, no coins · your 5 coins come back'), findsOneWidget);
  });

  testWidgets('only the options the server offers are shown', (tester) async {
    usePhoneViewport(tester);
    reduceMotion(tester);
    final server = _server();
    await _search(tester, server);
    server.push(_timeout(options: ['keep', 'cancel']));
    await advance(tester, const Duration(milliseconds: 600));
    expect(find.text('Keep searching'), findsOneWidget);
    expect(find.text('Play a Practice Bot'), findsNothing);
    expect(find.text('Invite a friend · Coming soon'), findsNothing);
  });

  testWidgets('Cancel search from the options stops and leaves', (tester) async {
    usePhoneViewport(tester);
    reduceMotion(tester);
    final server = _server();
    final container = await _search(tester, server);
    server.push(_timeout());
    await advance(tester, const Duration(milliseconds: 600));
    await tester.tap(find.text('Cancel search'));
    await advance(tester, const Duration(milliseconds: 600));
    expect(server.sentOfType('mm.respond').single['d'], {'choice': 'cancel'});
    expect(location(container), Routes.battle);
    expect(container.read(searchProvider).isSearching, isFalse);
  });

  testWidgets('a match found while the options are open closes them', (tester) async {
    usePhoneViewport(tester);
    reduceMotion(tester);
    final match = MatchFrames();
    final server = _server();
    final container = await _search(tester, server);
    server.push(_timeout());
    await advance(tester, const Duration(milliseconds: 600));
    server
      ..push(match.found())
      ..push(match.snapshot(phase: 'ready_wait', endsAt: serverNow() + 10000));
    await advance(tester, const Duration(milliseconds: 600));
    expect(find.text('No one found yet'), findsNothing);
    expect(location(container), Routes.battleMatch('m1'));
    expect(find.text('Riya'), findsWidgets);
  });

  testWidgets('a search the server stopped says why, with the refund, and can start again', (
    tester,
  ) async {
    usePhoneViewport(tester);
    reduceMotion(tester);
    final server = _server();
    await _search(tester, server, mode: 'Casual');
    server.push(frame('mm.cancelled', {'reason': 'timeout', 'refunded': 5}, 'u'));
    await advance(tester, const Duration(milliseconds: 600));
    expect(find.text('No one was available'), findsOneWidget);
    expect(find.text('Try the Practice Bot or invite a friend · 5 coins returned'), findsOneWidget);
    expect(find.widgetWithText(AppButton, 'Cancel'), findsNothing);
    expect(find.text('No one was available'), findsOneWidget, reason: 'no second notice on top');

    await tester.tap(find.text('Search again'));
    await advance(tester, const Duration(milliseconds: 600));
    final joins = server.sentOfType('mm.join');
    expect(joins, hasLength(2));
    expect(joins.last['d'], containsPair('mode', 'casual'));
    expect(joins.last['d'], containsPair('chapter', 'kinematics'));
    expect(find.text('Finding an opponent…'), findsOneWidget);
  });

  testWidgets('after a stopped search, the Practice Bot is one tap away', (tester) async {
    usePhoneViewport(tester);
    reduceMotion(tester);
    final match = MatchFrames(them: 'bot', kind: 'bot');
    final server = _server(
      also: (socket, message) {
        final data = message['d'] as Map?;
        if (message['t'] == 'mm.join' && data?['mode'] == 'bot') {
          socket
            ..push(match.found(mode: 'bot', bot: true))
            ..push(match.snapshot(phase: 'ready_wait'));
        }
      },
    );
    final container = await _search(tester, server);
    server.push(frame('mm.cancelled', {'reason': 'disconnected', 'refunded': 0}, 'u'));
    await advance(tester, const Duration(milliseconds: 600));
    expect(
      find.text('The connection dropped for too long. It doesn\'t count against you'),
      findsOneWidget,
    );
    await tester.tap(find.text('Play the Practice Bot'));
    await advance(tester, const Duration(milliseconds: 600));
    expect(server.sentOfType('mm.join').last['d'], containsPair('mode', 'bot'));
    expect(location(container), Routes.battleMatch('m1'));
  });

  testWidgets('an opponent who never got ready: back to searching, first in line', (tester) async {
    usePhoneViewport(tester);
    reduceMotion(tester);
    final match = MatchFrames();
    final server = _server();
    final container = await _search(tester, server);
    server
      ..push(match.found())
      ..push(match.snapshot(phase: 'ready_wait', endsAt: serverNow() + 10000));
    await advance(tester, const Duration(milliseconds: 600));
    expect(location(container), Routes.battleMatch('m1'));

    server.push(frame('mm.requeued', {'reason': 'opponent_not_ready', 'waited_s': 31}, 'u'));
    await advance(tester, const Duration(milliseconds: 600));
    expect(location(container), Routes.battleSearch);
    expect(find.text('Searching again…'), findsWidgets);
    expect(find.text('Your opponent didn\'t join. You\'re first in line.'), findsOneWidget);
    expect(find.text('0:31'), findsOneWidget, reason: 'the waiting time is kept');
    expect(container.read(liveControllerProvider)!.match('m1'), isNull);
  });

  testWidgets('without a search, the screen says so and leads back', (tester) async {
    usePhoneViewport(tester);
    reduceMotion(tester);
    final container = await pumpApp(
      tester,
      prefs: await testPrefs(),
      location: Routes.battleSearch,
      settle: false,
    );
    await advance(tester, const Duration(milliseconds: 500));
    expect(find.text('You\'re not searching'), findsOneWidget);
    expect(find.text('Start a quick battle from the Battle tab.'), findsOneWidget);
    expect(find.text('Search again'), findsNothing);
    await tester.tap(find.text('Back to Battle'));
    await advance(tester, const Duration(milliseconds: 500));
    expect(location(container), Routes.battle);
  });

  group('searchStatusLine', () {
    const physics = SearchRequest(mode: 'rated', subject: 'physics');
    const kinematics = SearchRequest(mode: 'rated', subject: 'physics', chapter: 'kinematics');

    test('names the subject and chapter', () {
      expect(searchStatusLine(const SearchState()), 'Looking for an opponent…');
      expect(
        searchStatusLine(const SearchState(phase: SearchPhase.queued, request: physics)),
        'Looking for a Physics player…',
      );
      expect(
        searchStatusLine(const SearchState(phase: SearchPhase.queued, request: kinematics)),
        'Looking for a Physics player in Kinematics…',
      );
    });

    test('says when the search widened', () {
      expect(
        searchStatusLine(
          const SearchState(phase: SearchPhase.queued, request: kinematics, widened: true),
        ),
        'Widened to all of Physics',
      );
    });
  });
}
