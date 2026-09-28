import 'package:realtime_client/realtime_client.dart';
import 'package:test/test.dart';

import 'support/frames.dart';

Map<String, Object?> member(
  String uid, {
  bool ready = false,
  bool connected = true,
  bool away = false,
}) => {
  ...card(uid),
  'ready': ready,
  'connected': connected,
  'away': away,
  'role': uid == 'u1' ? 'host' : 'member',
};

ServerEvent roomState(
  int seq, {
  String roomId = 'R1',
  String host = 'u1',
  String status = 'lobby',
  List<Map<String, Object?>>? members,
  Map<String, Object?>? rematch,
  String? matchId,
}) => event(
  'room.state',
  {
    'room_id': roomId,
    'kind': 'group',
    'code': 'K7M2QX',
    'host': host,
    'status': status,
    'locked': false,
    'settings': {'subject': 'physics', 'questions': 10, 'seconds': 15},
    'members': members ?? [member('u1', ready: true), member('u2')],
    'rematch': rematch,
    'match_id': ?matchId,
    'capacity': 8,
  },
  'r:$roomId',
  seq,
);

void main() {
  RoomState run(List<ServerEvent> events) => events.fold(const RoomState.initial('R1'), reduceRoom);

  test('room.state replaces the whole lobby', () {
    final state = run([roomState(3)]);
    expect(state.isKnown, isTrue);
    expect(state.status, RoomStatus.lobby);
    expect(state.kind, 'group');
    expect(state.isGroup, isTrue);
    expect(state.isFriend, isFalse);
    expect(state.code, 'K7M2QX');
    expect(state.isHost('u1'), isTrue);
    expect(state.settings.questions, 10);
    expect(state.capacity, 8);
    expect(state.hasSpace, isTrue);
    expect([for (final m in state.members) m.uid], ['u1', 'u2']);
    expect(state.hostMember?.uid, 'u1');
    expect(state.member('u9'), isNull);
    expect(state.previousHost, isNull);
    expect(const RoomState.initial('R1').isKnown, isFalse);
  });

  test('start needs two connected members; all ready needs every connected one', () {
    expect(run([roomState(1)]).canStart, isTrue);
    expect(run([roomState(1)]).allReady, isFalse);
    expect(
      run([
        roomState(1, members: [member('u1', ready: true), member('u2', ready: true)]),
      ]).allReady,
      isTrue,
    );
    final alone = run([
      roomState(1, members: [member('u1', ready: true), member('u2', connected: false)]),
    ]);
    expect(alone.canStart, isFalse);
    expect(alone.connectedCount, 1);
    expect(alone.allReady, isFalse);
    expect(run([roomState(1, status: 'playing')]).canStart, isFalse);
  });

  test('waiting for away and disconnected members, host first', () {
    final state = run([
      roomState(1, members: [member('u2', away: true), member('u1', away: true), member('u3')]),
    ]);
    expect([for (final m in state.waitingFor) m.uid], ['u1', 'u2']);
    expect([for (final m in state.present) m.uid], ['u3']);
  });

  test('a new host is remembered with the previous one', () {
    final state = run([roomState(1), roomState(2, host: 'u2')]);
    expect(state.host, 'u2');
    expect(state.previousHost, 'u1');
    expect(
      run([roomState(1), roomState(2, host: 'u2'), roomState(3, host: 'u2')]).previousHost,
      'u1',
    );
  });

  test('room.started starts the game on its match channel', () {
    final state = run([
      roomState(1),
      event('room.started', {'match_id': 'M5', 'ch': 'm:M5'}, 'r:R1', 2),
    ]);
    expect(state.status, RoomStatus.playing);
    expect(state.matchId, 'M5');

    // Another room's start changes nothing.
    expect(
      run([
        roomState(1),
        event('room.started', {'match_id': 'M6'}, 'r:R2', 2),
      ]).matchId,
      isNull,
    );

    // A later room.state keeps the match while playing and after it, and drops it in the lobby.
    expect(run([roomState(1), roomState(2, status: 'playing', matchId: 'M5')]).matchId, 'M5');
    final finished = run([
      roomState(1, status: 'playing', matchId: 'M5'),
      roomState(
        2,
        status: 'finished',
        rematch: {
          'offered_by': 'u2',
          'accepted': ['u2'],
        },
      ),
    ]);
    expect(finished.matchId, 'M5');
    expect(finished.rematch!.accepted, ['u2']);
    expect(run([roomState(1, status: 'playing', matchId: 'M5'), roomState(2)]).matchId, isNull);
  });

  test('kicked and closed are final', () {
    final kicked = run([
      roomState(1),
      event('room.kicked', {'room_id': 'R1'}, 'r:R1', 2),
    ]);
    expect(kicked.status, RoomStatus.kicked);
    expect(kicked.status.isGone, isTrue);
    expect(reduceRoom(kicked, roomState(3)), same(kicked));

    final closed = run([
      roomState(1),
      event('room.closed', {'room_id': 'R1', 'reason': 'host_ended'}, 'r:R1', 2),
    ]);
    expect(closed.status, RoomStatus.closed);
    expect(closed.closedReason, 'host_ended');
    expect(reduceRoom(closed, event('room.started', {'match_id': 'M1'}, 'r:R1', 3)), same(closed));
  });

  test('events for other rooms and other messages change nothing', () {
    final state = run([roomState(1)]);
    expect(reduceRoom(state, roomState(2, roomId: 'R2')), same(state));
    expect(reduceRoom(state, event('room.kicked', {'room_id': 'R2'})), same(state));
    expect(reduceRoom(state, event('ping', {'n': 1})), same(state));
    expect(RoomStatus.parse('paused'), RoomStatus.unknown);
    expect(RoomStatus.parse('closed'), RoomStatus.closed);
  });
}
