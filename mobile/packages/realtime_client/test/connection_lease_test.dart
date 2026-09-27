import 'package:fake_async/fake_async.dart';
import 'package:realtime_client/realtime_client.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';
import 'support/frames.dart';
import 'support/harness.dart';

void main() {
  /// Keeps the watchdog quiet for [seconds] with a server ping every 10 s.
  void idle(Harness h, int seconds) {
    for (var t = 0; t < seconds; t += 10) {
      h.elapse(Duration(seconds: seconds - t < 10 ? seconds - t : 10));
      h.push(frame('ping', {'n': t}, 'u'));
    }
  }

  test('the socket opens with the first lease', () {
    fakeAsync((async) {
      final h = Harness(async);
      expect(h.connector.attempts, 0);

      final lease = h.connection.acquire('battle-tab');
      h.flush();

      expect(h.state, isA<Open>());
      expect(h.connection.leases, [lease]);
      expect(lease.reason, 'battle-tab');
      expect(lease.inMatch, isFalse);
      h.dispose();
    });
  });

  test('closes 30 s after the last lease is released', () {
    fakeAsync((async) {
      final h = Harness(async);
      final lease = h.open(reason: 'battle-tab');
      final socket = h.socket;

      lease.release();
      expect(lease.isReleased, isTrue);
      idle(h, 29);
      h.elapseMs(999);
      expect(socket.isClosed, isFalse);
      expect(h.state, isA<Open>());

      h.elapseMs(1);
      expect(socket.closedByClient, isTrue);
      expect(socket.clientCloseCode, 1000);
      expect(h.state, isA<Idle>());

      h.elapse(const Duration(minutes: 5));
      expect(h.connector.attempts, 1, reason: 'nothing reconnects without a lease');
      h.dispose();
    });
  });

  test('a lease taken during the linger keeps the same socket', () {
    fakeAsync((async) {
      final h = Harness(async);
      h.open(reason: 'battle-tab').release();
      idle(h, 20);

      final again = h.connection.acquire('matchmaking');
      idle(h, 60);

      expect(h.connector.sockets, hasLength(1));
      expect(h.socket.isClosed, isFalse);
      again.release();
      idle(h, 29);
      expect(h.socket.isClosed, isFalse);
      h.elapse(const Duration(seconds: 1));
      expect(h.state, isA<Idle>());
      h.dispose();
    });
  });

  test('stays open while any lease is held, and releasing twice is harmless', () {
    fakeAsync((async) {
      final h = Harness(async);
      final tab = h.open(reason: 'battle-tab');
      final room = h.connection.acquire('room:R1');

      tab
        ..release()
        ..release();
      idle(h, 120);
      expect(h.state, isA<Open>());
      expect(h.connection.leases, [room]);

      room.release();
      idle(h, 30);
      expect(h.state, isA<Idle>());
      h.dispose();
    });
  });

  test('the linger also ends a pending reconnect', () {
    fakeAsync((async) {
      final h = Harness(async, random: MaxRandom());
      final lease = h.open();
      h.connector.failures.addAll([for (var i = 0; i < 10; i++) StateError('down')]);
      h.socket.closeFromServer(1013);
      h.flush();
      lease.release();

      h.elapse(const Duration(seconds: 30));
      expect(h.state, isA<Idle>());
      final attempts = h.connector.attempts;
      h.elapse(const Duration(minutes: 5));
      expect(h.connector.attempts, attempts);
      h.dispose();
    });
  });

  test('reopens with a fresh ticket after going idle', () {
    fakeAsync((async) {
      final h = Harness(async);
      h.open().release();
      idle(h, 30);
      expect(h.state, isA<Idle>());

      h.open();
      expect(h.tickets, ['t1', 't2']);
      expect(h.connector.sockets, hasLength(2));
      h.dispose();
    });
  });

  test('requests need a lease (or the linger)', () {
    fakeAsync((async) {
      final h = Harness(async);
      final early = Outcome(h.connection.request('mm.cancel', {}));
      h.flush();
      expect(early.realtimeError.code, RealtimeErrorCode.notConnected);

      h.open().release();
      final lingering = Outcome(h.connection.request('mm.cancel', {}));
      h.push(frame('ack', {'ref': h.lastIdOf('mm.cancel')}));
      expect(lingering.value.reply, isA<AckEvent>());
      h.dispose();
    });
  });

  test('requests queued while connecting fail when the linger ends first', () {
    fakeAsync((async) {
      final h = Harness(async)..connector.hang = true;
      h.connection.acquire('battle-tab').release();
      final queued = Outcome(
        h.connection.request('mm.cancel', {}, timeout: const Duration(minutes: 1)),
      );

      h.elapse(const Duration(seconds: 30));

      expect(h.state, isA<Idle>());
      expect(queued.realtimeError.code, RealtimeErrorCode.notConnected);
      h.dispose();
    });
  });

  test('a disposed connection hands out released leases', () {
    fakeAsync((async) {
      final h = Harness(async)..dispose();

      final lease = h.connection.acquire('late');

      expect(lease.isReleased, isTrue);
      expect(h.connector.attempts, 0);
    });
  });
}
