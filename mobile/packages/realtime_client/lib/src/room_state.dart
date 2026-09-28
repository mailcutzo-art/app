import 'events.dart';

/// Where a room stands (`room.state.status`), plus the two ways it can end for this player.
enum RoomStatus {
  lobby('lobby'),
  playing('playing'),
  finished('finished'),

  /// `room.closed`: see [RoomState.closedReason].
  closed('closed'),

  /// `room.kicked`: the host removed this player, who can't rejoin.
  kicked('kicked'),
  unknown('?');

  const RoomStatus(this.wire);

  final String wire;

  static RoomStatus parse(String wire) {
    for (final status in values) {
      if (status != unknown && status.wire == wire) return status;
    }
    return unknown;
  }

  /// Whether this player is out of the room for good.
  bool get isGone => this == closed || this == kicked;
}

/// Immutable state of one room lobby, built by [reduceRoom] from `r:<room_id>` events.
///
/// A `room.state` replaces it entirely (it is the room's snapshot), which is how resume works.
final class RoomState {
  const RoomState({
    required this.roomId,
    this.kind,
    this.code,
    this.host,
    this.status = RoomStatus.unknown,
    this.locked = false,
    this.settings = const RoomSettings(),
    this.members = const [],
    this.rematch,
    this.matchId,
    this.capacity,
    this.closedReason,
    this.previousHost,
  });

  /// The state before the first `room.state` of [roomId] arrives.
  const RoomState.initial(String roomId) : this(roomId: roomId);

  final String roomId;

  /// `friend` or `group`.
  final String? kind;

  /// The 6-character join code.
  final String? code;

  /// The host's uid.
  final String? host;
  final RoomStatus status;

  /// Whether the host locked the room: nobody new can join.
  final bool locked;
  final RoomSettings settings;

  /// Members in the server's order (join order).
  final List<RoomMember> members;

  /// A rematch on offer after a game.
  final RoomRematch? rematch;

  /// The game in progress (from `room.started`, or `room.state.match_id`), or the last one.
  final String? matchId;

  /// How many members the room takes.
  final int? capacity;

  /// `host_ended`, `idle`, `host_left` or `empty`, once [status] is [RoomStatus.closed].
  final String? closedReason;

  /// The host before the latest change of host, so the app can say "Neha is now the host".
  /// `null` when the host hasn't changed since this device joined.
  final String? previousHost;

  /// Whether any `room.state` has arrived.
  bool get isKnown => status != RoomStatus.unknown;

  bool get isFriend => kind == 'friend';

  bool get isGroup => kind == 'group';

  bool isHost(String uid) => host == uid;

  RoomMember? member(String uid) {
    for (final member in members) {
      if (member.uid == uid) return member;
    }
    return null;
  }

  RoomMember? get hostMember => host == null ? null : member(host!);

  /// Members whose app is connected and in the foreground.
  Iterable<RoomMember> get present => members.where((m) => m.connected && !m.away);

  int get connectedCount => members.where((m) => m.connected).length;

  /// Whether the host can start: a lobby with at least two connected members.
  bool get canStart => status == RoomStatus.lobby && connectedCount >= 2;

  /// Whether every connected member is ready (and there are at least two).
  bool get allReady {
    final connected = members.where((m) => m.connected).toList();
    return connected.length >= 2 && connected.every((m) => m.ready);
  }

  /// The members the lobby is waiting on to come back: away (app in the background) or
  /// disconnected, host first.
  List<RoomMember> get waitingFor => [
    for (final member in members)
      if (member.away || !member.connected) member,
  ]..sort((a, b) => (b.uid == host ? 1 : 0) - (a.uid == host ? 1 : 0));

  /// Whether the room has space for one more member.
  bool get hasSpace => capacity == null || members.length < capacity!;

  @override
  String toString() => 'RoomState($roomId, ${status.name}, ${members.length} members)';

  RoomState _copy({RoomStatus? status, Object? matchId = _keep, Object? closedReason = _keep}) =>
      RoomState(
        roomId: roomId,
        kind: kind,
        code: code,
        host: host,
        status: status ?? this.status,
        locked: locked,
        settings: settings,
        members: members,
        rematch: rematch,
        matchId: identical(matchId, _keep) ? this.matchId : matchId as String?,
        capacity: capacity,
        closedReason: identical(closedReason, _keep) ? this.closedReason : closedReason as String?,
        previousHost: previousHost,
      );
}

const Object _keep = Object();

/// Applies one server event to [state]. Pure: the same events always give the same state.
///
/// Only events for [RoomState.roomId] count (by `room_id`, or by the `r:` channel for
/// `room.started`). Anything else leaves [state] unchanged. A room that is closed or that this
/// player was kicked from stays that way.
RoomState reduceRoom(RoomState state, ServerEvent event) {
  if (state.status.isGone) return state;
  switch (event) {
    case RoomStateEvent() when event.roomId == state.roomId:
      final hostChanged = state.host != null && state.host != event.host;
      return RoomState(
        roomId: event.roomId,
        kind: event.kind,
        code: event.code ?? state.code,
        host: event.host,
        status: RoomStatus.parse(event.status),
        locked: event.locked,
        settings: event.settings,
        members: List.unmodifiable(event.members),
        rematch: event.rematch,
        matchId:
            event.matchId ??
            (RoomStatus.parse(event.status) == RoomStatus.lobby ? null : state.matchId),
        capacity: event.capacity ?? state.capacity,
        previousHost: hostChanged ? state.host : state.previousHost,
      );
    case RoomStartedEvent() when event.channel == 'r:${state.roomId}':
      return state._copy(status: RoomStatus.playing, matchId: event.matchId);
    case RoomKickedEvent(:final roomId) when roomId == state.roomId:
      return state._copy(status: RoomStatus.kicked);
    case RoomClosedEvent(:final roomId, :final reason) when roomId == state.roomId:
      return state._copy(status: RoomStatus.closed, closedReason: reason);
    default:
      return state;
  }
}
