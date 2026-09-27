import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:realtime_client/realtime_client.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';
import 'support/frames.dart';
import 'support/harness.dart';

void main() {
  group('handshake', () {
    test('stays idle without a lease', () {
      fakeAsync((async) {
        final h = Harness(async);
        h.elapse(const Duration(minutes: 1));

        expect(h.state, isA<Idle>());
        expect(h.connector.attempts, 0);
        expect(h.tickets, isEmpty);
        h.dispose();
      });
    });

    test('fetches a ticket, connects, says hello and opens on welcome', () {
      fakeAsync((async) {
        final h = Harness(
          async,
          active: [
            {'kind': 'match', 'ch': 'm:01929c2e', 'state': 'q_open'},
          ],
        );

        h.connection.acquire('battle-tab');
        expect(h.state, isA<Ticketing>());
        h.flush();

        expect(h.states, [isA<Ticketing>(), isA<Connecting>(), isA<Open>()]);
        expect(h.socket.sent.first, {
          'v': 1,
          't': 'hello',
          'id': 'c1',
          'd': {
            'ticket': 't1',
            'proto': 1,
            'build': 57,
            'platform': 'android',
            'resume': <Object?>[],
          },
        });
        final open = h.state as Open;
        expect(open.welcome.userId, 'u1');
        expect(open.welcome.hbS, 10);
        expect(h.connection.welcome, same(open.welcome));
        expect(open.welcome.active.single.channel, 'm:01929c2e');
        expect(open.welcome.active.single.state, 'q_open');
        h.dispose();
      });
    });

    test('never puts the ticket in the event stream or anywhere but hello', () {
      fakeAsync((async) {
        final h = Harness(async)..open();

        final carryingTicket = h.socket.sent.where((m) => '$m'.contains('t1'));
        expect(carryingTicket.map((m) => m['t']), ['hello']);
        expect(h.events, isEmpty, reason: 'welcome is connection plumbing');
        h.dispose();
      });
    });

    test('gives up on the socket when welcome does not arrive within 5 s', () {
      fakeAsync((async) {
        final h = Harness(async, autoWelcome: false);
        h.connection.acquire('battle-tab');
        h.flush();
        expect(h.state, isA<Connecting>());

        h.elapseMs(4999);
        expect(h.state, isA<Connecting>());
        expect(h.socket.isClosed, isFalse);

        h.elapseMs(1);
        expect(h.connector.sockets.first.closedByClient, isTrue);
        expect(h.state, isA<Backoff>().having((s) => s.attempt, 'attempt', 0));

        // The server answers the next attempt.
        h.autoWelcome = true;
        h.elapse(h.retryIn);
        expect(h.state, isA<Open>());
        expect(h.connector.sockets, hasLength(2));
        h.dispose();
      });
    });

    test('fetches a fresh ticket for every attempt', () {
      fakeAsync((async) {
        final h = Harness(async);
        h.open();
        for (var i = 0; i < 3; i++) {
          h.socket.closeFromServer(1013);
          h.flush();
          h.elapse(h.retryIn);
          expect(h.state, isA<Open>());
        }

        final helloTickets = [
          for (final socket in h.connector.sockets)
            (socket.sentOfType('hello').single['d']! as Map<String, Object?>)['ticket'],
        ];
        expect(helloTickets, ['t1', 't2', 't3', 't4']);
        expect(h.tickets, ['t1', 't2', 't3', 't4']);
        h.dispose();
      });
    });

    test('backs off when the ticket request fails', () {
      fakeAsync((async) {
        final h = Harness(async)..ticketFailures.add(StateError('HTTP 503'));
        h.connection.acquire('battle-tab');
        h.flush();

        expect(h.state, isA<Backoff>());
        expect(h.connector.attempts, 0);
        expect(h.logs, contains(startsWith('Ticket request failed')));

        h.elapse(h.retryIn);
        expect(h.state, isA<Open>());
        expect(h.tickets, ['t1']);
        h.dispose();
      });
    });

    test('backs off when the ticket request takes longer than 15 s', () {
      fakeAsync((async) {
        final h = Harness(async)..hangTickets = true;
        h.connection.acquire('battle-tab');
        h.elapseMs(14999);
        expect(h.state, isA<Ticketing>());

        h.elapseMs(1);
        expect(h.state, isA<Backoff>());
        expect(h.logs, contains(contains('Ticket request timed out')));

        h.hangTickets = false;
        h.elapse(h.retryIn);
        expect(h.state, isA<Open>());
        h.dispose();
      });
    });

    test('a connector that throws synchronously just backs off', () {
      fakeAsync((async) {
        final h = Harness(async)..connector.throwNow = StateError('no sockets today');
        h.connection.acquire('battle-tab');
        h.flush();

        expect(h.state, isA<Backoff>());
        h.elapse(const Duration(seconds: 20));
        expect(h.state, isA<Open>(), reason: 'no stray timeout fired in between');
        h.dispose();
      });
    });

    test('backs off when the socket cannot connect, or takes longer than 10 s', () {
      fakeAsync((async) {
        final h = Harness(async)..connector.failures.add(StateError('refused'));
        h.connection.acquire('battle-tab');
        h.flush();
        expect(h.state, isA<Backoff>());

        h.connector.hang = true;
        h.elapse(h.retryIn);
        expect(h.state, isA<Connecting>());
        h.elapseMs(9999);
        expect(h.state, isA<Connecting>());
        h.elapseMs(1);
        expect(h.state, isA<Backoff>().having((s) => s.attempt, 'attempt', 1));

        h.connector.hang = false;
        h.elapse(h.retryIn);
        expect(h.state, isA<Open>());
        expect(h.tickets, ['t1', 't2', 't3'], reason: 'one ticket per attempt');
        h.dispose();
      });
    });
  });

  group('heartbeat', () {
    test('answers every ping with a pong carrying the same n, at once', () {
      fakeAsync((async) {
        final h = Harness(async)..open();

        h.push(frame('ping', {'n': 7}, 'u'));
        h.push(frame('ping', {'n': 8}));

        final pongs = h.socket.sentOfType('pong');
        expect(
          [for (final pong in pongs) pong['d']],
          [
            {'n': 7},
            {'n': 8},
          ],
        );
        expect(pongs.map((p) => p['id']).toSet(), hasLength(2), reason: 'every message has an id');
        expect(h.events, isEmpty, reason: 'pings are not delivered as events');
        h.dispose();
      });
    });

    // In these tests the server doesn't answer clock pings, so pongs don't count as frames.
    test('reconnects when no frame arrives for 2 × hb_s + 2 s', () {
      fakeAsync((async) {
        final h = Harness(async, autoClockPong: false)..open();
        final first = h.socket;
        expect(h.connection.heartbeatTimeout, const Duration(seconds: 22));

        h.elapseMs(21999);
        expect(first.isClosed, isFalse);
        h.elapseMs(1);

        expect(first.closedByClient, isTrue);
        expect(h.state, isA<Backoff>());
        h.elapse(h.retryIn);
        expect(h.state, isA<Open>());
        expect(h.socket, isNot(same(first)));
        h.dispose();
      });
    });

    test('any frame resets the watchdog', () {
      fakeAsync((async) {
        final h = Harness(async, autoClockPong: false)..open();
        final first = h.socket;

        h.elapse(const Duration(seconds: 20));
        h.push(frame('ping', {'n': 1}, 'u'));
        h.elapse(const Duration(seconds: 21));
        h.push(frame('mm.status', {'waited_s': 3}, 'u'));
        h.elapse(const Duration(seconds: 21));
        expect(first.isClosed, isFalse);

        h.elapse(const Duration(seconds: 1));
        expect(first.closedByClient, isTrue);
        h.dispose();
      });
    });

    test('uses the in-match heartbeat while a match lease is held', () {
      fakeAsync((async) {
        final h = Harness(async, autoClockPong: false)..open(inMatch: true);
        final first = h.socket;
        expect(h.connection.heartbeatTimeout, const Duration(seconds: 12));

        h.elapseMs(11999);
        expect(first.isClosed, isFalse);
        h.elapseMs(1);
        expect(first.closedByClient, isTrue);
        h.dispose();
      });
    });

    test('switches the watchdog when a match lease comes and goes', () {
      fakeAsync((async) {
        final h = Harness(async, autoClockPong: false)..open();
        final first = h.socket;

        h.elapse(const Duration(seconds: 5));
        final match = h.connection.acquire('match:M1', inMatch: true);
        h.elapseMs(6999);
        expect(first.isClosed, isFalse);
        match.release();
        h.elapse(const Duration(seconds: 10));
        expect(first.isClosed, isFalse, reason: 'back to 22 s without the match lease');
        h.elapse(const Duration(seconds: 1));
        expect(first.closedByClient, isTrue);
        h.dispose();
      });
    });
  });

  group('clock sync', () {
    test('takes 5 samples after welcome, one at a time', () {
      fakeAsync((async) {
        final h = Harness(async, autoClockPong: false);
        final pings = <int>[];
        h.onMessage = (socket, message) {
          if (message['t'] != 'clock.ping') return;
          final c0 = (message['d']! as Map<String, Object?>)['c0']! as int;
          pings.add(c0);
        };
        h.open();

        for (var i = 0; i < 5; i++) {
          expect(pings, hasLength(i + 1), reason: 'the next ping waits for the pong');
          h.elapseMs(40);
          h.push(frame('clock.pong', {'c0': pings.last, 's': h.serverNowMs - 20}));
        }

        expect(pings, hasLength(5));
        expect(h.connection.serverClock.isSynced, isTrue);
        expect(h.connection.serverClock.nowServerMs(), h.serverNowMs);
        h.dispose();
      });
    });

    test('keeps the lowest round trip and drops pongs slower than 1 s', () {
      fakeAsync((async) {
        final h = Harness(async, autoClockPong: false);
        // Each ping reaches the server after `up` ms and the pong returns `down` ms later.
        final trips = [(100, 200), (60, 60), (700, 800), (30, 50), (100, 100)];
        var ping = 0;
        h.onMessage = (socket, message) {
          if (message['t'] != 'clock.ping') return;
          final (up, down) = trips[ping++];
          final c0 = (message['d']! as Map<String, Object?>)['c0'];
          Timer(Duration(milliseconds: up), () {
            final s = h.serverNowMs;
            Timer(Duration(milliseconds: down), () {
              socket.push(frame('clock.pong', {'c0': c0, 's': s}));
            });
          });
        };
        h.connection.acquire('battle-tab');
        h.flush();
        h.elapse(const Duration(seconds: 5));

        expect(ping, 5);
        final clock = h.connection.serverClock;
        expect(clock.sample!.rttMs, 80);
        // Server time = monotonic + (epoch − monotonic base); the 30/50 split is off by −10 ms.
        expect(clock.offsetMs, Harness.serverEpochMs - h.clock.monotonicBase - 10);
        expect(h.logs, contains(startsWith('Clock synced')));
        h.dispose();
      });
    });

    test('re-syncs every 60 s in a match, every 5 min when idle, and after every reconnect', () {
      fakeAsync((async) {
        final h = Harness(async, hbS: 30)..open();
        int pings() => h.connector.sockets.fold(0, (n, s) => n + s.sentOfType('clock.ping').length);
        // The server's heartbeat: every 30 s when idle, every 5 s in a match.
        void run(int seconds, {int every = 30}) {
          for (var t = 0; t < seconds; t += every) {
            h.elapse(Duration(seconds: every));
            h.push(frame('ping', {'n': t}, 'u'));
          }
        }

        expect(pings(), 5);
        run(270);
        expect(pings(), 5, reason: 'idle: nothing before 5 minutes');
        run(30);
        expect(pings(), 10);

        // Entering a match with a clock synced 100 s ago syncs at once, then every 60 s.
        run(90);
        final match = h.connection.acquire('match:M1', inMatch: true);
        h.flush();
        expect(pings(), 15);
        run(55, every: 5);
        expect(pings(), 15);
        run(5, every: 5);
        expect(pings(), 20);

        // Back to idle: the next sync is 5 minutes after the last one.
        match.release();
        run(240);
        expect(pings(), 20);
        run(60);
        expect(pings(), 25);

        h.socket.closeFromServer(1013);
        h.flush();
        h.elapse(h.retryIn);
        expect(h.connector.sockets.last.sentOfType('clock.ping'), hasLength(5));
        expect(pings(), 30);
        h.dispose();
      });
    });

    test('an idle connection only answers pings between clock syncs', () {
      fakeAsync((async) {
        final h = Harness(async, hbS: 30)..open();
        final socket = h.socket;
        for (var n = 1; n <= 20; n++) {
          h.elapse(const Duration(seconds: 30));
          h.push(frame('ping', {'n': n}, 'u'));
        }

        final sentTypes = socket.sent.map((m) => m['t']).toList();
        expect(sentTypes.where((t) => t == 'pong'), hasLength(20));
        expect(
          sentTypes.where((t) => t == 'clock.ping'),
          hasLength(15),
          reason: 'at 0, 5 and 10 min',
        );
        expect(sentTypes.toSet(), {'hello', 'clock.ping', 'pong'});
        expect(h.connection.heartbeatTimeout, const Duration(seconds: 62));
        expect(h.state, isA<Open>());
        h.dispose();
      });
    });

    test('seeds the clock from welcome until the first sync finishes', () {
      fakeAsync((async) {
        final h = Harness(async, autoClockPong: false);
        h.open();

        final clock = h.connection.serverClock;
        expect(clock.isSynced, isFalse);
        expect(clock.nowServerMs(), h.serverNowMs);
        h.dispose();
      });
    });
  });

  group('app state and takeover', () {
    test('sends client.state when it changes, and again after every welcome', () {
      fakeAsync((async) {
        final h = Harness(async);
        h.connection.setAppForeground(true);
        h.open();
        List<Object?> states(FakeSocket socket) => [
          for (final m in socket.sentOfType('client.state'))
            (m['d']! as Map<String, Object?>)['state'],
        ];

        final first = h.socket;
        expect(first.sent[1]['t'], 'client.state', reason: 'right after welcome');
        expect(states(first), ['foreground']);

        h.connection
          ..setAppForeground(false)
          ..setAppForeground(false);
        h.flush();
        expect(states(first), ['foreground', 'background']);

        first.closeFromServer(1012);
        h.flush();
        h.elapse(h.retryIn);
        expect(states(h.socket), ['background']);
        h.dispose();
      });
    });

    test('LIVE_ELSEWHERE then 4409 is terminal liveElsewhere, and takeover reconnects', () {
      fakeAsync((async) {
        final h = Harness(async, autoWelcome: false);
        h.onMessage = (socket, message) {
          if (message['t'] != 'hello') return;
          final hello = message['d']! as Map<String, Object?>;
          if (hello['takeover'] == true) {
            socket.push(frame('welcome', welcomeData(serverMs: h.serverNowMs), 'u'));
          } else {
            socket
              ..push(
                frame('error', {
                  'ref': message['id'],
                  'code': 'LIVE_ELSEWHERE',
                  'message': 'You are playing on another device.',
                  'details': {'match_id': 'M3'},
                }),
              )
              ..closeFromServer(4409);
          }
        };
        h.connection.acquire('shell');
        h.flush();

        expect(h.state, isA<Terminal>());
        final reason = (h.state as Terminal).reason;
        expect(reason, const TerminalReason.liveElsewhere('M3'));
        expect(reason, isA<LiveElsewhere>().having((r) => r.matchId, 'matchId', 'M3'));
        expect(h.socket.sentOfType('hello').single['d'], isNot(contains('takeover')));
        h.elapse(const Duration(minutes: 1));
        expect(h.connector.attempts, 1, reason: 'no retry until the user decides');

        h.connection.connect(takeover: true);
        h.flush();
        expect(h.state, isA<Open>());
        expect(h.socket.sentOfType('hello').single['d'], containsPair('takeover', true));

        // The takeover applies to that handshake only.
        h.socket.closeFromServer(1013);
        h.flush();
        h.elapse(h.retryIn);
        expect(h.socket.sentOfType('hello').single['d'], isNot(contains('takeover')));
        h.dispose();
      });
    });

    test('asking for a takeover while open changes nothing', () {
      fakeAsync((async) {
        final h = Harness(async)..open();

        h.connection.connect(takeover: true);
        h.socket.closeFromServer(1013);
        h.flush();
        h.elapse(h.retryIn);

        expect(h.socket.sentOfType('hello').single['d'], isNot(contains('takeover')));
        h.dispose();
      });
    });

    test('a plain 4409 is still superseded', () {
      fakeAsync((async) {
        final h = Harness(async)..open();

        h.socket.closeFromServer(4409);
        h.flush();

        expect(
          h.state,
          isA<Terminal>().having((s) => s.reason, 'reason', TerminalReason.superseded),
        );
        h.dispose();
      });
    });

    test('connect() skips a pending backoff and does nothing without a lease', () {
      fakeAsync((async) {
        final h = Harness(async, random: MaxRandom());
        h.connection.connect();
        h.flush();
        expect(h.state, isA<Idle>());

        h.connector.failures.addAll([StateError('down'), StateError('down'), StateError('down')]);
        h.connection.acquire('shell');
        h.flush();
        h.elapse(h.retryIn);
        h.elapse(h.retryIn);
        expect(h.retryIn, const Duration(seconds: 2));

        h.connection.connect();
        h.flush();
        expect(h.state, isA<Open>());
        h.dispose();
      });
    });
  });

  group('incoming frames', () {
    test('drops malformed frames, counts them and keeps going', () {
      fakeAsync((async) {
        final h = Harness(async)..open();

        h.socket
          ..pushRaw('not json')
          ..pushRaw([1, 2, 3])
          ..push({
            'v': 2,
            't': 'ping',
            'd': {'n': 1},
          })
          ..push(frame('q.show', {'q': 1}, 'm:M1', 1));
        h.flush();

        expect(h.connection.protocolErrors, 4);
        expect(h.state, isA<Open>());
        expect(h.events, isEmpty);
        expect(h.logs.where((l) => l.startsWith('Dropped a bad frame')), hasLength(4));

        h.push(frame('q.progress', {'q': 1, 'answered': <String>[]}, 'm:M1', 1));
        expect(h.events.single, isA<QProgressEvent>(), reason: 'the bad seq 1 was not consumed');
        h.dispose();
      });
    });

    test('delivers unknown message types for consumers to ignore', () {
      fakeAsync((async) {
        final h = Harness(async)..open();

        h.push(frame('lb.update', {'rows': <Object?>[]}, 'u'));

        expect(h.events.single, isA<UnknownEvent>().having((e) => e.type, 'type', 'lb.update'));
        h.dispose();
      });
    });

    test('dispose closes the socket and fails pending work', () {
      fakeAsync((async) {
        final h = Harness(async)..open();
        final ready = Outcome(h.connection.request('match.ready', {'match_id': 'M1'}));
        final answer = Outcome(h.connection.submitAnswer('M1', 1, 'a', 100));
        final socket = h.socket;

        h.dispose();

        expect(socket.closedByClient, isTrue);
        expect(ready.realtimeError.code, RealtimeErrorCode.closed);
        expect(answer.realtimeError.code, RealtimeErrorCode.closed);
        expect(
          Outcome(h.connection.request('mm.cancel', {})).isPending,
          isTrue,
          reason: 'fails asynchronously',
        );
        h.flush();
      });
    });
  });
}
