import 'package:flutter/foundation.dart';

import '../../../core/network/json.dart';
import '../../social/data/social_models.dart' show UserCard;

/// A private room: a 1v1 friend duel or a group battle of 2–8.
enum RoomKind {
  friend('friend', 'Friend battle'),
  group('group', 'Group battle');

  const RoomKind(this.wire, this.label);

  final String wire;
  final String label;

  static RoomKind? parse(Object? value) => values.where((k) => k.wire == value).firstOrNull;
}

/// `POST /v1/rooms` → `{room_id, code, link, expires_at}`.
@immutable
class CreatedRoom {
  const CreatedRoom({required this.roomId, required this.code, this.link, this.expiresAt});

  factory CreatedRoom.fromJson(Object? json) {
    final r = JsonReader(json, 'room');
    return CreatedRoom(
      roomId: r.string('room_id'),
      code: r.string('code'),
      link: r.optString('link'),
      expiresAt: DateTime.tryParse(r.optString('expires_at') ?? ''),
    );
  }

  final String roomId;
  final String code;

  /// `https://<domain>/j/<code>`, the link to share.
  final String? link;
  final DateTime? expiresAt;
}

/// Why a room can't be joined (`GET /v1/rooms/code/{code}` `reason`).
enum JoinBlock {
  locked('locked', 'The host locked this room.'),
  full('full', 'This room is full.'),
  started('started', 'The game has already started.'),
  blocked('blocked', 'You can\'t join this room.'),
  friendsOnly('friends_only', 'Only the host\'s friends can join this room.'),
  unknown('?', 'You can\'t join this room right now.');

  const JoinBlock(this.wire, this.message);

  final String wire;

  /// What the join screen says.
  final String message;

  static JoinBlock? parse(Object? value) {
    if (value == null) return null;
    return values.where((b) => b.wire == value).firstOrNull ?? unknown;
  }
}

/// The preview before joining: `GET /v1/rooms/code/{code}`.
@immutable
class RoomPreview {
  const RoomPreview({
    required this.roomId,
    required this.kind,
    required this.host,
    this.subject,
    this.chapters = const [],
    this.questions,
    this.seconds,
    this.members = 0,
    this.capacity,
    this.joinable = true,
    this.reason,
  });

  factory RoomPreview.fromJson(Object? json) {
    final r = JsonReader(json, 'room preview');
    final reason = JoinBlock.parse(r['reason']);
    return RoomPreview(
      roomId: r.string('room_id'),
      kind: RoomKind.parse(r['kind']) ?? RoomKind.friend,
      host: UserCard.fromJson(r['host']),
      subject: r.optString('subject'),
      chapters: r
          .optList('chapters', (c) => c is String ? c : '')
          .where((c) => c.isNotEmpty)
          .toList(),
      questions: r.optInt('questions'),
      seconds: r.optInt('seconds'),
      members: r.optInt('members') ?? 0,
      capacity: r.optInt('capacity'),
      joinable: r.flag('joinable', fallback: reason == null),
      reason: reason,
    );
  }

  final String roomId;
  final RoomKind kind;
  final UserCard host;

  /// The subject's name (or slug).
  final String? subject;

  /// Chapter names; empty means all chapters.
  final List<String> chapters;
  final int? questions;
  final int? seconds;
  final int members;
  final int? capacity;
  final bool joinable;

  /// Set when [joinable] is false.
  final JoinBlock? reason;
}

/// `POST /v1/invites` → `{invite_id, expires_at}`.
@immutable
class SentInvite {
  const SentInvite({required this.inviteId, this.expiresAt});

  factory SentInvite.fromJson(Object? json) {
    final r = JsonReader(json, 'invite');
    return SentInvite(
      inviteId: r.string('invite_id'),
      expiresAt: DateTime.tryParse(r.optString('expires_at') ?? ''),
    );
  }

  final String inviteId;
  final DateTime? expiresAt;
}

/// One pending invite from `GET /v1/me/invites`: [user] is `from` for incoming ones and `to` for
/// outgoing ones.
@immutable
class RoomInvite {
  const RoomInvite({
    required this.inviteId,
    required this.user,
    this.roomId,
    this.kind,
    this.subject,
    this.expiresAt,
  });

  factory RoomInvite.fromJson(Object? json) {
    final r = JsonReader(json, 'invite');
    return RoomInvite(
      inviteId: r.string('invite_id'),
      user: UserCard.fromJson(r['from'] ?? r['to']),
      roomId: r.optString('room_id'),
      kind: RoomKind.parse(r['kind']),
      subject: r.optString('subject'),
      expiresAt: DateTime.tryParse(r.optString('expires_at') ?? ''),
    );
  }

  final String inviteId;
  final UserCard user;
  final String? roomId;
  final RoomKind? kind;
  final String? subject;
  final DateTime? expiresAt;
}

/// `GET /v1/me/invites`: pending invites both ways.
@immutable
class InviteList {
  const InviteList({this.incoming = const [], this.outgoing = const []});

  factory InviteList.fromJson(Object? json) {
    final r = JsonReader(json, 'invites');
    return InviteList(
      incoming: r.optList('incoming', RoomInvite.fromJson),
      outgoing: r.optList('outgoing', RoomInvite.fromJson),
    );
  }

  final List<RoomInvite> incoming;
  final List<RoomInvite> outgoing;
}

/// `POST /v1/invites/{id}/accept` → `{room_id, code}`; the app then sends `room.join`.
@immutable
class AcceptedInvite {
  const AcceptedInvite({required this.roomId, this.code});

  factory AcceptedInvite.fromJson(Object? json) {
    final r = JsonReader(json, 'accepted invite');
    return AcceptedInvite(roomId: r.string('room_id'), code: r.optString('code'));
  }

  final String roomId;
  final String? code;
}
