part of '../events.dart';

/// `match.snapshot`: the whole match state, built for the receiving player (section 6). The first
/// frame on a match channel, and the answer to a resume the log can no longer replay. Its `seq`
/// is the channel's current seq.
final class MatchSnapshotEvent extends ServerEvent {
  MatchSnapshotEvent._(
    super.envelope, {
    required this.matchId,
    required this.kind,
    required this.phase,
    required this.endsAt,
    required this.q,
    required this.total,
    required this.limitMs,
    required this.players,
    required this.question,
    required this.reveal,
    required this.mine,
    required this.end,
    required this.settled,
  });

  factory MatchSnapshotEvent.fromEnvelope(Envelope envelope) {
    final d = _payload(envelope);
    final question = d.optObject('question');
    final reveal = d.optObject('reveal');
    final end = d.optObject('end');
    return MatchSnapshotEvent._(
      envelope,
      matchId: d.string('match_id'),
      kind: d.optString('kind'),
      phase: MatchPhase.parse(d.string('phase')),
      endsAt: d.optInt('ends_at'),
      q: d.integer('q'),
      total: d.integer('total'),
      limitMs: d.optInt('limit_ms'),
      players: d.objects('players', _readSnapshotPlayer),
      question: question == null ? null : _readShownQuestion(question),
      reveal: reveal == null ? null : _readReveal(reveal),
      mine: d.optObjects('mine', _readMine) ?? const [],
      end: end == null ? null : _readOutcome(end),
      settled: d.optBool('settled') ?? false,
    );
  }

  final String matchId;

  /// `quick_rated`, `quick_casual`, `bot`, `friend`, `group` or `tournament`.
  final String? kind;
  final MatchPhase phase;
  final int? endsAt;

  /// The current question number (0 before the first).
  final int q;
  final int total;
  final int? limitMs;
  final List<SnapshotPlayer> players;

  /// The current `q.show` payload, or `null`.
  final ShownQuestion? question;

  /// The last `q.reveal` payload, or `null`.
  final RevealResult? reveal;

  /// My answers so far.
  final List<MineEntry> mine;

  /// How the match ended (the `match.end` payload), or `null` while it is running.
  final MatchOutcome? end;

  /// Whether the server has committed the result. If so and `match.settled` never arrived, the app
  /// reads it over REST.
  final bool settled;
}

/// `match.phase {phase, q, ends_at}`.
final class MatchPhaseEvent extends ServerEvent {
  MatchPhaseEvent._(super.envelope, {required this.phase, required this.q, required this.endsAt});

  factory MatchPhaseEvent.fromEnvelope(Envelope envelope) {
    final d = _payload(envelope);
    return MatchPhaseEvent._(
      envelope,
      phase: MatchPhase.parse(d.string('phase')),
      q: d.optInt('q'),
      endsAt: d.optInt('ends_at'),
    );
  }

  final MatchPhase phase;
  final int? q;
  final int? endsAt;
}

/// `q.show`: the next question, sent about 400 ms before it goes live.
final class QShowEvent extends ServerEvent {
  QShowEvent._(super.envelope, this.question);

  factory QShowEvent.fromEnvelope(Envelope envelope) =>
      QShowEvent._(envelope, _readShownQuestion(_payload(envelope)));

  final ShownQuestion question;
}

/// `q.progress {q, answered}`: who has answered, never what.
final class QProgressEvent extends ServerEvent {
  QProgressEvent._(super.envelope, {required this.q, required this.answered});

  factory QProgressEvent.fromEnvelope(Envelope envelope) {
    final d = _payload(envelope);
    return QProgressEvent._(envelope, q: d.integer('q'), answered: d.strings('answered'));
  }

  final int q;
  final List<String> answered;
}

/// `ans.ack {ref, q, status}`: the natural reply to `ans.submit`.
final class AnsAckEvent extends ServerEvent {
  AnsAckEvent._(
    super.envelope, {
    required this.ref,
    required this.q,
    required this.status,
    required this.dup,
  });

  factory AnsAckEvent.fromEnvelope(Envelope envelope) {
    final d = _payload(envelope);
    final status = AnswerStatus.parse(d.string('status'));
    return AnsAckEvent._(
      envelope,
      ref: d.string('ref'),
      q: d.integer('q'),
      status: status,
      dup: d.optBool('dup') ?? status == AnswerStatus.dup,
    );
  }

