import 'dart:math';

import 'package:fake_async/fake_async.dart';
import 'package:realtime_client/realtime_client.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';
import 'support/frames.dart';
import 'support/harness.dart';

void main() {
  /// Makes the next [count] connects fail, then collects the delay of each resulting backoff.
  List<int> failingDelays(Harness h, int count, {bool inMatch = false}) {
    h.connector.failures.addAll([for (var i = 0; i < count; i++) StateError('down')]);
    h.connection.acquire('test', inMatch: inMatch);
    final delays = <int>[];
    for (var i = 0; i < count; i++) {
      h.flush();
      final state = h.state as Backoff;
      expect(state.attempt, i);
      delays.add(h.retryIn.inMilliseconds);
      h.elapse(h.retryIn);
    }
    h.flush();
    return delays;
  }

  group('backoff', () {
    test('full jitter stays within 0 and min(10 s, 500 ms × 2^attempt)', () {
      for (final seed in [1, 2, 3]) {
        fakeAsync((async) {
          final h = Harness(async, random: Random(seed));
          final delays = failingDelays(h, 9);

          for (final (attempt, delay) in delays.indexed) {
            expect(delay, inInclusiveRange(0, min(10000, 500 * pow(2, attempt))));
          }
          expect(delays.toSet(), hasLength(greaterThan(1)), reason: 'the delays are random');
          expect(h.state, isA<Open>());
          h.dispose();
        });
      }
    });

    test('the window doubles from 500 ms up to the 10 s cap', () {
      fakeAsync((async) {
        final h = Harness(async, random: MaxRandom());

        expect(failingDelays(h, 8), [500, 1000, 2000, 4000, 8000, 10000, 10000, 10000]);
        h.dispose();
      });
    });

    test('the cap is 2 s while a match lease is held', () {
      fakeAsync((async) {
        final h = Harness(async, random: MaxRandom());

        expect(failingDelays(h, 5, inMatch: true), [500, 1000, 2000, 2000, 2000]);
        h.dispose();
      });
    });

    test('retries exactly when the delay is up', () {
      fakeAsync((async) {
        final h = Harness(async, random: MaxRandom())..connector.failures.add(StateError('x'));
        h.connection.acquire('test');
        h.flush();
        expect(h.connector.attempts, 1);

        h.elapseMs(499);
        expect(h.connector.attempts, 1);
        h.elapseMs(1);
        expect(h.connector.attempts, 2);
        h.dispose();
      });
    });

    test('resets after a successful welcome', () {
      fakeAsync((async) {
        final h = Harness(async, random: MaxRandom());
        expect(failingDelays(h, 4), [500, 1000, 2000, 4000]);
        expect(h.state, isA<Open>());

        h.socket.closeFromServer(1013);
        h.flush();

        expect(h.state, isA<Backoff>().having((s) => s.attempt, 'attempt', 0));
        expect(h.retryIn, const Duration(milliseconds: 500));
        h.dispose();
      });
    });

    test('a match that starts during a long backoff brings the retry within 2 s', () {
      fakeAsync((async) {
        final h = Harness(async, random: MaxRandom());
        failingDelays(h, 0);
        h.connector.failures.addAll([for (var i = 0; i < 5; i++) StateError('down')]);
        h.socket.closeFromServer(1013);
        for (var i = 0; i < 5; i++) {
          h.flush();
          h.elapse(h.retryIn);
        }
        h.flush();
        expect(h.retryIn, const Duration(seconds: 10));

        h.connection.acquire('match:M1', inMatch: true);
        expect(h.retryIn, const Duration(seconds: 2));
        h.elapse(const Duration(seconds: 2));
        expect(h.state, isA<Open>());
        h.dispose();
      });
    });
  });

  group('network availability', () {
    test('pauses while offline and retries at once when the network returns', () {
      fakeAsync((async) {
        final h = Harness(async)..open();
        h.network.add(false);
        h.flush();
        expect(h.state, isA<Open>(), reason: 'an open socket is left alone');

        h.socket.closeFromServer();
        h.flush();
        expect(h.state, isA<Backoff>().having((s) => s.waitingForNetwork, 'offline', isTrue));

        final attempts = h.connector.attempts;
        h.elapse(const Duration(minutes: 5));
        expect(h.connector.attempts, attempts);
        expect(h.state, isA<Backoff>().having((s) => s.retryAt, 'retryAt', isNull));

        h.network.add(true);
        h.flush();
        expect(h.connector.attempts, attempts + 1);
        expect(h.state, isA<Open>());
        h.dispose();
      });
    });

    test('losing the network cancels a scheduled retry', () {
      fakeAsync((async) {
        final h = Harness(async, random: MaxRandom())..open();
        h.socket.closeFromServer(1013);
        h.flush();
        expect(h.retryIn, const Duration(milliseconds: 500));

        h.network.add(false);
        h.flush();
        h.elapse(const Duration(seconds: 10));
        expect(h.connector.sockets, hasLength(1));
        expect(h.state, isA<Backoff>().having((s) => s.waitingForNetwork, 'offline', isTrue));

        h.network.add(true);
        h.flush();
        expect(h.state, isA<Open>());
        expect(h.connector.sockets, hasLength(2));
        h.dispose();
      });
    });

    test('does not even try while offline', () {
      fakeAsync((async) {
        final h = Harness(async);
        h.network.add(false);
        h.flush();

        h.connection.acquire('battle-tab');
        h.flush();
        expect(h.state, isA<Backoff>().having((s) => s.waitingForNetwork, 'offline', isTrue));
        expect(h.tickets, isEmpty);

        h.network.add(true);
        h.flush();
        expect(h.state, isA<Open>());
        h.dispose();
      });
    });
  });

  group('close codes', () {
    /// Opens, closes from the server with [code], and returns the harness right after.
    Harness closedWith(FakeAsync async, int? code, {Random? random}) {
      final h = Harness(async, random: random ?? MaxRandom())..open();
      h.socket.closeFromServer(code);
      h.flush();
      return h;
    }

    for (final code in [1000, 1013, 4400, 4408, 4999, null]) {
      test('${code ?? 'a drop without a close code'} reconnects with backoff', () {
        fakeAsync((async) {
          final h = closedWith(async, code);

          expect(h.state, isA<Backoff>().having((s) => s.attempt, 'attempt', 0));
          expect(h.retryIn, const Duration(milliseconds: 500));
          h.elapse(h.retryIn);
          expect(h.state, isA<Open>());
          expect(h.tickets, ['t1', 't2']);
          h.dispose();
        });
      });
    }

    test('1012 reconnects after a random 0 to 2 s, without counting an attempt', () {
      fakeAsync((async) {
        final h = closedWith(async, 1012);
        expect(h.state, isA<Backoff>().having((s) => s.attempt, 'attempt', 0));
        expect(h.retryIn, const Duration(seconds: 2));

        h.connector.failures.add(StateError('still restarting'));
        h.elapse(h.retryIn);
        h.flush();
        expect(h.state, isA<Backoff>().having((s) => s.attempt, 'attempt', 0));
        expect(h.retryIn, const Duration(milliseconds: 500));
        h.dispose();
      });

      fakeAsync((async) {
        final h = closedWith(async, 1012, random: ZeroRandom());
        expect(h.retryIn, Duration.zero);
        h.dispose();
      });
    });

    test('4401 fetches a new ticket and reconnects at once, then backs off if it repeats', () {
      fakeAsync((async) {
        final h = Harness(async, random: MaxRandom(), autoWelcome: false);
        var rejections = 2;
        h.onMessage = (socket, message) {
          if (message['t'] != 'hello') return;
          if (rejections-- > 0) {
            socket.closeFromServer(4401);
          } else {
            socket.push(frame('welcome', welcomeData(serverMs: h.serverNowMs), 'u'));
          }
        };

        h.connection.acquire('battle-tab');
        h.flush();
        expect(h.tickets, ['t1', 't2'], reason: 't1 was rejected, so t2 went out at once');
        expect(h.states, [
          isA<Ticketing>(),
          isA<Connecting>(),
          isA<Ticketing>(),
          isA<Connecting>(),
          isA<Backoff>().having((s) => s.attempt, 'attempt', 0),
        ]);
        expect(h.retryIn, const Duration(milliseconds: 500));

        h.elapse(h.retryIn);
        expect(h.state, isA<Open>());
        expect(h.tickets, ['t1', 't2', 't3']);
        h.dispose();
      });
    });

    final terminal = {
      4403: TerminalReason.revoked,
      4409: TerminalReason.superseded,
      4426: TerminalReason.updateRequired,
    };
    for (final MapEntry(key: code, value: reason) in terminal.entries) {
      test('$code is terminal: $reason', () {
        fakeAsync((async) {
          final h = closedWith(async, code);

          expect(h.state, isA<Terminal>().having((s) => s.reason, 'reason', reason));
          h.elapse(const Duration(minutes: 10));
          expect(h.connector.attempts, 1, reason: 'never reconnects on its own');

          final request = Outcome(h.connection.request('mm.cancel', {}));
          final answer = Outcome(h.connection.submitAnswer('M1', 1, 'a', 10));
          h.flush();
          expect(request.realtimeError.code, RealtimeErrorCode.closed);
          expect(answer.realtimeError.code, RealtimeErrorCode.closed);

          // The app decides, for example after the user signs in again.
          h.connection.connect();
          h.flush();
          expect(h.state, isA<Open>());
          h.dispose();
        });
      });
    }

    test('answers pending when the connection turns terminal fail with CLOSED', () {
      fakeAsync((async) {
        final h = Harness(async)..open();
        final answer = Outcome(h.connection.submitAnswer('M1', 1, 'a', 10));
        h.flush();

        h.socket.closeFromServer(4403);
        h.flush();

        expect(answer.realtimeError.code, RealtimeErrorCode.closed);
        expect(h.connection.pendingAnswers, 0);
        h.dispose();
      });
    });

    test('4429 waits 10 s, even if the network flaps meanwhile', () {
      fakeAsync((async) {
        final h = closedWith(async, 4429, random: ZeroRandom());
        expect(h.state, isA<Backoff>());
        expect(h.retryIn, const Duration(seconds: 10));

        h.elapse(const Duration(seconds: 4));
        h.network.add(false);
        h.flush();
        h.network.add(true);
        h.flush();
        expect(h.connector.attempts, 1);
        expect(h.retryIn, const Duration(seconds: 6));

        h.elapseMs(5999);
        expect(h.connector.attempts, 1);
        h.elapseMs(1);
        expect(h.connector.attempts, 2);
        expect(h.state, isA<Open>());
        h.dispose();
      });
    });
  });
}
