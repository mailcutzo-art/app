import 'events.dart';

/// The connection manager's state.
///
/// ```
/// Idle ─lease─► Ticketing ─► Connecting ─welcome─► Open
///                   ▲             │                  │ drop / close code
///                   └── Backoff ◄─┴──────────────────┘
/// Terminal: revoked (4403), superseded (4409), updateRequired (4426)
/// ```
sealed class ConnState {
  const ConnState();
}

/// No lease is held (or the 30 s linger ran out), so there is no socket.
final class Idle extends ConnState {
  const Idle();

  @override
  String toString() => 'Idle';
}

/// Fetching a ticket over REST.
final class Ticketing extends ConnState {
  const Ticketing();

  @override
  String toString() => 'Ticketing';
}

/// Opening the socket and waiting for `welcome`.
final class Connecting extends ConnState {
  const Connecting();

  @override
  String toString() => 'Connecting';
}

/// Connected. [welcome] carries `active`, for jumping back into games.
final class Open extends ConnState {
  const Open(this.welcome);

  final WelcomeEvent welcome;

  @override
  String toString() => 'Open(${welcome.userId})';
}

/// Waiting to reconnect.
///
/// [attempt] counts the failed attempts since the last `welcome`, starting at 0. The delay is
/// drawn from 0 to min(cap, 500 ms × 2^attempt), except after close code 1012 (0 to 2 s) and 4429
/// (10 s). [retryAt] is `null` while the device is offline: the retry then waits for the network
/// to come back.
final class Backoff extends ConnState {
  const Backoff({required this.attempt, required this.retryAt});

  final int attempt;
  final DateTime? retryAt;

  /// Whether the retry is paused until the network returns.
  bool get waitingForNetwork => retryAt == null;

  @override
  String toString() => 'Backoff(attempt: $attempt, retryAt: ${retryAt ?? 'when online'})';
}

/// The server ended the session for good. Nothing reconnects until
/// `RealtimeConnection.connect` is called.
final class Terminal extends ConnState {
  const Terminal(this.reason);

  final TerminalReason reason;

  @override
  String toString() => 'Terminal($reason)';
}

/// Why a connection became [Terminal]:
/// [TerminalReason.revoked], [TerminalReason.superseded], [TerminalReason.updateRequired] or
/// [TerminalReason.liveElsewhere].
sealed class TerminalReason {
  const TerminalReason();

  /// 4403: the session was revoked or the account banned. Go to sign-in.
  static const revoked = Revoked();

  /// 4409: a newer connection replaced this one. Show "Playing on another device".
  static const superseded = Superseded();

  /// 4426: the app is too old. Show the update screen.
  static const updateRequired = UpdateRequired();

  /// 4409 after a `LIVE_ELSEWHERE` error: another device is in a live match, and this connection
  /// did not take it over. Ask "Move the game here?", then `connect(takeover: true)`.
  const factory TerminalReason.liveElsewhere(String? matchId) = LiveElsewhere;

  /// A short name for logs.
  String get name;

  @override
  String toString() => name;
}

/// See [TerminalReason.revoked].
final class Revoked extends TerminalReason {
  const Revoked();

  @override
  String get name => 'revoked';
}

/// See [TerminalReason.superseded].
final class Superseded extends TerminalReason {
  const Superseded();

  @override
  String get name => 'superseded';
}

/// See [TerminalReason.updateRequired].
final class UpdateRequired extends TerminalReason {
  const UpdateRequired();

  @override
  String get name => 'updateRequired';
}

/// See [TerminalReason.liveElsewhere].
final class LiveElsewhere extends TerminalReason {
  const LiveElsewhere(this.matchId);

  /// The match running on the other device (`error.details.match_id`).
  final String? matchId;

  @override
  String get name => 'liveElsewhere';

  @override
  bool operator ==(Object other) => other is LiveElsewhere && other.matchId == matchId;

  @override
  int get hashCode => Object.hash(LiveElsewhere, matchId);

  @override
  String toString() => 'liveElsewhere(${matchId ?? '?'})';
}
