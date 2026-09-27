import 'events.dart';

/// One player in a match, as the UI shows them.
final class MatchPlayer {
  const MatchPlayer({required this.card, this.presence = Presence.connected, this.graceUntil});

  final PlayerCard card;

  /// Connected, reconnecting (the grace period is running) or left.
  final Presence presence;

  /// Server ms when the player forfeits if still away (from `opp.conn`).
  final int? graceUntil;

  String get uid => card.uid;

  MatchPlayer _withPresence(Presence presence, int? graceUntil) =>
      MatchPlayer(card: card, presence: presence, graceUntil: graceUntil);

  @override
  String toString() => 'MatchPlayer($uid, ${presence.name})';
}

/// My answer to one question.
final class MyAnswer {
  const MyAnswer({required this.q, required this.opt, required this.status});

  final int q;

  /// The option I picked, or `null` when only the server knows (for example after a restart).
  final String? opt;

  /// [AnswerStatus.pending] until `ans.ack` arrives. [AnswerStatus.unknown] means the server says
  /// I answered but the verdict isn't known here.
  final AnswerStatus status;

  @override
  bool operator ==(Object other) =>
      other is MyAnswer && other.q == q && other.opt == opt && other.status == status;

  @override
  int get hashCode => Object.hash(q, opt, status);

  @override
  String toString() => 'MyAnswer(q$q, ${opt ?? '-'}, ${status.name})';
}

/// The most recent emote. [serial] grows with every emote, so the UI can replay the animation
/// when the same emote arrives twice.
final class EmoteState {
  const EmoteState({required this.uid, required this.emote, required this.serial, this.at});

  final String uid;
  final String emote;
  final int serial;

  /// Server ms of the event (`ts`).
  final int? at;
}

/// Where a casual rematch stands after `match.end` (from `rematch.status`).
enum Rematch {
  /// Nobody has offered one.
  none,

  /// I offered; waiting for the opponent.
  offeredByMe,

  /// The opponent offered; I can accept.
  offeredByThem,

  /// Both accepted; a new `mm.found` follows.
  accepted,
  declined,
  expired,

  /// It couldn't start; see [MatchState.rematchFailure].
  failed,
}

/// Immutable UI state of one match, built by [reduceMatch] from server events.
///
/// A `match.snapshot` replaces it entirely, which is how resume works.
final class MatchState {
  const MatchState({
    this.matchId,
    this.kind,
    this.phase = MatchPhase.unknown,
    this.endsAt,
    this.q = 0,
    this.total = 0,
    this.limitMs,
    this.players = const {},
    this.question,
    this.mine = const {},
    this.answered = const {},
    this.reveal,
    this.standings = const [],
    this.totals = const {},
    this.lastEmote,
    this.end,
    this.endedAt,
    this.settlement,
    this.settledOnServer = false,
    this.rematch = Rematch.none,
    this.rematchFailure,
  });

  /// The state before the first snapshot of [matchId] arrives. Events for other matches are
  /// ignored.
  const MatchState.initial(String matchId) : this(matchId: matchId);

  final String? matchId;

  /// `quick_rated`, `quick_casual`, `bot`, `friend`, `group` or `tournament`.
  final String? kind;
  final MatchPhase phase;

  /// Server ms when the current phase ends (countdown end, question deadline), if known.
  final int? endsAt;

  /// The current question number (0 before the first).
  final int q;
  final int total;
  final int? limitMs;

  /// Players by uid, in the server's order.
  final Map<String, MatchPlayer> players;

  /// The current (or last) question.
  final ShownQuestion? question;

  /// My answers by question number.
  final Map<int, MyAnswer> mine;

  /// Who has answered the current question (`q.progress`).
  final Set<String> answered;

  /// The last `q.reveal`.
  final RevealResult? reveal;

  /// The group battle leaderboard from the last `q.reveal` that carried one (empty in 1v1).
  final List<GroupStanding> standings;

  /// Running totals by uid.
  final Map<String, PlayerTotals> totals;
  final EmoteState? lastEmote;

  /// How the match ended: from `match.end`, or from a snapshot's `end` after a resume.
  final MatchOutcome? end;

  /// Server ms of the `match.end` event, or `null` if the end came from a snapshot.
  final int? endedAt;

