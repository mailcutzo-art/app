import 'events.dart';
import 'json.dart';

/// Error codes carried by [RealtimeError.code].
///
/// The server codes come from docs/protocol.md section 4. The client codes describe failures that
/// happen on this side of the socket.
abstract final class RealtimeErrorCode {
  // Server codes.
  static const badRequest = 'BAD_REQUEST';
  static const notFound = 'NOT_FOUND';
  static const notAllowed = 'NOT_ALLOWED';
  static const busy = 'BUSY';
  static const alreadyMatched = 'ALREADY_MATCHED';
  static const insufficientCoins = 'INSUFFICIENT_COINS';
  static const cooldown = 'COOLDOWN';
  static const rateLimited = 'RATE_LIMITED';
  static const unavailable = 'UNAVAILABLE';

  /// Sent before a 4409 close when another device is in a live match and `hello` didn't ask to
  /// take it over. The connection turns it into `TerminalReason.liveElsewhere`.
  static const liveElsewhere = 'LIVE_ELSEWHERE';

  // Client codes.

  /// No reply arrived within the request's timeout.
  static const timeout = 'TIMEOUT';

  /// The request was sent, but the connection dropped before the reply. The server may or may not
  /// have acted on it.
  static const disconnected = 'DISCONNECTED';

  /// No lease is held, so no connection is coming to send the request on.
  static const notConnected = 'NOT_CONNECTED';

  /// The app dropped the work, for example by forgetting the match an answer belonged to.
  static const cancelled = 'CANCELLED';

  /// The connection is terminal (revoked, superseded, update required) or disposed.
  static const closed = 'CLOSED';

  static const clientCodes = {timeout, disconnected, notConnected, cancelled, closed};
}

/// A failed request: an `error` frame from the server, or a client-side failure such as a
/// timeout (see [RealtimeErrorCode]).
final class RealtimeError implements Exception {
  const RealtimeError({
    required this.code,
    this.message = '',
    this.retryable = false,
    this.details = const {},
    this.ref,
  });

  /// One of [RealtimeErrorCode], or a newer server code.
  final String code;

  /// Human-readable text. Server messages are safe to show to the user.
  final String message;

  /// Whether trying again later can succeed.
  final bool retryable;

  /// Extra data, for example `active` for `BUSY` or `match_id` for `ALREADY_MATCHED`.
  final Map<String, Object?> details;

  /// The id of the client message this error answers, when known.
  final String? ref;

  /// Whether the error was produced by the client rather than sent by the server.
  bool get isClientSide => RealtimeErrorCode.clientCodes.contains(code);

  /// `details.active` for [RealtimeErrorCode.busy]: what the user is busy with (a queue, match,
  /// room or tournament, with its id and title), so the app can offer "Go there".
  ActiveEntry? get active => ActiveEntry.tryParse(details['active']);

  /// `details.match_id` for [RealtimeErrorCode.alreadyMatched] and
  /// [RealtimeErrorCode.liveElsewhere].
  String? get matchId => _string(details['match_id']);

  /// `details.retry_after_s` for [RealtimeErrorCode.rateLimited].
  int? get retryAfterSeconds => asInt(details['retry_after_s']);

  /// `details.until` (server ms) for [RealtimeErrorCode.cooldown].
  int? get until => asInt(details['until']);

  @override
  String toString() {
    final refText = ref == null ? '' : ' ref=$ref';
    final messageText = message.isEmpty ? '' : ': $message';
    return 'RealtimeError($code$refText)$messageText';
  }
}

String? _string(Object? value) => value is String ? value : null;
