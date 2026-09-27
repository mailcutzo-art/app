/// Typed server messages (docs/protocol.md sections 1 to 9).
///
/// Every server frame decodes to exactly one [ServerEvent]. Unknown message types become an
/// [UnknownEvent], which consumers ignore. Unknown fields are ignored. A missing or mistyped
/// required field throws a [FormatException], which the connection logs and drops as a bad frame.
library;

import 'dart:math' as math;

import 'envelope.dart';
import 'errors.dart';
import 'json.dart';

part 'events/match.dart';
part 'events/matchmaking.dart';
part 'events/room.dart';
part 'events/social.dart';
part 'events/system.dart';
part 'events/tournament.dart';
part 'events/values.dart';

/// A decoded server message.
sealed class ServerEvent {
  const ServerEvent(this.envelope);

  /// Decodes a text frame: the envelope first, then the payload for its type.
  ///
  /// Throws a [FormatException] for a malformed envelope or payload.
  factory ServerEvent.decode(Object? frame) => ServerEvent.fromEnvelope(Envelope.decode(frame));

  /// Types the payload of an already validated [envelope].
  factory ServerEvent.fromEnvelope(Envelope envelope) {
    final decode = _decoders[envelope.type];
    return decode == null ? UnknownEvent(envelope) : decode(envelope);
  }

  /// The envelope the event arrived in.
  final Envelope envelope;

  /// The wire type, for example `q.show`.
  String get type => envelope.type;

  /// `ch`: the channel the event belongs to.
  String? get channel => envelope.channel;

  /// `seq`: the per-channel sequence number, on resumable channels only.
  int? get seq => envelope.seq;

  /// `ts`: server time in ms when the event was produced.
  int? get ts => envelope.ts;

  @override
  String toString() => '$type(ch: ${channel ?? '-'}, seq: ${seq ?? '-'})';
}

/// A message type this client doesn't know. It is delivered so nothing is silently lost, and
/// consumers ignore it.
final class UnknownEvent extends ServerEvent {
  const UnknownEvent(super.envelope);
}

/// Reads the payload of [envelope], naming the message type in errors.
JsonObject _payload(Envelope envelope) => JsonObject(envelope.data, envelope.type);

const Map<String, ServerEvent Function(Envelope)> _decoders = {
  // Section 1, 3 and 4: connection, heartbeat, clock, replies.
  'welcome': WelcomeEvent.fromEnvelope,
  'ping': PingEvent.fromEnvelope,
  'clock.pong': ClockPongEvent.fromEnvelope,
  'ack': AckEvent.fromEnvelope,
  'error': ErrorEvent.fromEnvelope,
  // Section 5: matchmaking.
  'mm.queued': MmQueuedEvent.fromEnvelope,
  'mm.status': MmStatusEvent.fromEnvelope,
  'mm.timeout': MmTimeoutEvent.fromEnvelope,
  'mm.cancelled': MmCancelledEvent.fromEnvelope,
  'mm.requeued': MmRequeuedEvent.fromEnvelope,
  'mm.found': MmFoundEvent.fromEnvelope,
  // Section 6: matches.
  'match.snapshot': MatchSnapshotEvent.fromEnvelope,
  'match.phase': MatchPhaseEvent.fromEnvelope,
  'q.show': QShowEvent.fromEnvelope,
  'q.progress': QProgressEvent.fromEnvelope,
  'ans.ack': AnsAckEvent.fromEnvelope,
  'q.reveal': QRevealEvent.fromEnvelope,
  'opp.conn': OppConnEvent.fromEnvelope,
  'emote': EmoteEvent.fromEnvelope,
  'match.end': MatchEndEvent.fromEnvelope,
  'match.settled': MatchSettledEvent.fromEnvelope,
  'rematch.status': RematchStatusEvent.fromEnvelope,
  // Section 8: rooms and invites.
  'room.state': RoomStateEvent.fromEnvelope,
  'room.started': RoomStartedEvent.fromEnvelope,
  'room.kicked': RoomKickedEvent.fromEnvelope,
  'room.closed': RoomClosedEvent.fromEnvelope,
  'invite.received': InviteReceivedEvent.fromEnvelope,
  'invite.updated': InviteUpdatedEvent.fromEnvelope,
  // Section 9: tournaments.
  't.standings': TStandingsEvent.fromEnvelope,
  't.round': TRoundEvent.fromEnvelope,
  't.check_in': TCheckInEvent.fromEnvelope,
  't.checked_in': TCheckedInEvent.fromEnvelope,
  't.pairing': TPairingEvent.fromEnvelope,
  't.bye': TByeEvent.fromEnvelope,
  't.finished': TFinishedEvent.fromEnvelope,
  't.cancelled': TCancelledEvent.fromEnvelope,
  // Section 9a: inbox.
  'notify': NotifyEvent.fromEnvelope,
};

/// The message types [ServerEvent.decode] knows, for tests and diagnostics.
Iterable<String> get knownServerMessageTypes => _decoders.keys;
