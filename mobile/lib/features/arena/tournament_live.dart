import 'dart:async';

import 'package:design_system/design_system.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:realtime_client/realtime_client.dart' as rt;

import '../../app/live/live_hub.dart';
import '../../app/router.dart';
import '../../core/auth/session.dart';
import '../../core/auth/user.dart';
import '../../core/network/app_failure.dart';
import '../../core/realtime/live_controller.dart';
import '../../core/realtime/live_match.dart' show MatchView;
import '../../core/realtime/live_text.dart';
import '../../core/realtime/realtime_providers.dart';
import '../../core/utils/time_text.dart';
import '../leaderboards/data/leaderboard_models.dart' show PlayerCard;
import 'arena_providers.dart';
import 'data/tournament_models.dart';
import 'data/tournament_repository.dart';
import 'tournament_reminders.dart';

/// A player card from the socket, as the Arena shows players.
PlayerCard playerFromSocket(rt.PlayerCard card) => PlayerCard(
  id: card.uid,
  handle: card.handle,
  displayName: card.displayName ?? card.handle ?? 'Player',
  avatar: Avatar.parse(card.raw['avatar']),
  level: card.level,
);

/// A round's state from `t.round`.
@immutable
class RoundInfo {
  const RoundInfo({required this.round, required this.status, this.startsAt, this.endsAt});

  final int round;
  final RoundStatus status;

  /// When the round's games start (the pairing countdown runs to it).
  final DateTime? startsAt;
  final DateTime? endsAt;
}

/// What the live connection said about one tournament the viewer is in.
@immutable
class TournamentLive {
  const TournamentLive({
    required this.id,
    this.title,
    this.running = false,
    this.round,
    this.pairing,
    this.result,
    this.cancelled = false,
  });

  final String id;
  final String? title;

  /// The viewer is playing it and it's on (the "Tournament live" pill).
  final bool running;
  final RoundInfo? round;

  /// The latest call: a game to join, or a bye.
  final Pairing? pairing;
  final TournamentFinal? result;
  final bool cancelled;

  TournamentLive copyWith({
    String? title,
    bool? running,
    RoundInfo? round,
    Pairing? Function()? pairing,
    TournamentFinal? result,
    bool? cancelled,
  }) => TournamentLive(
    id: id,
    title: title ?? this.title,
    running: running ?? this.running,
    round: round ?? this.round,
    pairing: pairing == null ? this.pairing : pairing(),
    result: result ?? this.result,
    cancelled: cancelled ?? this.cancelled,
  );
}

@immutable
class TournamentLiveState {
  const TournamentLiveState({this.byId = const {}, this.matchToTournament = const {}});

  final Map<String, TournamentLive> byId;

  /// Which tournament each round's game belongs to, for the result screen's way back.
  final Map<String, String> matchToTournament;

  TournamentLive? operator [](String id) => byId[id];

  String? tournamentOf(String matchId) => matchToTournament[matchId];

  /// The tournament the viewer is playing right now, if any.
  TournamentLive? get running => byId.values.where((t) => t.running).firstOrNull;
}

/// The live side of the Arena: rounds, pairings, byes and results from the connection, and the
/// "Tournament live" pill on every screen but the tournament's own and its games.
class TournamentLiveNotifier extends Notifier<TournamentLiveState> {
  bool _pillShown = false;

  @override
  TournamentLiveState build() {
    final router = ref.watch(routerProvider);
    void onRoute() => _later(_syncPill);
    router.routerDelegate.addListener(onRoute);
    // Another user signing in clears the pill (`RealtimeHost`).
    ref.onDispose(() => router.routerDelegate.removeListener(onRoute));
    // Someone else signing in starts from nothing.
    ref.watch(currentUserIdProvider);
    return const TournamentLiveState();
  }

  TournamentLive _of(String id) => state.byId[id] ?? TournamentLive(id: id);

  void _put(TournamentLive live, {Map<String, String>? matches}) {
    state = TournamentLiveState(
      byId: {...state.byId, live.id: live},
      matchToTournament: matches ?? state.matchToTournament,
    );
    _later(_syncPill);
  }

