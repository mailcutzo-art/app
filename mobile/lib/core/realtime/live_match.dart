import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:realtime_client/realtime_client.dart';

import '../../features/battle/data/battle_repository.dart';
import '../../features/battle/data/match_models.dart';
import '../network/app_failure.dart';
import 'search_state.dart';

/// What `mm.found` said about a match: the opponent's rating and record, where the questions come
/// from, and the settings for "Play again". Memory only.
@immutable
class MatchIntro {
  const MatchIntro({
    required this.matchId,
    this.opponent,
    this.sources = const [],
    this.bot = false,
    this.mode,
    this.request,
  });

  factory MatchIntro.fromFound(MmFoundEvent event, {SearchRequest? request}) {
    final bot = event.bot || event.opponent.isBot;
    return MatchIntro(
      matchId: event.matchId,
      opponent: event.opponent,
      sources: event.sources,
      bot: bot,
      mode: bot ? 'bot' : (event.mode ?? request?.mode),
      request: request == null ? null : (bot ? request.withMode('bot') : request),
    );
  }

  final String matchId;
  final PlayerCard? opponent;
  final List<SourceChapter> sources;
  final bool bot;

  /// `rated`, `casual` or `bot`.
  final String? mode;

  /// How the game was asked for, so "Play again" can ask again.
  final SearchRequest? request;
}

/// Where the rewards of a finished game stand.
enum SettlementStatus {
  /// Not over, or waiting for `match.settled`.
  waiting,

  /// Reading `GET /v1/matches/{id}`.
  fetching,

  /// The server has the result but is still settling it: "Rewards will appear shortly".
  later,

  /// Reading it failed; another try is scheduled.
  failed,

  /// The settlement is here, or none is coming (an aborted or voided game).
  done,
}

/// Everything the match screen shows, rebuilt on every change.
@immutable
class MatchView {
  const MatchView({
    required this.matchId,
    required this.me,
    required this.state,
    this.intro,
    this.reveals = const {},
    this.visibleQ = 0,
    this.closedQ = 0,
    this.readySent = false,
    this.settlementStatus = SettlementStatus.waiting,
    this.restSettlement,
    this.summary,
    this.loadFailed = false,
    this.leaving = false,
    this.rematchError,
  });

  final String matchId;

  /// The signed-in user's uid.
  final String me;

  /// The reduced server state.
  final MatchState state;
  final MatchIntro? intro;

  /// Every reveal seen on this device, by question, for the result dots.
  final Map<int, RevealResult> reveals;

  /// The question whose `shown_at` has passed on the synced clock. Nothing of a question shows
  /// before that.
  final int visibleQ;

  /// The question whose deadline has passed on this device.
  final int closedQ;

  /// `match.ready` was sent.
  final bool readySent;
  final SettlementStatus settlementStatus;

  /// The settlement read over REST when `match.settled` didn't come.
  final Settlement? restSettlement;

  /// `GET /v1/matches/{id}`, when it was read.
  final MatchSummary? summary;

  /// Nothing could be loaded for a match opened from a link or after a restart.
  final bool loadFailed;

  /// The user chose to leave (`match.forfeit` sent).
  final bool leaving;

  /// Why the last rematch request failed, in words.
  final String? rematchError;

  MatchPhase get phase {
    final phase = state.phase;
    if (phase != MatchPhase.unknown) return phase;
    return switch (summary?.status) {
      MatchStatus.aborted => MatchPhase.aborted,
      MatchStatus.voided => MatchPhase.voided,
      MatchStatus.settling || MatchStatus.settled => MatchPhase.finished,
      _ => MatchPhase.unknown,
    };
  }

  bool get isOver => phase.isOver;

  /// Whether live state has arrived (a snapshot or events).
  bool get hasLiveState => state.phase != MatchPhase.unknown;

  MatchPlayer? get opponent => state.opponentsOf(me).firstOrNull;

  PlayerCard? get opponentCard =>
      opponent?.card ?? intro?.opponent ?? summary?.opponents.firstOrNull;

  /// "Riya", "Practice Bot", or "Your opponent".
  String get opponentName {
    final card = opponentCard;
    if (isBot) return card?.displayName ?? 'Practice Bot';
    return card?.displayName ?? card?.handle ?? 'Your opponent';
  }

  PlayerCard? get myCard => state.players[me]?.card;

  /// The opponent's rating: `mm.found` carries it, snapshots don't.
  PlayerRating? get opponentRating => intro?.opponent?.rating ?? opponentCard?.rating;

  /// My head-to-head record against the opponent, from `mm.found`.
  HeadToHead? get opponentRecord => intro?.opponent?.record ?? opponentCard?.record;

  bool get isBot =>
      (intro?.bot ?? false) ||
      state.kind == 'bot' ||
      summary?.kind == 'bot' ||
      (opponentCard?.isBot ?? false);

