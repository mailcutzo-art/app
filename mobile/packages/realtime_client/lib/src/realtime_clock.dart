import 'dart:async';

/// The time source and timers the connection uses. Inject a fake one in tests.
///
/// The default [SystemRealtimeClock] creates ordinary zone timers, so it already works under
/// `fake_async` for timers; only [monotonicMs] and [now] need faking.
abstract interface class RealtimeClock {
  /// Milliseconds on a clock that never goes backwards. The origin is arbitrary.
  int get monotonicMs;

  /// Wall-clock time, used only for display values such as `Backoff.retryAt`.
  DateTime now();

  /// Runs [callback] once after [duration].
  Timer timer(Duration duration, void Function() callback);

  /// Runs [callback] every [period].
  Timer periodic(Duration period, void Function(Timer timer) callback);
}

/// The real clock: a [Stopwatch] for monotonic time and [Timer] for timers.
///
/// Monotonic time is anchored to the wall clock when the clock is created, so before the first
/// clock sync, monotonic time is roughly Unix ms and makes a sane server-time fallback.
final class SystemRealtimeClock implements RealtimeClock {
  SystemRealtimeClock() : _originMs = DateTime.now().millisecondsSinceEpoch;

  final int _originMs;
  final Stopwatch _stopwatch = Stopwatch()..start();

  @override
  int get monotonicMs => _originMs + _stopwatch.elapsedMilliseconds;

  @override
  DateTime now() => DateTime.now();

  @override
  Timer timer(Duration duration, void Function() callback) => Timer(duration, callback);

  @override
  Timer periodic(Duration period, void Function(Timer timer) callback) =>
      Timer.periodic(period, callback);
}
