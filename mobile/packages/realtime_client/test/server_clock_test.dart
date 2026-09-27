import 'package:realtime_client/realtime_client.dart';
import 'package:test/test.dart';

/// A monotonic clock the test moves by hand.
final class ManualClock {
  int nowMs = 1000;

  int call() => nowMs;
}

/// Server time is client monotonic time plus this.
const trueOffset = 1789999000000;

void main() {
  late ManualClock mono;
  late ServerClock clock;

  setUp(() {
    mono = ManualClock();
    clock = ServerClock(monotonicMs: mono.call);
  });

  /// One ping/pong exchange: the ping reaches the server after [upMs], and the pong comes back
  /// after [downMs]. Asymmetric trips make the offset estimate off by (upMs − downMs) / 2.
  bool sample(int upMs, int downMs) {
    final c0 = mono.nowMs;
    final serverMs = c0 + upMs + trueOffset;
    mono.nowMs += upMs + downMs;
    final kept = clock.addSample(c0: c0, serverMs: serverMs);
    mono.nowMs += 50;
    return kept;
  }

  group('ClockSample', () {
    test('offset = s − (c0 + rtt / 2)', () {
      const sample = ClockSample(c0: 1000, serverMs: 1790000000150, c1: 1200);

      expect(sample.rttMs, 200);
      expect(sample.offsetMs, 1790000000150 - (1000 + 100));
    });

    test('rounds half-millisecond offsets', () {
      const sample = ClockSample(c0: 0, serverMs: 1000, c1: 101);

      expect(sample.offsetMs, (1000 - 50.5).round());
    });
  });

  group('ServerClock', () {
    test('has no offset before a sync, and falls back to monotonic time', () {
      expect(clock.offsetMs, isNull);
      expect(clock.isSynced, isFalse);
      expect(clock.nowServerMs(), mono.nowMs);
    });

    test('keeps the lowest-RTT sample of 5', () {
      clock.startSync();
      expect(sample(150, 150), isTrue); // rtt 300, exact
      expect(sample(60, 20), isTrue); // rtt 80, off by +20
      expect(sample(100, 20), isTrue); // rtt 120, off by +40
      expect(clock.offsetMs, isNull, reason: 'the offset changes only when the sync ends');
      expect(sample(40, 50), isTrue); // rtt 90
      expect(clock.isSyncing, isTrue);
      expect(sample(200, 250), isTrue); // rtt 450

      expect(clock.isSyncing, isFalse);
      expect(clock.isSynced, isTrue);
      expect(clock.sample!.rttMs, 80);
      expect(clock.offsetMs, trueOffset + 20);
      expect(clock.nowServerMs(), mono.nowMs + trueOffset + 20);
    });

    test('discards samples with a round trip above 1 s', () {
      clock.startSync();
      expect(sample(500, 501), isFalse); // rtt 1001
      expect(sample(700, 700), isFalse);
      expect(sample(600, 400), isTrue); // rtt 1000 is still fine
      expect(sample(900, 900), isFalse);
      expect(sample(2000, 10), isFalse);

      expect(clock.sample!.rttMs, 1000);
      expect(clock.offsetMs, trueOffset + 100);
    });

    test('keeps the previous offset when every sample is too slow', () {
      clock.startSync();
      for (var i = 0; i < 5; i++) {
        sample(10, 10);
      }
      final synced = clock.offsetMs;

      clock.startSync();
      for (var i = 0; i < 5; i++) {
        expect(sample(800, 800), isFalse);
      }

      expect(clock.isSyncing, isFalse);
      expect(clock.offsetMs, synced);
    });

    test('each sync replaces the offset with its own best sample', () {
      clock.startSync();
      for (var i = 0; i < 5; i++) {
        sample(10, 10);
      }
      expect(clock.offsetMs, trueOffset);

      // The clocks drifted; a later sync with slower samples still wins.
      mono.nowMs += 60000;
      clock.startSync();
      for (var i = 0; i < 5; i++) {
        sample(100, 60);
      }
      expect(clock.sample!.rttMs, 160);
      expect(clock.offsetMs, trueOffset + 20);
    });

    test('lost pings count towards the 5', () {
      clock.startSync();
      clock
        ..addLostSample()
        ..addLostSample();
      sample(30, 30);
      clock.addLostSample();
      expect(clock.isSyncing, isTrue);
      clock.addLostSample();

      expect(clock.isSyncing, isFalse);
      expect(clock.offsetMs, trueOffset);
    });

    test('ignores samples outside a sync, and negative round trips', () {
      expect(clock.addSample(c0: 1, serverMs: 2), isFalse);

      clock.startSync();
      expect(clock.addSample(c0: mono.nowMs + 5, serverMs: 2), isFalse);
    });

    test('finishSync applies the best sample so far', () {
      clock.startSync();
      sample(20, 20);
      clock.finishSync();

      expect(clock.isSyncing, isFalse);
      expect(clock.offsetMs, trueOffset);
    });

    test('a seed gives a rough offset until the first sync', () {
      clock.seed(mono.nowMs + trueOffset + 35);
      expect(clock.offsetMs, trueOffset + 35);
      expect(clock.isSynced, isFalse);

      clock.startSync();
      for (var i = 0; i < 5; i++) {
        sample(10, 10);
      }
      clock.seed(0);

      expect(clock.offsetMs, trueOffset);
    });

    test('converts between monotonic and server time', () {
      clock.startSync();
      for (var i = 0; i < 5; i++) {
        sample(10, 10);
      }

      expect(clock.toServerMs(5000), 5000 + trueOffset);
      expect(clock.toMonotonicMs(5000 + trueOffset), 5000);
    });
  });
}