  /// Set by `match.settled`. Until then a finished match shows "Results syncing…".
  final Settlement? settlement;

  /// Whether the server has committed the result (a snapshot said `settled: true`, or
  /// `match.settled` arrived). See [needsSettlementFetch].
  final bool settledOnServer;

  /// The casual rematch, after `match.end`.
  final Rematch rematch;

  /// Why the rematch failed (`insufficient_coins`, `opponent_left`, …), when [rematch] is
  /// [Rematch.failed].
  final String? rematchFailure;

  /// My answer to the current question.
  MyAnswer? get myAnswer => mine[q];

  /// The reveal of the current question, once it is revealed.
  RevealResult? get currentReveal {
    final reveal = this.reveal;
    return reveal != null && reveal.q == q ? reveal : null;
  }

  /// Whether the question may be shown at [serverNowMs] (pass `ServerClock.nowServerMs()`).
  /// `false` until the synced clock reaches `shown_at`.
  bool isQuestionRevealed(int serverNowMs) => question?.revealedAt(serverNowMs) ?? false;

  bool get isOver => phase.isOver;

  /// Finished, but `match.settled` hasn't arrived yet.
  bool get awaitingSettlement => phase == MatchPhase.finished && settlement == null;

  /// Whether the app should read the result over REST (`GET /v1/matches/{id}`) because
  /// `match.settled` hasn't arrived: a snapshot said the server has settled the match, or the
  /// match ended at least [waitMs] ago at the synced server time [serverNowMs].
  ///
  /// An end known only from a snapshot has no [endedAt]; it counts as old, since the app was away
  /// while waiting. Also fetch when the connection drops while waiting (docs/protocol.md
  /// section 6).
  bool needsSettlementFetch(int serverNowMs, {int waitMs = 20000}) {
    if (settlement != null) return false;
    if (settledOnServer) return true;
    if (end == null) return false;
    final endedAt = this.endedAt;
    return endedAt == null || serverNowMs - endedAt >= waitMs;
  }

  PlayerTotals totalsOf(String uid) => totals[uid] ?? PlayerTotals.zero;

  Iterable<MatchPlayer> opponentsOf(String me) => players.values.where((p) => p.uid != me);

  @override
  String toString() =>
      'MatchState(${matchId ?? '-'}, ${phase.name}, q$q/$total, mine: ${mine.values.toList()})';

  MatchState _copy({
    MatchPhase? phase,
    Object? endsAt = _keep,
    int? q,
    int? total,
    Object? limitMs = _keep,
    Map<String, MatchPlayer>? players,
    Object? question = _keep,
    Map<int, MyAnswer>? mine,
    Set<String>? answered,
    Object? reveal = _keep,
    List<GroupStanding>? standings,
    Map<String, PlayerTotals>? totals,
    Object? lastEmote = _keep,
    Object? end = _keep,
    Object? endedAt = _keep,
    Object? settlement = _keep,
    bool? settledOnServer,
    Rematch? rematch,
    Object? rematchFailure = _keep,
  }) => MatchState(
    matchId: matchId,
    kind: kind,
    phase: phase ?? this.phase,
    endsAt: identical(endsAt, _keep) ? this.endsAt : endsAt as int?,
    q: q ?? this.q,
    total: total ?? this.total,
    limitMs: identical(limitMs, _keep) ? this.limitMs : limitMs as int?,
    players: players == null ? this.players : Map.unmodifiable(players),
    question: identical(question, _keep) ? this.question : question as ShownQuestion?,
    mine: mine == null ? this.mine : Map.unmodifiable(mine),
    answered: answered == null ? this.answered : Set.unmodifiable(answered),
    reveal: identical(reveal, _keep) ? this.reveal : reveal as RevealResult?,
    standings: standings == null ? this.standings : List.unmodifiable(standings),
    totals: totals == null ? this.totals : Map.unmodifiable(totals),
    lastEmote: identical(lastEmote, _keep) ? this.lastEmote : lastEmote as EmoteState?,
    end: identical(end, _keep) ? this.end : end as MatchOutcome?,
    endedAt: identical(endedAt, _keep) ? this.endedAt : endedAt as int?,
    settlement: identical(settlement, _keep) ? this.settlement : settlement as Settlement?,
    settledOnServer: settledOnServer ?? this.settledOnServer,
    rematch: rematch ?? this.rematch,
    rematchFailure: identical(rematchFailure, _keep)
        ? this.rematchFailure
        : rematchFailure as String?,
  );
}

