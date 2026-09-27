part of '../events.dart';

/// `invite.received`: a friend invited me to a room. The app shows Accept/Decline on any screen;
/// accepting goes through REST, then `room.join`.
final class InviteReceivedEvent extends ServerEvent {
  InviteReceivedEvent._(
    super.envelope, {
    required this.inviteId,
    required this.from,
    required this.kind,
    required this.roomId,
    required this.subject,
    required this.expiresAt,
  });

  factory InviteReceivedEvent.fromEnvelope(Envelope envelope) {
    final d = _payload(envelope);
    return InviteReceivedEvent._(
      envelope,
      inviteId: d.string('invite_id'),
      from: _readCard(d.object('from')),
      kind: d.optString('kind'),
      roomId: d.optString('room_id'),
      subject: d.optString('subject'),
      expiresAt: d.optTimestamp('expires_at'),
    );
  }

  final String inviteId;
  final PlayerCard from;

  /// The room kind: `friend` or `group`.
  final String? kind;
  final String? roomId;
  final String? subject;

  /// Server ms when the invite lapses (2 minutes after it was sent).
  final int? expiresAt;
}

/// `invite.updated`: an invite was accepted, declined, expired or cancelled. Goes to both sides.
final class InviteUpdatedEvent extends ServerEvent {
  InviteUpdatedEvent._(super.envelope, {required this.inviteId, required this.status});

  factory InviteUpdatedEvent.fromEnvelope(Envelope envelope) {
    final d = _payload(envelope);
    return InviteUpdatedEvent._(
      envelope,
      inviteId: d.string('invite_id'),
      status: InviteStatus.parse(d.string('status')),
    );
  }

  final String inviteId;
  final InviteStatus status;
}

/// `notify`: a new inbox item, live, so the bell badge updates at once (section 9a).
final class NotifyEvent extends ServerEvent {
  NotifyEvent._(
    super.envelope, {
    required this.id,
    required this.kind,
    required this.title,
    required this.body,
    required this.icon,
    required this.action,
    required this.unread,
  });

  factory NotifyEvent.fromEnvelope(Envelope envelope) {
    final d = _payload(envelope);
    final action = d.optObject('action');
    return NotifyEvent._(
      envelope,
      id: d.string('id'),
      kind: d.string('kind'),
      title: d.string('title'),
      body: d.optString('body'),
      icon: d.optString('icon'),
      action: action == null
          ? null
          : NotifyAction(
              route: action.string('route'),
              params: action.optObject('params')?.map ?? const {},
            ),
      unread: d.optInt('unread'),
    );
  }

  final String id;

  /// `invite`, `tournament_round`, `refund`, `level_up`, … (see docs/api-play.md).
  final String kind;
  final String title;
  final String? body;
  final String? icon;

  /// Where tapping the item goes.
  final NotifyAction? action;

  /// The unread count after this item, for the badge.
  final int? unread;
}
