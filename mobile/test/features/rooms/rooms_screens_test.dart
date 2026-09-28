import 'package:design_system/design_system.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_app/app/router.dart';
import 'package:quiz_app/core/config/app_config.dart';
import 'package:quiz_app/core/network/app_failure.dart';
import 'package:quiz_app/features/rooms/data/fake_rooms_repository.dart';
import 'package:quiz_app/features/rooms/data/room_models.dart';
import 'package:quiz_app/features/rooms/room_share.dart';
import 'package:quiz_app/features/rooms/rooms_controller.dart';
import 'package:quiz_app/features/social/data/social_models.dart';

import '../../support/battle.dart';
import '../../support/fakes.dart';
import '../../support/room_frames.dart';
import '../../support/rt_server.dart';

final _shared = <String>[];
final _copied = <String>[];

Future<ProviderContainer> _pump(
  WidgetTester tester,
  TestRealtimeServer server, {
  required String location,
  FakeRoomsRepository? rooms,
  String? paste,
}) async {
  usePhoneViewport(tester, height: 1500);
  reduceMotion(tester);
  _shared.clear();
  _copied.clear();
  final container = await pumpApp(
    tester,
    prefs: await testPrefs(),
    realtime: server,
    rooms: rooms,
    location: location,
    settle: false,
    overrides: [
      roomShareProvider.overrideWithValue((text, {subject}) async => _shared.add(text)),
      roomClipboardProvider.overrideWithValue((text) async => _copied.add(text)),
      roomPasteProvider.overrideWithValue(() async => paste),
    ],
  );
  await advance(tester, const Duration(milliseconds: 800));
  return container;
}

List<Map<String, Object?>> _sent(TestRealtimeServer server, String type) =>
    server.sentOfType(type).map((m) => (m['d']! as Map).cast<String, Object?>()).toList();

Finder _iconButton(String label) =>
    find.byWidgetPredicate((w) => w is AppIconButton && w.semanticLabel == label);

AppButton _button(WidgetTester tester, String label) =>
    tester.widget<AppButton>(find.widgetWithText(AppButton, label));