const Object _keep = Object();

/// Applies one server event to [state]. Pure and deterministic: the same events always give the
/// same state. [me] is the signed-in user's uid.
///
/// Events for another match (by `match_id` when the payload has one, otherwise by channel) and
/// events that aren't about matches leave [state] unchanged. Feed it the connection's filtered
/// event stream, so events arrive once and in order.
MatchState reduceMatch(MatchState state, ServerEvent event, {required String me}) {
  if (!_belongsTo(state, event)) return state;
  return switch (event) {
    MatchSnapshotEvent() => _snapshot(event, me),
    MatchPhaseEvent() => state._copy(phase: event.phase, q: event.q, endsAt: event.endsAt),
    QShowEvent(:final question) => _show(state, question),
    QProgressEvent() => _progress(state, event, me),
    AnsAckEvent() => _ack(state, event),
    QRevealEvent(:final reveal) => _reveal(state, reveal, me),
    OppConnEvent() => _presence(state, event),
    EmoteEvent() => state._copy(
      lastEmote: EmoteState(
        uid: event.uid,
        emote: event.emote,
        serial: (state.lastEmote?.serial ?? 0) + 1,
        at: event.ts,
      ),
    ),
    MatchEndEvent() => _end(state, event),
    MatchSettledEvent(:final settlement) => state._copy(
      settlement: settlement,
      settledOnServer: true,
    ),
    RematchStatusEvent() => _rematch(state, event, me),
    _ => state,
  };
}

/// Marks option [opt] of question [q] as my pending answer, shown optimistically until the
/// `ans.ack`. Ignored unless question [q] is open, [opt] is one of its options, and I haven't
/// answered it yet.
MatchState selectAnswer(MatchState state, {required int q, required String opt}) {
  final question = state.question;
  if (state.phase != MatchPhase.qOpen || question == null || question.q != q) return state;
  if (state.mine.containsKey(q) || !question.options.any((option) => option.id == opt)) {
    return state;
  }
  return state._copy(
    mine: {
      ...state.mine,
      q: MyAnswer(q: q, opt: opt, status: AnswerStatus.pending),
    },
  );
}

bool _belongsTo(MatchState state, ServerEvent event) {
  final matchId = state.matchId;
  if (matchId == null) return true;
  switch (event) {
    case MatchSnapshotEvent(matchId: final id) ||
        RematchStatusEvent(matchId: final id) ||
        MatchSettledEvent(matchId: final String id):
      return id == matchId;
    default:
      final channel = event.channel;
      return channel == null || !channel.startsWith('m:') || channel == 'm:$matchId';
  }
}

MatchState _snapshot(MatchSnapshotEvent snapshot, String me) {
  final revealTotals = snapshot.reveal?.totals ?? const <String, PlayerTotals>{};
  final mine = {
    for (final entry in snapshot.mine)
      entry.q: MyAnswer(q: entry.q, opt: entry.opt, status: entry.status),
  };
  final question = snapshot.question;
  final meAnswered = snapshot.players.any((p) => p.uid == me && p.answered);
  if (question != null && meAnswered && !mine.containsKey(question.q)) {
    mine[question.q] = MyAnswer(q: question.q, opt: null, status: AnswerStatus.unknown);
  }
  final end = snapshot.end;
  final phase = end == null || snapshot.phase.isOver ? snapshot.phase : _phaseAfter(end.reason);
  return MatchState(
    matchId: snapshot.matchId,
    kind: snapshot.kind,
    phase: phase,
    endsAt: end != null
        ? null
        : snapshot.endsAt ?? (phase == MatchPhase.qOpen ? question?.deadlineAt : null),
    q: snapshot.q,
    total: snapshot.total,
    limitMs: snapshot.limitMs ?? question?.limitMs,
    players: Map.unmodifiable({
      for (final player in snapshot.players)
        player.uid: MatchPlayer(
          card: player.card,
          presence: player.presence,
          graceUntil: player.graceUntil,
        ),
    }),
    question: question,
    mine: Map.unmodifiable(mine),
    answered: Set.unmodifiable({
      for (final player in snapshot.players)
        if (player.answered) player.uid,
    }),
    reveal: snapshot.reveal,
    standings: snapshot.reveal?.standings ?? const [],
    totals: end != null && end.totals.isNotEmpty
        ? end.totals
        : Map.unmodifiable({
            for (final player in snapshot.players)
              player.uid: PlayerTotals(
                points: player.score,
                correct: player.correct ?? revealTotals[player.uid]?.correct ?? 0,
              ),
          }),
    end: end,
    settledOnServer: snapshot.settled,
  );
}

