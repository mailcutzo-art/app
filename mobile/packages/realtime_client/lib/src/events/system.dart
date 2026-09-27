part of '../events.dart';

/// `welcome`: the handshake succeeded (section 1).
final class WelcomeEvent extends ServerEvent {
  WelcomeEvent._(
    super.envelope, {
    required this.connId,
    required this.userId,
    required this.serverMs,
    required this.hbS,
    required this.active,
  });

  factory WelcomeEvent.fromEnvelope(Envelope envelope) {
    final d = _payload(envelope);
    return WelcomeEvent._(
      envelope,
      connId: d.optString('conn_id'),
      userId: d.string('user_id'),
      serverMs: d.integer('server_ms'),
      hbS: d.integer('hb_s'),
      active: d.optObjects('active', _readActive) ?? const [],
    );
  }

  final String? connId;
  final String userId;

  /// Server time when the welcome was sent. Seeds the clock until the first sync finishes.
  final int serverMs;

  /// The heartbeat interval in seconds.
  final int hbS;

  /// Anything the user is in right now. After a cold start the app uses it to jump back into the
  /// game.
  final List<ActiveEntry> active;
}

/// `ping {n}`: answered at once with `pong {n}` (section 3).
final class PingEvent extends ServerEvent {
  PingEvent._(super.envelope, this.n);

  factory PingEvent.fromEnvelope(Envelope envelope) =>
      PingEvent._(envelope, _payload(envelope).integer('n'));

  final int n;
}

/// `clock.pong {c0, s}` (section 3).
final class ClockPongEvent extends ServerEvent {
  ClockPongEvent._(super.envelope, {required this.c0, required this.s});

  factory ClockPongEvent.fromEnvelope(Envelope envelope) {
    final d = _payload(envelope);
    return ClockPongEvent._(envelope, c0: d.integer('c0'), s: d.integer('s'));
  }

  /// The client's monotonic ms from the matching `clock.ping`.
  final int c0;

  /// Server ms when the server answered.
  final int s;
}

/// `ack {ref}`: confirms a request that has no other natural reply (section 4).
final class AckEvent extends ServerEvent {
  AckEvent._(super.envelope, this.ref);

  factory AckEvent.fromEnvelope(Envelope envelope) =>
      AckEvent._(envelope, _payload(envelope).string('ref'));

  final String ref;
}

/// `error {ref, code, message, retryable, details}` (section 4).
final class ErrorEvent extends ServerEvent {
  ErrorEvent._(
    super.envelope, {
    required this.ref,
    required this.code,
    required this.message,
    required this.retryable,
    required this.details,
  });

  factory ErrorEvent.fromEnvelope(Envelope envelope) {
    final d = _payload(envelope);
    return ErrorEvent._(
      envelope,
      ref: d.optString('ref'),
      code: d.string('code'),
      message: d.optString('message') ?? '',
      retryable: d.optBool('retryable') ?? false,
      details: d.optObject('details')?.map ?? const {},
    );
  }

  /// The client message id this error answers, if any.
  final String? ref;
  final String code;
  final String message;
  final bool retryable;
  final Map<String, Object?> details;

  RealtimeError toError() =>
      RealtimeError(code: code, message: message, retryable: retryable, details: details, ref: ref);
}
