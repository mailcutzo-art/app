part of '../events.dart';

/// `mm.queued`: the natural reply to `mm.join` (section 5).
final class MmQueuedEvent extends ServerEvent {
  MmQueuedEvent._(
    super.envelope, {
    required this.ticketId,
    required this.mode,
    required this.subject,
    required this.chapter,
    required this.joinedAt,
  });

  factory MmQueuedEvent.fromEnvelope(Envelope envelope) {
    final d = _payload(envelope);
    return MmQueuedEvent._(
      envelope,
      ticketId: d.string('ticket_id'),
      mode: d.string('mode'),
      subject: d.string('subject'),
      chapter: d.optString('chapter'),
      joinedAt: d.optInt('joined_at'),
    );
  }

  final String ticketId;

  /// `rated` or `casual`.
  final String mode;
  final String subject;

  /// `null` means all chapters.
  final String? chapter;
  final int? joinedAt;
}

/// `mm.status`: the search widened or the rating window grew.
final class MmStatusEvent extends ServerEvent {
  MmStatusEvent._(
    super.envelope, {
    required this.waitedS,
    required this.widened,
    required this.window,
    required this.online,
    required this.p50WaitS,
  });

  factory MmStatusEvent.fromEnvelope(Envelope envelope) {
    final d = _payload(envelope);
    return MmStatusEvent._(
      envelope,
      waitedS: d.integer('waited_s'),
      widened: d.optBool('widened') ?? false,
      window: d.optInt('window'),
      online: d.optInt('online'),
      p50WaitS: d.optInt('p50_wait_s'),
    );
  }

  final int waitedS;

  /// Whether the search now accepts players from other chapters of the subject.
  final bool widened;
  final int? window;

  /// Players searching in this subject right now.
  final int? online;

  /// The median wait in this subject, in seconds.
  final int? p50WaitS;
}

/// `mm.timeout`: nobody found yet; the user picks one of [options] with `mm.respond`.
final class MmTimeoutEvent extends ServerEvent {
  MmTimeoutEvent._(super.envelope, {required this.waitedS, required this.options});

  factory MmTimeoutEvent.fromEnvelope(Envelope envelope) {
    final d = _payload(envelope);
    return MmTimeoutEvent._(
      envelope,
      waitedS: d.integer('waited_s'),
      options: d.strings('options'),
    );
  }

  final int waitedS;

  /// Some of `keep`, `bot`, `invite`, `cancel`. `bot` is never offered for rated play.
  final List<String> options;
}

/// `mm.cancelled`: the ticket is gone and any coin hold is released.
final class MmCancelledEvent extends ServerEvent {
  MmCancelledEvent._(super.envelope, {required this.reason, required this.refunded});

  factory MmCancelledEvent.fromEnvelope(Envelope envelope) {
    final d = _payload(envelope);
    return MmCancelledEvent._(
      envelope,
      reason: d.string('reason'),
      refunded: d.optInt('refunded') ?? 0,
    );
  }

  /// `user`, `timeout` (nobody found in 105 s), `disconnected` (away for more than 10 s) or
  /// `cooldown`.
  final String reason;

  /// Coins returned (0 for rated play).
  final int refunded;
}

/// `mm.requeued`: the found match fell through, and the ticket is back at the front of the queue
/// with its original waiting time ("Your opponent didn't join. Searching again…").
final class MmRequeuedEvent extends ServerEvent {
  MmRequeuedEvent._(super.envelope, {required this.reason, required this.waitedS});

  factory MmRequeuedEvent.fromEnvelope(Envelope envelope) {
    final d = _payload(envelope);
    return MmRequeuedEvent._(envelope, reason: d.string('reason'), waitedS: d.integer('waited_s'));
  }

  /// `opponent_not_ready` or `match_failed`.
  final String reason;
  final int waitedS;
}

/// `mm.found`: a match was made. Its events follow on [matchChannel].
final class MmFoundEvent extends ServerEvent {
  MmFoundEvent._(
    super.envelope, {
    required this.matchId,
    required this.matchChannel,
    required this.mode,
    required this.opponent,
    required this.sources,
    required this.bot,
  });

  factory MmFoundEvent.fromEnvelope(Envelope envelope) {
    final d = _payload(envelope);
    final matchId = d.string('match_id');
    return MmFoundEvent._(
      envelope,
      matchId: matchId,
      matchChannel: d.optString('ch') ?? 'm:$matchId',
      mode: d.optString('mode'),
      opponent: _readCard(d.object('opponent')),
      sources: d.optObjects('sources', _readSource) ?? const [],
      bot: d.optBool('bot') ?? false,
    );
  }

  final String matchId;

  /// `m:<match_id>` (the payload's `ch`).
  final String matchChannel;
  final String? mode;
  final PlayerCard opponent;

  /// How the questions split across chapters, for example 4 + 3 after widening.
  final List<SourceChapter> sources;
  final bool bot;
}