  /// The id of the `ans.submit` this acknowledges.
  final String ref;
  final int q;

  /// The verdict. A repeat gets the first answer's verdict again, with [dup] set. From older
  /// servers it can be [AnswerStatus.dup], which carries no verdict.
  final AnswerStatus status;

  /// Whether the server already had this answer (a resend after a reconnect, or a second tap).
  final bool dup;
}

/// `q.reveal`: the correct option, everyone's picks and points, and the totals.
final class QRevealEvent extends ServerEvent {
  QRevealEvent._(super.envelope, this.reveal);

  factory QRevealEvent.fromEnvelope(Envelope envelope) =>
      QRevealEvent._(envelope, _readReveal(_payload(envelope)));

  final RevealResult reveal;
}

/// `opp.conn {uid, state, grace_until}`: another player dropped, came back or left.
final class OppConnEvent extends ServerEvent {
  OppConnEvent._(
    super.envelope, {
    required this.uid,
    required this.presence,
    required this.graceUntil,
  });

  factory OppConnEvent.fromEnvelope(Envelope envelope) {
    final d = _payload(envelope);
    return OppConnEvent._(
      envelope,
      uid: d.string('uid'),
      presence: Presence.parse(d.string('state')),
      graceUntil: d.optInt('grace_until'),
    );
  }

  final String uid;
  final Presence presence;

  /// Server ms when the player forfeits if still away.
  final int? graceUntil;
}

/// `emote {uid, e}`.
final class EmoteEvent extends ServerEvent {
  EmoteEvent._(super.envelope, {required this.uid, required this.emote});

  factory EmoteEvent.fromEnvelope(Envelope envelope) {
    final d = _payload(envelope);
    return EmoteEvent._(envelope, uid: d.string('uid'), emote: d.string('e'));
  }

  final String uid;

  /// `gg`, `nice`, `wow` or `oops`.
  final String emote;
}

/// `match.end {result, reason, totals, ranking}`. [result] is from my point of view.
final class MatchEndEvent extends ServerEvent {
  MatchEndEvent._(super.envelope, this.outcome);

  factory MatchEndEvent.fromEnvelope(Envelope envelope) =>
      MatchEndEvent._(envelope, _readOutcome(_payload(envelope)));

  final MatchOutcome outcome;

  MatchResult get result => outcome.result;
  MatchEndReason get reason => outcome.reason;
  Map<String, PlayerTotals> get totals => outcome.totals;

  /// Places from first to last. Each place lists the uids that share it.
  List<List<String>> get ranking => outcome.ranking;
}

/// `match.settled`: the committed rating, rank, coins, XP, missions, streak, achievements and tip.
///
/// Sent to each player alone, on `m:<match_id>` without a `seq`.
final class MatchSettledEvent extends ServerEvent {
  MatchSettledEvent._(super.envelope, {required this.matchId, required this.settlement});

  factory MatchSettledEvent.fromEnvelope(Envelope envelope) {
    final d = _payload(envelope);
    return MatchSettledEvent._(
      envelope,
      matchId: d.optString('match_id'),
      settlement: _readSettlement(d),
    );
  }

  /// The settled match, when the payload names it.
  final String? matchId;
  final Settlement settlement;
}

/// `rematch.status {match_id, state, by, reason}`: a casual rematch was offered, accepted,
/// declined, expired or failed. When both accept, a new `mm.found` follows.
final class RematchStatusEvent extends ServerEvent {
  RematchStatusEvent._(
    super.envelope, {
    required this.matchId,
    required this.state,
    required this.by,
    required this.reason,
  });

  factory RematchStatusEvent.fromEnvelope(Envelope envelope) {
    final d = _payload(envelope);
    return RematchStatusEvent._(
      envelope,
      matchId: d.string('match_id'),
      state: RematchState.parse(d.string('state')),
      by: d.optString('by'),
      reason: d.optString('reason'),
    );
  }

  /// The match that just ended.
  final String matchId;
  final RematchState state;

  /// Who made the change.
  final String? by;

  /// Why it failed, for example `insufficient_coins` or `opponent_left`.
  final String? reason;
}