  /// `rated`, `casual` or `bot`.
  String? get mode {
    if (isBot) return 'bot';
    final kind = state.kind ?? summary?.kind;
    return switch (kind) {
      'quick_rated' || 'tournament' => 'rated',
      'quick_casual' => 'casual',
      _ => intro?.mode,
    };
  }

  bool get isCasual => mode == 'casual';

  bool get isRated => mode == 'rated';

  Settlement? get settlement => state.settlement ?? restSettlement ?? summary?.settlement;

  MatchOutcome? get outcome => state.end ?? summary?.outcome(me: me);

  ShownQuestion? get question => state.question;

  /// Whether the current question may be on screen.
  bool get questionVisible {
    final question = state.question;
    if (question == null) return false;
    return visibleQ == question.q || state.currentReveal != null;
  }

  PlayerTotals get myTotals => state.totalsOf(me);

  PlayerTotals get opponentTotals {
    final uid = opponentCard?.uid;
    return uid == null ? PlayerTotals.zero : state.totalsOf(uid);
  }

  /// Waiting on rewards: "Results syncing…".
  bool get syncing =>
      phase == MatchPhase.finished &&
      settlement == null &&
      settlementStatus != SettlementStatus.later;

  MatchView copyWith({
    MatchState? state,
    Map<int, RevealResult>? reveals,
    int? visibleQ,
    int? closedQ,
    bool? readySent,
    SettlementStatus? settlementStatus,
    Settlement? restSettlement,
    MatchSummary? summary,
    bool? loadFailed,
    bool? leaving,
    Object? rematchError = _keep,
  }) => MatchView(
    matchId: matchId,
    me: me,
    state: state ?? this.state,
    intro: intro,
    reveals: reveals ?? this.reveals,
    visibleQ: visibleQ ?? this.visibleQ,
    closedQ: closedQ ?? this.closedQ,
    readySent: readySent ?? this.readySent,
    settlementStatus: settlementStatus ?? this.settlementStatus,
    restSettlement: restSettlement ?? this.restSettlement,
    summary: summary ?? this.summary,
    loadFailed: loadFailed ?? this.loadFailed,
    leaving: leaving ?? this.leaving,
    rematchError: identical(rematchError, _keep) ? this.rematchError : rematchError as String?,
  );
}

const Object _keep = Object();

/// One live match on this device: feeds its events through `reduceMatch`, holds the in-match
/// lease, times when each question may show, sends ready, answers, emotes and forfeits, and reads
/// the result over REST when `match.settled` doesn't arrive.
class LiveMatch extends ChangeNotifier {
  LiveMatch({
    required this.matchId,
    required this.me,
    required RealtimeConnection connection,
    required this._matches,
    MatchIntro? intro,
    this.settleWait = const Duration(seconds: 20),
    this.retryDelays = const [
      Duration(seconds: 5),
      Duration(seconds: 10),
      Duration(seconds: 20),
      Duration(seconds: 30),
    ],
  }) : _connection = connection,
       _view = MatchView(
         matchId: matchId,
         me: me,
         state: MatchState.initial(matchId),
         intro: intro,
       ) {
    _lease = connection.acquire('match:$matchId', inMatch: true);
  }

  final String matchId;
  final String me;
  final RealtimeConnection _connection;
  final MatchRepository Function() _matches;

  /// How long after `match.end` the app waits for `match.settled` before reading REST.
  final Duration settleWait;

  /// Waits between REST retries; the last one repeats.
  final List<Duration> retryDelays;

  static const emoteGapMs = 3000;
  static const maxEmotes = 10;

  MatchView _view;
  RealtimeLease? _lease;
  bool _disposed = false;
  bool _onScreen = false;
  bool _readyInFlight = false;
  bool _overHandled = false;
  bool _fetching = false;
  int _retries = 0;
  int _emotes = 0;
  int? _lastEmoteMs;
  Timer? _visibleTimer;
  Timer? _deadlineTimer;
  Timer? _settleTimer;
  Timer? _retryTimer;

  MatchView get view => _view;

  bool get isDisposed => _disposed;

  bool get isOver => _view.isOver;

  int get _serverNow => _connection.serverClock.nowServerMs();

  // ------------------------------------------------------------------------------------------
  // Server events

  /// Applies one event on this match's channel (shared or per-player).
  void apply(ServerEvent event) {
    if (_disposed) return;
    final before = _view.state;
    final next = reduceMatch(before, event, me: me);
    var reveals = _view.reveals;
    switch (event) {
      case QRevealEvent(:final reveal):
        reveals = {...reveals, reveal.q: reveal};
      case MatchSnapshotEvent(reveal: final reveal?):
        reveals = {...reveals, reveal.q: reveal};
      default:
        break;
    }
    if (identical(next, before) && identical(reveals, _view.reveals)) return;
    _set(_view.copyWith(state: next, reveals: reveals));
    _afterChange(before, next);
  }