  /// The tournament's name, for alerts about it.
  void remember(String id, String title) {
    if (_of(id).title == title) return;
    _put(_of(id).copyWith(title: title));
  }

  /// The viewer is in [id] and it's running (from `welcome.active`, or the detail screen).
  void markRunning(String id, {String? title, bool running = true}) {
    final live = _of(id);
    if (live.running == running && (title == null || live.title == title)) return;
    _put(live.copyWith(running: running, title: title));
  }

  void onRound(String id, RoundInfo round) => _put(_of(id).copyWith(round: round, running: true));

  void onPairing(String id, Pairing pairing) => _put(
    _of(id).copyWith(pairing: () => pairing, running: true),
    matches: {...state.matchToTournament, ?pairing.matchId: id},
  );

  void onFinished(String id, TournamentFinal result) =>
      _put(_of(id).copyWith(result: result, running: false, pairing: () => null));

  void onCancelled(String id) =>
      _put(_of(id).copyWith(cancelled: true, running: false, pairing: () => null));

  /// Runs [change] now, or after the frame when one is being built.
  void _later(void Function() change) {
    if (SchedulerBinding.instance.schedulerPhase != SchedulerPhase.persistentCallbacks) {
      change();
      return;
    }
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (ref.mounted) change();
    });
  }

  /// "Tournament live" on every screen except the tournament itself and its games. A search
  /// pill wins (it can't happen during a tournament anyway).
  void _syncPill() {
    if (!ref.mounted) return;
    final hub = ref.read(liveHubProvider.notifier);
    final current = ref.read(liveHubProvider).status;
    final live = state.running;
    final path = currentPath(ref.read(routerProvider));
    final show =
        live != null &&
        !path.startsWith(Routes.tournament(live.id)) &&
        !Routes.isBattleMatch(path) &&
        (current == null || _pillShown);
    if (!show) {
      if (_pillShown && (current?.route?.startsWith('${Routes.arena}/') ?? false)) {
        hub.setStatus(null);
      }
      _pillShown = false;
      return;
    }
    hub.setStatus(
      LiveStatus(label: 'Tournament live', route: Routes.tournament(live.id), icon: AppIcons.arena),
    );
    _pillShown = true;
  }
}

final tournamentLiveProvider = NotifierProvider<TournamentLiveNotifier, TournamentLiveState>(
  TournamentLiveNotifier.new,
);

/// One line of the live standings (`t.standings` rows).
@immutable
class LiveStandingRow {
  const LiveStandingRow({
    required this.rank,
    required this.uid,
    required this.name,
    this.points = 0,
    this.avatar = Avatar.fallback,
    this.record,
  });

  factory LiveStandingRow.fromSocket(rt.StandingRow row) {
    final raw = row.raw;
    int? count(String key) => raw[key] is num ? (raw[key]! as num).toInt() : null;
    final w = count('w');
    final d = count('d');
    final l = count('l');
    return LiveStandingRow(
      rank: row.rank ?? 0,
      uid: row.uid ?? '',
      name: row.name ?? (raw['handle'] is String ? raw['handle']! as String : 'Player'),
      points: row.points ?? 0,
      avatar: Avatar.parse(raw['avatar']),
      record: w == null && d == null && l == null
          ? null
          : TournamentRecord(wins: w ?? 0, draws: d ?? 0, losses: l ?? 0),
    );
  }

  final int rank;
  final String uid;
  final String name;
  final num points;
  final Avatar avatar;
  final TournamentRecord? record;
}

@immutable
class LiveStandings {
  const LiveStandings({required this.round, required this.rows, this.me});

  final int round;
  final List<LiveStandingRow> rows;
  final LiveStandingRow? me;
}

/// The live standings of a tournament while a screen shows them: `sub {"ch": "t:<id>"}` when
/// the first screen watches, `unsub` when the last one goes. `t:` channels aren't resumed, so a
/// reconnect subscribes again (see [TournamentLiveHook.onWelcome]).
final liveStandingsProvider = NotifierProvider.autoDispose
    .family<LiveStandingsNotifier, LiveStandings?, String>(LiveStandingsNotifier.new);

class LiveStandingsNotifier extends Notifier<LiveStandings?> {
  LiveStandingsNotifier(this.id);

  final String id;

