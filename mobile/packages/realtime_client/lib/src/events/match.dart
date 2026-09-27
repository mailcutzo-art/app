part of '../events.dart';

/// `match.snapshot`: the whole match state (section 6). The first frame on a match channel, and
/// the answer to a resume the log can no longer replay. Its `seq` is the channel's current seq.
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
  });

  factory MatchSnapshotEvent.fromEnvelope(Envelope envelope) {
    final d = _payload(envelope);
    final question = d.optObject('question');
    final reveal = d.optObject('reveal');
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
  AnsAckEvent._(super.envelope, {required this.ref, required this.q, required this.status});

  factory AnsAckEvent.fromEnvelope(Envelope envelope) {
    final d = _payload(envelope);
    return AnsAckEvent._(
      envelope,
      ref: d.string('ref'),
      q: d.integer('q'),
      status: AnswerStatus.parse(d.string('status')),
    );
  }

  /// The id of the `ans.submit` this acknowledges.
  final String ref;
  final int q;
  final AnswerStatus status;
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
  MatchEndEvent._(
    super.envelope, {
    required this.result,
    required this.reason,
    required this.totals,
    required this.ranking,
  });

  factory MatchEndEvent.fromEnvelope(Envelope envelope) {
    final d = _payload(envelope);
    return MatchEndEvent._(
      envelope,
      result: MatchResult.parse(d.string('result')),
      reason: MatchEndReason.parse(d.string('reason')),
      totals: d.optObjectMap('totals', _readTotals) ?? const {},
      ranking: _readRanking(d),
    );
  }

  final MatchResult result;
  final MatchEndReason reason;
  final Map<String, PlayerTotals> totals;

  /// Places from first to last. Each place lists the uids that share it.
  final List<List<String>> ranking;
}

/// `ranking: [["<uid>"], …]`. A bare uid is read as a place of its own.
List<List<String>> _readRanking(JsonObject d) {
  final places = d.optList('ranking') ?? const [];
  return List.unmodifiable([
    for (final place in places)
      switch (place) {
        final String uid => List<String>.unmodifiable([uid]),
        final List<Object?> uids when uids.every((uid) => uid is String) =>
          List<String>.unmodifiable(uids.cast<String>()),
        _ => throw const FormatException('match.end: "ranking" must be a list of uid lists'),
      },
  ]);
}

/// `match.settled`: the committed rating, rank, coins, XP, missions, streak, achievements and tip.
final class MatchSettledEvent extends ServerEvent {
  MatchSettledEvent._(super.envelope, this.settlement);

  factory MatchSettledEvent.fromEnvelope(Envelope envelope) =>
      MatchSettledEvent._(envelope, _readSettlement(_payload(envelope)));

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
