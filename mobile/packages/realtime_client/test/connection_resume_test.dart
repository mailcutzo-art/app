import 'package:fake_async/fake_async.dart';
import 'package:realtime_client/realtime_client.dart';
import 'package:test/test.dart';

import 'support/frames.dart';
import 'support/harness.dart';

void main() {
  Map<String, Object?> progress(int seq, {String ch = 'm:M1'}) =>
      frame('q.progress', {'q': 1, 'answered': <String>[]}, ch, seq);

  Map<String, Object?> snapshot(int seq, {String matchId = 'M1'}) => frame(
    'match.snapshot',
    {
      'match_id': matchId,
      'phase': 'q_open',
      'q': 1,
      'total': 7,
      'players': [
        {...card('u1'), 'connected': true, 'score': 0},
      ],
    },
    'm:$matchId',
    seq,
  );

  Map<String, Object?> roomState(int seq) => frame(
    'room.state',
    {'room_id': 'R1', 'kind': 'group', 'host': 'u1', 'status': 'lobby', 'members': <Object?>[]},
    'r:R1',
    seq,
  );

  /// Drops the socket and runs until the next one is open.
  void reconnect(Harness h) {
    h.socket.closeFromServer(1013);
    h.flush();
    h.elapse(h.retryIn);
    expect(h.state, isA<Open>());
  }

  List<Object?> resumeOf(Harness h) =>
      (h.socket.sentOfType('hello').single['d']! as Map<String, Object?>)['resume']!
          as List<Object?>;

  List<int?> seqs(Iterable<ServerEvent> events) => [for (final e in events) e.seq];

  List<Map<String, Object?>> syncs(Harness h) => [
    for (final s in h.connector.sockets)
      for (final m in s.sentOfType('sync')) m['d']! as Map<String, Object?>,
  ];

  test('hello resumes every tracked channel from its last applied seq', () {
    fakeAsync((async) {
      final h = Harness(async)..open();
      h.push(frame('mm.found', {'match_id': 'M1', 'opponent': card('u2')}, 'u'));
      reconnect(h);
      expect(resumeOf(h), [
        {'ch': 'm:M1', 'last_seq': 0},
      ], reason: 'tracked as soon as mm.found names it');

      h.push(snapshot(0));
      for (var seq = 1; seq <= 12; seq++) {
        h.push(progress(seq));
      }
      h.push(roomState(4));
      h.push(frame('t.round', {'round': 1, 'status': 'live'}, 't:T1', 3));
      reconnect(h);

      expect(resumeOf(h), [
        {'ch': 'm:M1', 'last_seq': 12},
        {'ch': 'r:R1', 'last_seq': 4},
      ]);
      expect(h.connection.resumeList, const [ResumeEntry('m:M1', 12), ResumeEntry('r:R1', 4)]);
      h.dispose();
    });
  });

  test('a replay after reconnecting skips what was already applied', () {
    fakeAsync((async) {
      final h = Harness(async)..open();
      h.push(snapshot(10));
      h.push(progress(11));
      h.push(progress(12));
      reconnect(h);
      h.events.clear();

      for (final seq in [11, 12, 13, 14]) {
        h.push(progress(seq));
      }

      expect(seqs(h.events), [13, 14]);
      expect(syncs(h), isEmpty);
      h.dispose();
    });
  });

  test('a gap sends sync, holds later events, and delivers them in order once filled', () {
    fakeAsync((async) {
      final h = Harness(async)..open();
      h.push(snapshot(14));
      h.events.clear();

      h.push(progress(16));
      expect(h.events, isEmpty);
      expect(syncs(h), [
        {'ch': 'm:M1', 'last_seq': 14},
      ]);

      h.push(progress(17));
      expect(syncs(h), hasLength(1), reason: 'one sync per gap');

      // The server replays from 15, including what is already held.
      for (final seq in [15, 16, 17]) {
        h.push(progress(seq));
      }
      expect(seqs(h.events), [15, 16, 17]);
      expect(h.connection.lastSeq('m:M1'), 17);

      h.push(progress(18));
      expect(seqs(h.events), [15, 16, 17, 18]);
      h.dispose();
    });
  });

  test('a snapshot resolves a gap and resets the seq', () {
    fakeAsync((async) {
      final h = Harness(async)..open();
      h.push(snapshot(17));
      h.events.clear();

      h.push(progress(20));
      h.push(snapshot(21));
      h.push(progress(22));

      expect(h.events.map((e) => e.type), ['match.snapshot', 'q.progress']);
      expect(seqs(h.events), [21, 22]);
      h.elapse(const Duration(seconds: 10));
      expect(syncs(h), hasLength(1), reason: 'the gap is closed, so no more syncs');
      h.dispose();
    });
  });

  test('the sync is repeated every 3 s while the gap stays open', () {
    fakeAsync((async) {
      final h = Harness(async)..open();
      h.push(snapshot(5));
      h.push(progress(7));
      expect(syncs(h), hasLength(1));

      h.elapse(const Duration(seconds: 3));
      expect(syncs(h), hasLength(2));
      h.push(progress(6));
      h.elapse(const Duration(seconds: 10));

      expect(syncs(h), hasLength(2));
      expect(seqs(h.events), [5, 6, 7]);
      h.dispose();
    });
  });

  test('a refused sync is not repeated', () {
    fakeAsync((async) {
      final h = Harness(async)..open();
      h.push(snapshot(5));
      h.push(progress(7));
      final syncId = h.lastIdOf('sync');

      h.push(frame('error', {'ref': syncId, 'code': 'NOT_FOUND'}));
      h.elapse(const Duration(seconds: 10));

      expect(syncs(h), hasLength(1));
      expect(h.logs, contains(startsWith('sync for m:M1 failed')));
      h.dispose();
    });
  });

  test('the first event on an unknown match channel must be seq 1 or a snapshot', () {
    fakeAsync((async) {
      final h = Harness(async)..open();

      h.push(progress(4, ch: 'm:M5'));

      expect(h.events, isEmpty);
      expect(syncs(h), [
        {'ch': 'm:M5', 'last_seq': 0},
      ]);
      h.push(snapshot(9, matchId: 'M5'));
      expect(h.events.single, isA<MatchSnapshotEvent>());
      h.dispose();
    });
  });

  test('a reconnect drops held events; the resume replays them', () {
    fakeAsync((async) {
      final h = Harness(async)..open();
      h.push(snapshot(3));
      h.push(progress(5));
      reconnect(h);

      expect(resumeOf(h), [
        {'ch': 'm:M1', 'last_seq': 3},
      ]);
      h.push(progress(4));
      h.push(progress(5));
      expect(seqs(h.events), [3, 4, 5]);
      h.dispose();
    });
  });

  test('forgotten channels are not resumed, and late events on them pass through', () {
    fakeAsync((async) {
      final h = Harness(async)..open();
      h.push(snapshot(30));
      h.connection.forgetChannel('m:M1');
      reconnect(h);

      expect(resumeOf(h), isEmpty);
      h.push(progress(40));
      expect(h.events.last.seq, 40);
      expect(syncs(h), isEmpty);
      h.dispose();
    });
  });

  test('room.kicked and room.closed forget the room', () {
    fakeAsync((async) {
      final h = Harness(async)..open();
      h.push(roomState(2));
      h.push(frame('room.kicked', {'room_id': 'R1'}, 'r:R1', 3));
      expect(h.connection.resumeList, isEmpty);

      h.push(roomState(8));
      expect(h.connection.resumeList, const [ResumeEntry('r:R1', 8)]);
      h.push(frame('room.closed', {'room_id': 'R1', 'reason': 'host_ended'}, 'r:R1', 9));
      expect(h.connection.resumeList, isEmpty);
      h.dispose();
    });
  });

  test('room.started and t.pairing track the match they announce', () {
    fakeAsync((async) {
      final h = Harness(async)..open();

      h.push(frame('room.started', {'match_id': 'M7', 'ch': 'm:M7'}, 'r:R1', 1));
      h.push(
        frame('t.pairing', {
          'tournament_id': 'T1',
          'round': 1,
          'match_id': 'M8',
          'opponent': card('u3'),
        }, 'u'),
      );

      expect(h.connection.resumeList.map((e) => e.channel), ['r:R1', 'm:M7', 'm:M8']);
      h.dispose();
    });
  });

  test('syncChannel reopens a game named by welcome.active after a cold start', () {
    fakeAsync((async) {
      final h = Harness(
        async,
        active: [
          {'kind': 'match', 'ch': 'm:M9', 'state': 'q_open'},
        ],
      )..open();

      for (final entry in h.connection.welcome!.active) {
        h.connection.syncChannel(entry.channel!);
      }
      h.flush();

      expect(syncs(h), [
        {'ch': 'm:M9', 'last_seq': 0},
      ]);
      h.push(snapshot(23, matchId: 'M9'));
      expect(h.events.single, isA<MatchSnapshotEvent>());
      expect(h.connection.lastSeq('m:M9'), 23);
      expect(() => h.connection.syncChannel('u'), throwsArgumentError);
      h.dispose();
    });
  });
}