  void _afterChange(MatchState before, MatchState next) {
    final question = next.question;
    if (question != null &&
        (question.q != before.question?.q || question.shownAt != before.question?.shownAt)) {
      _scheduleQuestion(question);
    }
    if (next.phase == MatchPhase.readyWait && _onScreen) unawaited(_sendReady());
    if (next.isOver) _onOver();
    if (next.settlement != null && before.settlement == null) _settled();
    if (next.settledOnServer && next.settlement == null && _view.restSettlement == null) {
      unawaited(fetchSettlement());
    }
  }

  void _scheduleQuestion(ShownQuestion question) {
    _visibleTimer?.cancel();
    _deadlineTimer?.cancel();
    final now = _serverNow;
    final untilShown = question.shownAt - now;
    if (untilShown <= 0) {
      _set(_view.copyWith(visibleQ: question.q));
    } else {
      _visibleTimer = Timer(Duration(milliseconds: untilShown), () {
        if (!_disposed && _view.state.question?.q == question.q) {
          _set(_view.copyWith(visibleQ: question.q));
        }
      });
    }
    final untilDeadline = question.deadlineAt - now;
    if (untilDeadline <= 0) {
      _set(_view.copyWith(closedQ: question.q));
    } else {
      _deadlineTimer = Timer(Duration(milliseconds: untilDeadline), () {
        if (!_disposed && _view.state.question?.q == question.q) {
          _set(_view.copyWith(closedQ: question.q));
        }
      });
    }
  }

  void _onOver() {
    if (_overHandled) return;
    _overHandled = true;
    _visibleTimer?.cancel();
    _deadlineTimer?.cancel();
    final state = _view.state;
    if (state.phase != MatchPhase.finished || state.settlement != null) {
      // Aborted and voided games settle nothing.
      _set(_view.copyWith(settlementStatus: SettlementStatus.done));
      _releaseLease();
      return;
    }
    if (state.needsSettlementFetch(_serverNow, waitMs: settleWait.inMilliseconds)) {
      unawaited(fetchSettlement());
      return;
    }
    final endedAt = state.endedAt ?? _serverNow;
    final waitMs = endedAt + settleWait.inMilliseconds - _serverNow;
    _settleTimer = Timer(Duration(milliseconds: waitMs.clamp(0, settleWait.inMilliseconds)), () {
      if (!_disposed && _view.settlement == null) unawaited(fetchSettlement());
    });
  }

  void _settled() {
    _settleTimer?.cancel();
    _retryTimer?.cancel();
    _set(_view.copyWith(settlementStatus: SettlementStatus.done));
    _releaseLease();
  }

  /// The connection changed state. A drop while waiting for rewards reads them over REST; a new
  /// connection sends a ready that didn't get through.
  void onConnectionState(ConnState state) {
    if (_disposed) return;
    switch (state) {
      case Backoff() || Idle() || Terminal():
        if (_view.phase == MatchPhase.finished && _view.settlement == null) {
          unawaited(fetchSettlement());
        }
      case Open():
        if (_view.state.phase == MatchPhase.readyWait && _onScreen) unawaited(_sendReady());
      case Ticketing() || Connecting():
        break;
    }
  }

  // ------------------------------------------------------------------------------------------
  // Actions

  /// The VS screen is showing: tell the server this player is ready.
  void markVsVisible() {
    if (_disposed || _onScreen) return;
    _onScreen = true;
    if (_view.state.phase == MatchPhase.readyWait) unawaited(_sendReady());
  }

  Future<void> _sendReady() async {
    if (_readyInFlight || _view.readySent || _disposed) return;
    _readyInFlight = true;
    _set(_view.copyWith(readySent: true));
    try {
      await _connection.request('match.ready', {'match_id': matchId});
    } on RealtimeError catch (error) {
      // Sent into a dropped connection: send it again once connected.
      if (!_disposed && (error.retryable || error.isClientSide)) {
        _set(_view.copyWith(readySent: false));
      }
    } finally {
      _readyInFlight = false;
    }
  }

  /// Picks option [optionId] of the open question. Shows it at once and sends it through the
  /// outbox, which resends it until the server answers. Returns false when the pick isn't allowed
  /// (not open yet, already answered, time's up).
  bool answer(String optionId) {
    if (_disposed) return false;
    final question = _view.state.question;
    if (question == null || !_view.questionVisible || _view.closedQ == question.q) return false;
    final next = selectAnswer(_view.state, q: question.q, opt: optionId);
    if (identical(next, _view.state)) return false;
    _set(_view.copyWith(state: next));
    final elapsed = question.elapsedMs(_serverNow);
    unawaited(_connection.submitAnswer(matchId, question.q, optionId, elapsed));
    return true;
  }