void main() {
  group('set-up', () {
    testWidgets('a friend duel: defaults, create, join, then the friend is invited', (
      tester,
    ) async {
      final server = TestRealtimeServer();
      final room = RoomFrames(kind: 'friend', code: 'ABC001');
      serveRoom(server, room.state);
      final rooms = FakeRoomsRepository();
      final container = await _pump(
        tester,
        server,
        rooms: rooms,
        location: Routes.roomSetup('friend', friend: 'u-rahul'),
      );

      expect(find.text('Play with a friend'), findsOneWidget);
      expect(find.text('You\'ll invite Rahul as soon as the room is ready.'), findsOneWidget);
      expect(find.text('Difficulty'), findsNothing, reason: 'group only');
      await tester.tap(find.text('10'));
      await advance(tester, const Duration(milliseconds: 300));
      await tester.tap(find.text('20 s'));
      await advance(tester, const Duration(milliseconds: 300));

      await tester.tap(find.text('Create room'));
      await advance(tester, const Duration(seconds: 1));

      final created = rooms.created.single;
      expect(created.kind, RoomKind.friend);
      expect(created.settings.questions, 10);
      expect(created.settings.seconds, 20);
      expect(created.settings.subject, 'physics');
      expect(created.key, isNotEmpty);
      expect(_sent(server, 'room.join').single, {'room_id': 'R1'});
      expect(location(container), Routes.room('R1', invite: 'u-rahul'));
      expect(rooms.invited.single, (to: 'u-rahul', roomId: 'R1'));
      expect(find.text('K7M 2QX'), findsNothing);
      expect(find.text('ABC 001'), findsOneWidget);
      expect(find.text('Waiting for your friend…'), findsOneWidget);
    });

    testWidgets('a group battle has the group options', (tester) async {
      final server = TestRealtimeServer();
      await _pump(tester, server, location: Routes.roomSetup('group'));
      expect(find.text('Group battle'), findsOneWidget);
      expect(find.text('Difficulty'), findsOneWidget);
      expect(find.text('Until halfway'), findsOneWidget);
      expect(find.text('Anyone with code'), findsOneWidget);
      expect(find.text('Leaderboard between questions'), findsOneWidget);
      expect(find.text('20'), findsOneWidget, reason: '5/10/15/20 questions');
    });

    testWidgets('a failed create says why and keeps the screen', (tester) async {
      final server = TestRealtimeServer();
      final rooms = FakeRoomsRepository()..failure = const ServerFailure();
      await _pump(tester, server, rooms: rooms, location: Routes.roomSetup('friend'));
      await tester.tap(find.text('Create room'));
      await advance(tester, const Duration(milliseconds: 500));
      expect(find.text(const ServerFailure().message), findsOneWidget);
      expect(server.sentOfType('room.join'), isEmpty);
    });
  });

  group('lobby', () {
    testWidgets('the host: code, copy, share, members, start, manage and lock', (tester) async {
      final server = TestRealtimeServer();
      final room = RoomFrames();
      var members = [member(meCard, host: true), member(riyaCard, ready: true)];
      serveRoom(server, () => room.state(members: members));
      final container = await _pump(tester, server, location: Routes.room('R1'));

      expect(_sent(server, 'room.join').single, {'room_id': 'R1'});
      expect(find.text('K7M 2QX'), findsOneWidget);
      expect(find.text('Players 2/8'), findsOneWidget);
      expect(find.text('Aarav (you)'), findsOneWidget);
      expect(find.text('Host'), findsOneWidget);
      expect(find.text('Ready'), findsOneWidget);
      expect(find.text('Not ready'), findsOneWidget);

      expect(_button(tester, 'Start').onPressed, isNotNull);
      await tester.tap(find.text('Start'));
      await advance(tester, const Duration(milliseconds: 300));
      expect(_sent(server, 'room.start').single, {'room_id': 'R1'});

      await tester.tap(find.text('Copy code'));
      await advance(tester, const Duration(milliseconds: 300));
      await tester.tap(find.text('Share link'));
      await advance(tester, const Duration(milliseconds: 300));
      expect(_copied, ['K7M2QX']);
      expect(_shared.single, contains('K7M2QX'));
      await advance(tester, const Duration(seconds: 5));

      await tester.tap(_iconButton('Manage Riya'));
      await advance(tester, const Duration(milliseconds: 500));
      await tester.tap(find.text('Make host'));
      await advance(tester, const Duration(milliseconds: 500));
      expect(_sent(server, 'room.transfer').single, {'room_id': 'R1', 'uid': 'u2'});

      await tester.tap(_iconButton('Room settings'));
      await advance(tester, const Duration(milliseconds: 500));
      await tester.tap(find.text('Lock the room'));
      await advance(tester, const Duration(milliseconds: 500));
      expect(_sent(server, 'room.lock').single, {'room_id': 'R1', 'locked': true});

      // Riya leaves: start needs two connected players.
      members = [member(meCard, host: true)];
      server.push(room.state(members: members));
      await advance(tester, const Duration(milliseconds: 300));
      expect(_button(tester, 'Start').onPressed, isNull);
      expect(find.text('Start needs at least 2 players connected'), findsOneWidget);
      expect(container.read(roomViewProvider)?.isHost, isTrue);
    });

    testWidgets('a member: waiting for the host, ready, a new host, and a closed room', (
      tester,
    ) async {
      final server = TestRealtimeServer();
      final room = RoomFrames(kind: 'friend');
      serveRoom(
        server,
        () => room.state(
          host: 'u2',
          members: [member(riyaCard, host: true, away: true, ready: true), member(meCard)],
        ),
      );
      final container = await _pump(tester, server, location: Routes.room('R1'));

      expect(find.text('Waiting for Riya to come back'), findsOneWidget);
      expect(find.text('Away'), findsOneWidget);
      expect(find.text('Start'), findsNothing);
      await tester.tap(find.text('I\'m ready'));
      await advance(tester, const Duration(milliseconds: 300));
      expect(_sent(server, 'room.ready').single, {'room_id': 'R1', 'ready': true});

      server.push(room.state(members: [member(meCard, host: true, ready: true)]));
      await advance(tester, const Duration(milliseconds: 300));
      expect(find.text('You\'re now the host'), findsOneWidget);
      expect(find.text('Start'), findsOneWidget);

      server.push(room.closed('host_ended'));
      await advance(tester, const Duration(milliseconds: 600));
      expect(location(container), Routes.battle);
      expect(find.text('The host closed the room'), findsOneWidget);
      expect(container.read(roomViewProvider), isNull);
    });

    testWidgets('invites: the friends list, busy chips and a pending invite', (tester) async {
      final server = TestRealtimeServer();
      final room = RoomFrames(kind: 'friend');
      serveRoom(server, () => room.state(members: [member(meCard, host: true)]));
      final rooms = FakeRoomsRepository()
        ..inviteFailures['u-kabir'] = const ConflictFailure('Busy', code: 'BUSY');
      await _pump(tester, server, rooms: rooms, location: Routes.room('R1', pick: true));
      await advance(tester, const Duration(milliseconds: 600));

      expect(find.text('Invite friends'), findsWidgets);
      expect(find.text('Rahul'), findsOneWidget);
      // Meera is in a battle: busy, no invite.
      expect(find.text('Busy'), findsWidgets);

      await tester.tap(find.widgetWithText(AppButton, 'Invite').first);
      await advance(tester, const Duration(milliseconds: 300));
      expect(rooms.invited.first.to, 'u-rahul');
      expect(find.textContaining('Invited · '), findsOneWidget);

      await tester.tap(_iconButton('Cancel the invite to Rahul'));
      await advance(tester, const Duration(milliseconds: 300));
      expect(rooms.cancelled, ['I1']);
    });
  });

  group('joining by code', () {
    testWidgets('a room link previews the room, then joins it', (tester) async {
      final server = TestRealtimeServer();
      final room = RoomFrames(roomId: 'R9');
      serveRoom(
        server,
        () => room.state(host: 'u2', members: [member(riyaCard, host: true), member(meCard)]),
      );
      final rooms = FakeRoomsRepository()..previews['K7M2QX'] = samplePreview();
      final container = await _pump(tester, server, rooms: rooms, location: '/j/K7M2QX');

      expect(location(container), Routes.joinRoom('K7M2QX'));
      expect(find.text('Riya\'s room'), findsOneWidget);
      expect(find.text('Group battle · 3/8 players'), findsOneWidget);
      await tester.tap(find.text('Join room'));
      await advance(tester, const Duration(milliseconds: 600));
      expect(_sent(server, 'room.join').single, {'code': 'K7M2QX'});
      expect(location(container), Routes.room('R9'));
    });

    testWidgets('a room that can\'t be joined says why', (tester) async {
      final server = TestRealtimeServer();
      final rooms = FakeRoomsRepository()
        ..previews['K7M2QX'] = samplePreview(joinable: false, reason: JoinBlock.started);
      await _pump(tester, server, rooms: rooms, location: Routes.joinRoom('K7M2QX'));
      expect(find.text('The game has already started.'), findsOneWidget);
      expect(find.text('Join room'), findsNothing);
    });

    testWidgets('an unknown code says so', (tester) async {
      final unknown = FakeRoomsRepository();
      await _pump(
        tester,
        TestRealtimeServer(),
        rooms: unknown,
        location: Routes.joinRoom('ZZZZZZ'),
      );
      expect(find.text('No room with that code'), findsOneWidget);
      expect(find.text('That code isn\'t active. Ask for a new one.'), findsOneWidget);
    });

    testWidgets('paste fills in the code and previews it', (tester) async {
      final server = TestRealtimeServer();
      final rooms = FakeRoomsRepository()..previews['K7M2QX'] = samplePreview();
      await _pump(tester, server, rooms: rooms, location: Routes.joinRoom(), paste: 'k7m-2qx');
      expect(find.text('Join room'), findsNothing);
      await tester.tap(find.text('Paste'));
      await advance(tester, const Duration(milliseconds: 300));
      expect(rooms.previewed, ['K7M2QX']);
      expect(find.text('Join room'), findsOneWidget);
    });
  });

  group('invites received', () {
    Map<String, Object?> invite(String id) => frame('invite.received', {
      'invite_id': id,
      'from': riyaCard,
      'kind': 'friend',
      'room_id': 'R9',
      'subject': 'physics',
      'expires_at': serverNow() + 120000,
    }, 'u');

    testWidgets('a banner on any screen: Accept joins the room', (tester) async {
      final server = TestRealtimeServer();
      final room = RoomFrames(roomId: 'R9', kind: 'friend');
      serveRoom(
        server,
        () => room.state(host: 'u2', members: [member(riyaCard, host: true), member(meCard)]),
      );
      final rooms = FakeRoomsRepository();
      final container = await _pump(tester, server, rooms: rooms, location: Routes.learn);

      server.push(invite('I7'));
      await advance(tester, const Duration(milliseconds: 600));
      expect(find.text('Riya invited you'), findsOneWidget);
      expect(find.textContaining('Friend battle · Physics'), findsOneWidget);
      expect(find.textContaining('Expires in'), findsOneWidget);

      await tester.tap(find.text('Accept'));
      await advance(tester, const Duration(seconds: 1));
      expect(rooms.acceptedIds, ['I7']);
      expect(_sent(server, 'room.join').single, {'room_id': 'R9'});
      expect(location(container), Routes.room('R9'));
      expect(find.text('Riya invited you'), findsNothing);
    });

    testWidgets('Decline, a cancelled invite, and invites held back during a game', (tester) async {
      final server = TestRealtimeServer();
      final rooms = FakeRoomsRepository();
      final container = await _pump(tester, server, rooms: rooms, location: Routes.home);

      server.push(invite('I1'));
      await advance(tester, const Duration(milliseconds: 600));
      await tester.tap(find.text('Decline'));
      await advance(tester, const Duration(milliseconds: 600));
      expect(rooms.declined, ['I1']);
      expect(find.text('Riya invited you'), findsNothing);

      server.push(invite('I2'));
      await advance(tester, const Duration(milliseconds: 600));
      expect(find.text('Riya invited you'), findsOneWidget);
      server.push(frame('invite.updated', {'invite_id': 'I2', 'status': 'cancelled'}, 'u'));
      await advance(tester, const Duration(milliseconds: 600));
      expect(find.text('Riya invited you'), findsNothing);

      container.read(liveGameProvider.notifier).set(live: true);
      server.push(invite('I3'));
      await advance(tester, const Duration(milliseconds: 600));
      expect(find.text('Riya invited you'), findsNothing, reason: 'waits for the game to end');
      container.read(liveGameProvider.notifier).set(live: false);
      await advance(tester, const Duration(milliseconds: 600));
      expect(find.text('Riya invited you'), findsOneWidget);
    });

    testWidgets('pending invites are read after connecting', (tester) async {
      final server = TestRealtimeServer();
      final rooms = FakeRoomsRepository()
        ..pending = InviteList(
          incoming: [
            RoomInvite(
              inviteId: 'I5',
              user: const UserCard(id: 'u2', handle: 'riya_s', displayName: 'Riya'),
              roomId: 'R9',
              kind: RoomKind.group,
              expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 1)),
            ),
          ],
        );
      await _pump(tester, server, rooms: rooms, location: Routes.home);
      expect(rooms.inviteListCalls, greaterThan(0));
      expect(find.text('Riya invited you'), findsOneWidget);
    });
  });
}
