part of '../events.dart';

/// `room.state`: the whole lobby, sent on join and after every change (section 8). Like
/// `match.snapshot`, it resets the channel's seq.
final class RoomStateEvent extends ServerEvent {
  RoomStateEvent._(
    super.envelope, {
    required this.roomId,
    required this.kind,
    required this.code,
    required this.host,
    required this.status,
    required this.locked,
    required this.settings,
    required this.members,
    required this.rematch,
    required this.matchId,
    required this.capacity,
  });

  factory RoomStateEvent.fromEnvelope(Envelope envelope) {
    final d = _payload(envelope);
    final rematch = d.optObject('rematch');
    return RoomStateEvent._(
      envelope,
      roomId: d.string('room_id'),
      kind: d.string('kind'),
      code: d.optString('code'),
      host: d.string('host'),
      status: d.string('status'),
      locked: d.optBool('locked') ?? false,
      settings: RoomSettings.fromJson(d.optObject('settings')?.map ?? const {}),
      members: d.objects('members', _readMember),
      rematch: rematch == null
          ? null
          : RoomRematch(
              offeredBy: rematch.string('offered_by'),
              until: rematch.optTimestamp('until'),
              accepted: rematch.optStrings('accepted') ?? const [],
            ),
      matchId: d.optString('match_id'),
      capacity: d.optInt('capacity'),
    );
  }

  final String roomId;

  /// `friend` or `group`.
  final String kind;
  final String? code;

  /// The host's uid.
  final String host;

  /// `lobby`, `playing` or `finished`.
  final String status;
  final bool locked;

  /// Subject, chapters, question count, seconds per question, and for groups the difficulty,
  /// late join, leaderboard and who can join.
  final RoomSettings settings;
  final List<RoomMember> members;

  /// A rematch on offer after a game, or `null`.
  final RoomRematch? rematch;

  /// The game being played while [status] is `playing`, so a member who (re)joins mid-game can
  /// follow it on `m:<match_id>`.
  final String? matchId;

  /// How many members the room takes: 2 for a friend duel, up to 8 for a group.
  final int? capacity;
}

/// `room.started {match_id, ch}`: the room's match begins on [matchChannel].
final class RoomStartedEvent extends ServerEvent {
  RoomStartedEvent._(super.envelope, {required this.matchId, required this.matchChannel});

  factory RoomStartedEvent.fromEnvelope(Envelope envelope) {
    final d = _payload(envelope);
    final matchId = d.string('match_id');
    return RoomStartedEvent._(
      envelope,
      matchId: matchId,
      matchChannel: d.optString('ch') ?? 'm:$matchId',
    );
  }

  final String matchId;
  final String matchChannel;
}

/// `room.kicked {room_id}`: sent to the kicked player.
final class RoomKickedEvent extends ServerEvent {
  RoomKickedEvent._(super.envelope, this.roomId);

  factory RoomKickedEvent.fromEnvelope(Envelope envelope) =>
      RoomKickedEvent._(envelope, _payload(envelope).string('room_id'));

  final String roomId;
}

/// `room.closed {room_id, reason}`.
final class RoomClosedEvent extends ServerEvent {
  RoomClosedEvent._(super.envelope, {required this.roomId, required this.reason});

  factory RoomClosedEvent.fromEnvelope(Envelope envelope) {
    final d = _payload(envelope);
    return RoomClosedEvent._(envelope, roomId: d.string('room_id'), reason: d.string('reason'));
  }

  final String roomId;

  /// `host_ended`, `idle`, `host_left` or `empty`.
  final String reason;
}