  String get channel => 't:$id';

  @override
  LiveStandings? build() {
    final connection = ref.watch(realtimeConnectionProvider);
    if (connection == null) return null;
    scheduleMicrotask(subscribe);
    ref.onDispose(() {
      if (connection.state is rt.Terminal) return;
      unawaited(
        connection
            .request('unsub', {'ch': channel})
            .then<void>((_) {}, onError: (Object error) => debugPrint('unsub $channel: $error')),
      );
    });
    return null;
  }

  /// Asks for the standings (again). The reply is a `t.standings`, which [apply] takes.
  Future<void> subscribe() async {
    if (!ref.mounted) return;
    final connection = ref.read(realtimeConnectionProvider);
    if (connection == null) return;
    try {
      await connection.request('sub', {'ch': channel});
    } on rt.RealtimeError catch (error) {
      // Offline or not found: the REST standings stay on screen.
      debugPrint('sub $channel: ${error.code}');
    }
  }

  void apply(rt.TStandingsEvent event) {
    state = LiveStandings(
      round: event.round,
      rows: [for (final row in event.rows) LiveStandingRow.fromSocket(row)],
      me: event.me == null ? null : LiveStandingRow.fromSocket(event.me!),
    );
  }
}

/// Puts the tournament events of the live connection to work (`docs/protocol.md` §9):
/// - `t.check_in`: a banner with **Check in** and **Can't make it**, never an automatic check-in;
/// - `t.pairing`: a full-screen "Round 2: you vs Aman · Join" on any screen (the round's game is
///   opened at once, so its first frames aren't lost);
/// - `t.bye`, `t.at_risk`, `t.finished`, `t.cancelled`: notices that explain what happened;
/// - `t.round` and `t.standings`: the lobby and the standings.
///
/// After every (re)connect it re-subscribes to standings on screen, notes running tournaments
/// from `welcome.active`, and brings back a check-in banner missed while away.
class TournamentLiveHook implements LiveEventHook {
  TournamentLiveHook(this._ref);

  final Ref _ref;
  LiveController? _controller;

  @override
  void attach(LiveController controller) => _controller = controller;

  LiveHub get _hub => _ref.read(liveHubProvider.notifier);

  TournamentLiveNotifier get _live => _ref.read(tournamentLiveProvider.notifier);

  TournamentActions get _actions => _ref.read(tournamentActionsProvider);

  DateTime get _now => _ref.read(liveClockProvider)();

  String _path() => currentPath(_ref.read(routerProvider));

  /// A server time (ms) on this phone's clock.
  DateTime _local(int serverMs) {
    final connection = _ref.read(realtimeConnectionProvider);
    final serverNow = connection?.serverClock.nowServerMs() ?? _now.millisecondsSinceEpoch;
    return _now.add(Duration(milliseconds: serverMs - serverNow));
  }

  String _title(String id, [String? given]) {
    if (given != null && given.isNotEmpty) {
      _live.remember(id, given);
      return given;
    }
    return _ref.read(tournamentLiveProvider)[id]?.title ?? 'Your tournament';
  }

