/// Timings and limits for [RealtimeConnection]. The defaults follow docs/protocol.md.
final class RealtimeConfig {
  const RealtimeConfig({
    this.helloTimeout = const Duration(seconds: 5),
    this.ticketTimeout = const Duration(seconds: 15),
    this.connectTimeout = const Duration(seconds: 10),
    this.linger = const Duration(seconds: 30),
    this.backoffBase = const Duration(milliseconds: 500),
    this.backoffCap = const Duration(seconds: 10),
    this.matchBackoffCap = const Duration(seconds: 2),
    this.restartJitter = const Duration(seconds: 2),
    this.rateLimitWait = const Duration(seconds: 10),
    this.matchHeartbeat = const Duration(seconds: 5),
    this.answerResendAfter = const Duration(seconds: 2),
    this.requestTimeout = const Duration(seconds: 10),
    this.clockResyncEvery = const Duration(seconds: 60),
    this.idleClockResyncEvery = const Duration(minutes: 5),
    this.clockSamples = 5,
    this.clockMaxRtt = const Duration(seconds: 1),
    this.syncRetryAfter = const Duration(seconds: 3),
    this.maxGapBuffer = 256,
  });

  /// How long to wait for `welcome` after sending `hello`.
  final Duration helloTimeout;

  /// How long the ticket request may take before the attempt backs off.
  final Duration ticketTimeout;

  /// How long opening the socket may take.
  final Duration connectTimeout;

  /// How long the socket stays open after the last lease is released.
  final Duration linger;

  /// The backoff window for attempt 0; it doubles per attempt.
  final Duration backoffBase;

  /// The largest backoff window.
  final Duration backoffCap;

  /// The largest backoff window while a lease with `inMatch` is held.
  final Duration matchBackoffCap;

  /// After close code 1012 (server restarting), reconnect after a random 0 to this.
  final Duration restartJitter;

  /// After close code 4429 (rate limited), wait this long.
  final Duration rateLimitWait;

  /// The server's heartbeat interval during a match. With an `inMatch` lease the watchdog uses it
  /// in `2 × hb + 2 s` when it is shorter than `welcome.hb_s`.
  final Duration matchHeartbeat;

  /// Resend an unacknowledged answer after this long.
  final Duration answerResendAfter;

  /// The default timeout for [RealtimeConnection.request].
  final Duration requestTimeout;

  /// Clock sync interval while a lease with `inMatch` is held. A sync also runs after every
  /// `welcome`, and at once when a match lease arrives and the last sync is older than this.
  final Duration clockResyncEvery;

  /// Clock sync interval on an idle connection (no match lease), which the app may keep open for
  /// as long as it is in the foreground. Longer, so an idle socket stays cheap.
  final Duration idleClockResyncEvery;

  /// Pings per clock sync.
  final int clockSamples;

  /// Clock samples with a longer round trip are discarded, and a ping without a pong for this long
  /// counts as lost.
  final Duration clockMaxRtt;

  /// While a `sync` for a gap is outstanding, send another if the gap is still open after this.
  final Duration syncRetryAfter;

  /// Out-of-order events held per channel while a gap is being filled.
  final int maxGapBuffer;
}