  /// Sends a reaction: at most one every 3 s and ten a game. Returns whether it went out.
  bool emote(String emote) {
    if (_disposed || _view.isOver || _emotes >= maxEmotes) return false;
    final now = _serverNow;
    final last = _lastEmoteMs;
    if (last != null && now - last < emoteGapMs) return false;
    _lastEmoteMs = now;
    _emotes++;
    unawaited(
      _connection
          .request('emote', {'match_id': matchId, 'e': emote})
          .then<void>((_) {}, onError: (Object _) {}),
    );
    return true;
  }

  /// Leaves the game: the server records a forfeit (a loss).
  Future<void> forfeit() async {
    if (_disposed || _view.isOver) return;
    _set(_view.copyWith(leaving: true));
    try {
      await _connection.request('match.forfeit', {'match_id': matchId});
    } on RealtimeError catch (error) {
      debugPrint('Forfeit of $matchId failed: $error');
    }
  }

  /// Offers (or accepts) a casual rematch; [accept] false declines one.
  Future<void> rematch({bool accept = true}) async {
    if (_disposed) return;
    _set(_view.copyWith(rematchError: null));
    try {
      await _connection.request('match.rematch', {'match_id': matchId, 'accept': accept});
    } on RealtimeError catch (error) {
      if (!_disposed) _set(_view.copyWith(rematchError: rematchErrorText(error)));
    }
  }

  // ------------------------------------------------------------------------------------------
  // REST

  /// Opens a match this device didn't see start (a restart, a link): asks the server for a
  /// snapshot and reads the result over REST, whichever answers.
  void resume() {
    if (_disposed) return;
    try {
      _connection.syncChannel('m:$matchId');
    } on Object catch (error) {
      debugPrint('Could not sync $matchId: $error');
    }
    unawaited(loadSummary());
  }

  /// Reads `GET /v1/matches/{id}` for a match opened without live state.
  Future<void> loadSummary() async {
    if (_disposed) return;
    if (_view.loadFailed) _set(_view.copyWith(loadFailed: false));
    try {
      final summary = await _matches().match(matchId);
      if (_disposed) return;
      _set(
        _view.copyWith(
          summary: summary,
          restSettlement: summary.settlement,
          settlementStatus: summary.settlement != null || !summary.isOver
              ? null
              : SettlementStatus.later,
        ),
      );
      if (summary.isOver) _releaseLease();
    } on AppFailure {
      if (!_disposed && !_view.hasLiveState) _set(_view.copyWith(loadFailed: true));
    }
  }

  /// Reads the settlement over REST, and keeps retrying until it has one.
  Future<void> fetchSettlement() async {
    if (_disposed || _fetching || _view.settlement != null) return;
    _fetching = true;
    _retryTimer?.cancel();
    _set(_view.copyWith(settlementStatus: SettlementStatus.fetching));
    try {
      final summary = await _matches().match(matchId);
      if (_disposed) return;
      final settlement = summary.settlement;
      _set(
        _view.copyWith(
          summary: summary,
          restSettlement: settlement,
          settlementStatus: settlement == null ? SettlementStatus.later : SettlementStatus.done,
        ),
      );
      if (settlement == null) {
        _scheduleRetry();
      } else {
        _releaseLease();
      }
    } on AppFailure {
      if (_disposed) return;
      _set(_view.copyWith(settlementStatus: SettlementStatus.failed));
      _scheduleRetry();
    } finally {
      _fetching = false;
    }
  }

  void _scheduleRetry() {
    final delay = retryDelays[_retries.clamp(0, retryDelays.length - 1)];
    _retries++;
    _retryTimer = Timer(delay, () {
      if (!_disposed && _view.settlement == null) unawaited(fetchSettlement());
    });
  }

  // ------------------------------------------------------------------------------------------

  void _set(MatchView view) {
    if (_disposed) return;
    _view = view;
    notifyListeners();
  }

  void _releaseLease() {
    _lease?.release();
    _lease = null;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _visibleTimer?.cancel();
    _deadlineTimer?.cancel();
    _settleTimer?.cancel();
    _retryTimer?.cancel();
    _releaseLease();
    super.dispose();
  }
}

/// What to say when a rematch request fails.
String rematchErrorText(RealtimeError error) => switch (error.code) {
  RealtimeErrorCode.insufficientCoins => 'You need 5 coins for a rematch.',
  RealtimeErrorCode.busy => 'You\'re busy with something else right now.',
  RealtimeErrorCode.notAllowed => 'A rematch isn\'t possible for this game.',
  _ => 'Couldn\'t ask for a rematch. Please try again.',
};