  @override
  void onEvent(rt.ServerEvent event) {
    switch (event) {
      case rt.TStandingsEvent(:final tournamentId?):
        if (_ref.exists(liveStandingsProvider(tournamentId))) {
          _ref.read(liveStandingsProvider(tournamentId).notifier).apply(event);
        }
      case rt.TRoundEvent(:final channel?) when channel.startsWith('t:'):
        final id = channel.substring(2);
        _live.onRound(
          id,
          RoundInfo(
            round: event.round,
            status: RoundStatus.parse(event.status),
            startsAt: event.startsAt == null ? null : _local(event.startsAt!),
            endsAt: event.endsAt == null ? null : _local(event.endsAt!),
          ),
        );
        _actions.refresh(id);
      case rt.TCheckInEvent():
        _showCheckIn(
          event.tournamentId,
          title: _title(event.tournamentId, event.title),
          startsAt: event.startsAt == null ? null : _local(event.startsAt!),
          closesAt: event.closesAt == null ? null : _local(event.closesAt!),
        );
      case rt.TAtRiskEvent(:final tournamentId, :final needed):
        _hub.show(
          LiveAlert(
            id: TournamentAlertIds.atRisk(tournamentId),
            title: needed == null
                ? 'At risk: more players needed'
                : 'At risk: $needed more ${needed == 1 ? 'player' : 'players'} needed',
            message: 'Invite friends so ${_title(tournamentId)} can start.',
            icon: AppIcons.userAdd,
            tone: PastelTone.peach,
            primary: const LiveAction('Invite friends', route: Routes.social),
            secondary: LiveAction('Open', route: Routes.tournament(tournamentId)),
          ),
        );
        _actions.refresh(tournamentId);
      case rt.TCheckedInEvent(:final tournamentId):
        _hub.dismiss(TournamentAlertIds.checkIn(tournamentId));
        _actions.refresh(tournamentId);
      case rt.TPairingEvent(:final tournamentId?, :final round?) when event.bye:
        _onBye(tournamentId, round, 1);
      case rt.TPairingEvent(:final tournamentId?, :final matchId?):
        _onPairing(event, tournamentId, matchId);
      case rt.TByeEvent(:final tournamentId, :final round, :final points):
        _onBye(tournamentId, round, points);
      case rt.TFinishedEvent():
        _onFinished(event);
      case rt.TCancelledEvent(:final tournamentId, :final reason, :final refunded):
        _live.onCancelled(tournamentId);
        _hub
          ..dismiss(TournamentAlertIds.checkIn(tournamentId))
          ..show(
            LiveAlert(
              id: TournamentAlertIds.cancelled(tournamentId),
              title: 'Cancelled: ${_title(tournamentId)}',
              message: cancelledMessage(reason, refunded),
              icon: AppIcons.info,
              tone: PastelTone.peach,
              primary: LiveAction('Details', route: Routes.tournament(tournamentId)),
            ),
          );
        unawaited(_ref.read(tournamentRemindersProvider).cancelFor(tournamentId));
        _actions
          ..refresh(tournamentId)
          ..refreshLists();
      default:
        break;
    }
  }

  void _showCheckIn(String id, {required String title, DateTime? startsAt, DateTime? closesAt}) {
    Future<void> guarded(Future<void> Function() action) async {
      try {
        await action();
      } on AppFailure catch (failure) {
        _hub.show(
          LiveAlert(
            id: '${TournamentAlertIds.checkIn(id)}-failed',
            title: 'Couldn\'t update $title',
            message: arenaErrorMessage(failure),
            icon: AppIcons.alert,
            tone: PastelTone.peach,
          ),
        );
      }
    }

    _hub.show(
      LiveAlert(
        id: TournamentAlertIds.checkIn(id),
        title: 'Check in for $title',
        message: startsAt == null ? 'Check-in is open now' : 'Starts at ${clockTime(startsAt)}',
        icon: AppIcons.arena,
        priority: LivePriority.checkIn,
        expiresAt: closesAt,
        primary: LiveAction('Check in', run: () => guarded(() => _actions.checkIn(id))),
        secondary: LiveAction(
          'Can\'t make it',
          run: () => guarded(() async => _actions.withdraw(id)),
        ),
      ),
    );
  }

  void _onPairing(rt.TPairingEvent event, String id, String matchId) {
    final round = event.round ?? 1;
    final opponent = event.opponent == null ? null : playerFromSocket(event.opponent!);
    final readyBy = event.readyBy == null
        ? _now.add(const Duration(seconds: 90))
        : _local(event.readyBy!);
    _live.onPairing(
      id,
      Pairing(round: round, opponent: opponent, matchId: matchId, readyBy: readyBy),
    );
    // Follow the game now: its first frames arrive before the player taps Join.
    final controller = _controller;
    if (controller != null && !controller.isDisposed) controller.openMatch(matchId);
    _actions.refresh(id);
    if (Routes.isBattleMatch(_path(), matchId)) return;
    final name = opponent?.displayName ?? 'your opponent';
    _hub.show(
      LiveAlert(
        id: TournamentAlertIds.pairing(id, round),
        title: 'Round $round: you vs $name',
        message: '${_title(id)} · join within ${readyBy.difference(_now).inSeconds.clamp(0, 90)} s',
        icon: AppIcons.arena,
        style: AlertStyle.takeover,
        priority: LivePriority.roundJoin,
        expiresAt: readyBy,
        primary: LiveAction('Join', route: Routes.battleMatch(matchId)),
      ),
    );
  }

