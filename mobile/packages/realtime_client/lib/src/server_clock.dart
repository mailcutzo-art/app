/// One `clock.ping` / `clock.pong` round trip, all in ms.
final class ClockSample {
  const ClockSample({required this.c0, required this.serverMs, required this.c1});

  /// Client monotonic time when the ping was sent.
  final int c0;

  /// Server time in the pong (`s`).
  final int serverMs;

  /// Client monotonic time when the pong arrived.
  final int c1;

  int get rttMs => c1 - c0;

  /// `offset = s − (c0 + rtt / 2)`: add it to monotonic time to get server time. Assumes the
  /// server answered halfway through the round trip.
  int get offsetMs => (serverMs - (c0 + rttMs / 2)).round();

  @override
  String toString() => 'ClockSample(rtt: $rttMs ms, offset: $offsetMs ms)';
}

/// Maps the client's monotonic clock to server time (docs/protocol.md section 3).
///
/// A sync takes [samplesPerSync] `clock.ping` samples, drops any with a round trip above
/// [maxRttMs], and keeps the one with the lowest round trip. The connection drives the pings:
/// [startSync], then [addSample] or [addLostSample] once per ping until [isSyncing] is false.
///
/// All times come from the injected monotonic source, so the class is deterministic in tests.
final class ServerClock {
  ServerClock({required this._monotonicMs, this.samplesPerSync = 5, this.maxRttMs = 1000})
    : assert(samplesPerSync > 0, 'a sync needs at least one sample');

  final int Function() _monotonicMs;

  /// How many pings one sync sends.
  final int samplesPerSync;

  /// Samples with a longer round trip are discarded.
  final int maxRttMs;

  int? _offsetMs;
  ClockSample? _sample;
  bool _syncing = false;
  int _attempts = 0;
  ClockSample? _roundBest;

  /// Client monotonic time now.
  int get monotonicMs => _monotonicMs();

  /// Server time now: monotonic time plus the offset.
  ///
  /// Before any estimate exists the offset is 0, so this returns monotonic time. With the default
  /// [RealtimeClock] that is anchored to the wall clock at startup, which is a sane fallback.
  int nowServerMs() => toServerMs(_monotonicMs());

  /// Converts a client monotonic time to server time.
  int toServerMs(int monotonicMs) => monotonicMs + (_offsetMs ?? 0);

  /// Converts a server time to client monotonic time, for scheduling local timers.
  int toMonotonicMs(int serverMs) => serverMs - (_offsetMs ?? 0);

  /// The current offset, or `null` before the first estimate.
  int? get offsetMs => _offsetMs;

  /// Whether a sync has produced an offset. [seed] alone doesn't count.
  bool get isSynced => _sample != null;

  /// The sample behind the current offset.
  ClockSample? get sample => _sample;

  /// Whether a sync is collecting samples.
  bool get isSyncing => _syncing;

  /// Takes a rough offset from a server timestamp received just now (for example
  /// `welcome.server_ms`), ignoring the round trip. Does nothing once a sync has succeeded.
  void seed(int serverMs) {
    if (isSynced) return;
    _offsetMs = serverMs - _monotonicMs();
  }

  /// Starts a sync. Restarting one that is running discards its samples.
  void startSync() {
    _syncing = true;
    _attempts = 0;
    _roundBest = null;
  }

  /// Records the pong for a ping sent at monotonic time [c0], carrying server time [serverMs].
  ///
  /// Returns whether the sample was kept: it must belong to a running sync and have a round trip
  /// between 0 and [maxRttMs]. The sync finishes after [samplesPerSync] samples.
  bool addSample({required int c0, required int serverMs}) {
    if (!_syncing) return false;
    final sample = ClockSample(c0: c0, serverMs: serverMs, c1: _monotonicMs());
    final kept = sample.rttMs >= 0 && sample.rttMs <= maxRttMs;
    final best = _roundBest;
    if (kept && (best == null || sample.rttMs < best.rttMs)) _roundBest = sample;
    _countAttempt();
    return kept;
  }

  /// Records a ping that got no pong in time. It counts towards the sync's samples.
  void addLostSample() {
    if (_syncing) _countAttempt();
  }

  /// Ends the running sync now, applying the best sample so far if there is one.
  void finishSync() {
    if (!_syncing) return;
    _syncing = false;
    final best = _roundBest;
    _roundBest = null;
    if (best == null) return;
    _sample = best;
    _offsetMs = best.offsetMs;
  }

  void _countAttempt() {
    _attempts++;
    if (_attempts >= samplesPerSync) finishSync();
  }
}