MatchPhase _phaseAfter(MatchEndReason reason) => switch (reason) {
  MatchEndReason.aborted => MatchPhase.aborted,
  MatchEndReason.voided => MatchPhase.voided,
  _ => MatchPhase.finished,
};

MatchState _show(MatchState state, ShownQuestion question) {
  if (question.q < state.q) return state;
  final sameQuestion = state.question?.q == question.q;
  return state._copy(
    phase: MatchPhase.qOpen,
    q: question.q,
    total: question.total,
    limitMs: question.limitMs,
    question: question,
    endsAt: question.deadlineAt,
    answered: sameQuestion ? state.answered : const {},
  );
}

MatchState _progress(MatchState state, QProgressEvent progress, String me) {
  if (progress.q != state.q) return state;
  final mine = progress.answered.contains(me) && !state.mine.containsKey(progress.q)
      ? {
          ...state.mine,
          progress.q: MyAnswer(q: progress.q, opt: null, status: AnswerStatus.unknown),
        }
      : null;
  return state._copy(answered: progress.answered.toSet(), mine: mine);
}

MatchState _ack(MatchState state, AnsAckEvent ack) {
  final current = state.mine[ack.q];
  // The status is the verdict, also on a repeat (`dup: true`). Only an older server's
  // `status: "dup"` carries none: then keep the verdict we have, if any.
  final keepVerdict = ack.status == AnswerStatus.dup && current != null && current.status.isVerdict;
  final status = keepVerdict ? current.status : ack.status;
  return state._copy(
    mine: {
      ...state.mine,
      ack.q: MyAnswer(q: ack.q, opt: current?.opt, status: status),
    },
  );
}

MatchState _reveal(MatchState state, RevealResult reveal, String me) {
  if (reveal.q < state.q) return state;
  final myPick = reveal.players[me]?.opt;
  final current = state.mine[reveal.q];
  final mine = myPick != null && current?.opt == null
      ? {
          ...state.mine,
          reveal.q: MyAnswer(
            q: reveal.q,
            opt: myPick,
            status: current?.status ?? AnswerStatus.unknown,
          ),
        }
      : null;
  return state._copy(
    phase: MatchPhase.qReveal,
    q: reveal.q,
    endsAt: null,
    reveal: reveal,
    standings: reveal.standings.isEmpty ? null : reveal.standings,
    totals: reveal.totals.isEmpty ? null : reveal.totals,
    mine: mine,
  );
}

MatchState _rematch(MatchState state, RematchStatusEvent event, String me) {
  final rematch = switch (event.state) {
    RematchState.offered => event.by == me ? Rematch.offeredByMe : Rematch.offeredByThem,
    RematchState.accepted => Rematch.accepted,
    RematchState.declined => Rematch.declined,
    RematchState.expired => Rematch.expired,
    RematchState.failed => Rematch.failed,
    RematchState.unknown => null,
  };
  if (rematch == null) return state;
  return state._copy(
    rematch: rematch,
    rematchFailure: rematch == Rematch.failed ? event.reason : null,
  );
}

MatchState _presence(MatchState state, OppConnEvent event) {
  final player = state.players[event.uid] ?? MatchPlayer(card: PlayerCard(uid: event.uid));
  return state._copy(
    players: {...state.players, event.uid: player._withPresence(event.presence, event.graceUntil)},
  );
}

MatchState _end(MatchState state, MatchEndEvent event) => state._copy(
  phase: _phaseAfter(event.reason),
  endsAt: null,
  end: event.outcome,
  endedAt: event.ts,
  totals: event.totals.isEmpty ? null : event.totals,
);