  void _onBye(String id, int round, num points) {
    _live.onPairing(id, Pairing(round: round, bye: true));
    _actions.refresh(id);
    _hub.show(
      LiveAlert(
        id: TournamentAlertIds.bye(id, round),
        title: 'Round $round: you have a bye',
        message: 'You have a bye this round (+${formatPoints(points)} point)',
        icon: AppIcons.hourglass,
        tone: PastelTone.mint,
        primary: LiveAction('Open', route: Routes.tournament(id)),
      ),
    );
  }

  void _onFinished(rt.TFinishedEvent event) {
    final id = event.tournamentId;
    final players = event.players ?? 0;
    _live.onFinished(
      id,
      TournamentFinal(
        rank: event.rank,
        players: players,
        points: event.points ?? 0,
        prize: event.prize,
        xp: event.xp,
      ),
    );
    _actions
      ..refresh(id)
      ..refreshLists();
    _ref.invalidate(myTournamentsProvider);
    if (_path() == Routes.tournamentResults(id)) return;
    _hub.show(
      LiveAlert(
        id: TournamentAlertIds.finished(id),
        title: players > 0
            ? 'You finished #${event.rank} of $players'
            : 'You finished #${event.rank}',
        message: [
          _title(id),
          if (event.prize > 0) '+${LiveText.coins(event.prize)}',
          if (event.xp > 0) '+${event.xp} XP',
        ].join(' · '),
        icon: AppIcons.award,
        tone: PastelTone.mint,
        primary: LiveAction('See results', route: Routes.tournamentResults(id)),
      ),
    );
  }

  @override
  void onWelcome(rt.WelcomeEvent welcome) {
    for (final entry in welcome.active.where((a) => a.kind == rt.ActiveKind.tournament)) {
      final id = entry.id ?? entry.channel?.replaceFirst('t:', '');
      if (id != null) _live.markRunning(id, title: entry.title);
    }
    // `t:` channels aren't resumed: ask again for every standings on screen.
    for (final id in _ref.read(tournamentLiveProvider).byId.keys) {
      if (_ref.exists(liveStandingsProvider(id))) {
        unawaited(_ref.read(liveStandingsProvider(id).notifier).subscribe());
      }
    }
    unawaited(_recoverCheckIns());
  }

  /// A `t.check_in` sent while the app was away is gone; REST still knows the window is open.
  Future<void> _recoverCheckIns() async {
    try {
      final page = await _ref.read(tournamentRepositoryProvider).mine();
      final now = _now;
      for (final item in page.items) {
        final t = item.tournament;
        _live.remember(t.id, t.title);
        if (t.entered && !t.checkedIn && t.checkInOpen(now)) {
          _showCheckIn(t.id, title: t.title, startsAt: t.startsAt, closesAt: t.checkInClosesAt);
        }
      }
    } on AppFailure catch (failure) {
      debugPrint('Couldn\'t check tournament check-ins: $failure');
    }
  }
}

/// Whether [view] is a tournament round's game.
bool isTournamentGame(MatchView view) =>
    view.state.kind == 'tournament' || view.summary?.kind == 'tournament';

/// Where a tournament game's result screen leads back to: its tournament (the lobby), or the
/// Arena when this device didn't see the pairing. Null for any other game.
String? tournamentRouteFor(WidgetRef ref, MatchView view) {
  if (!isTournamentGame(view)) return null;
  final id = ref.read(tournamentLiveProvider).tournamentOf(view.matchId);
  return id == null ? Routes.arena : Routes.tournament(id);
}

/// "Not enough players. Your 15 coins are back."
String cancelledMessage(String? reason, int refunded) {
  final why = switch (reason) {
    'not_enough_players' => 'Not enough players.',
    'admin' => 'The organisers called it off.',
    _ => 'It won\'t go ahead.',
  };
  final coins = refunded > 0
      ? 'Your ${LiveText.coins(refunded)} are back.'
      : 'Nothing was charged.';
  return '$why $coins';
}
