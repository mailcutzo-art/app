import 'dart:async';

import 'package:design_system/design_system.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:realtime_client/realtime_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app/live/live_hub.dart';
import '../../app/router.dart';
import '../../features/battle/data/battle_repository.dart';
import '../auth/token_store.dart';
import '../network/api_client.dart';
import '../network/server_signals.dart';
import '../storage/prefs.dart';
import '../utils/ids.dart';
import 'live_match.dart';
import 'live_text.dart';
import 'search_state.dart';

/// Later phases (friend rooms, invites, tournaments, the inbox) plug into the live connection
/// here, without touching the battle router.
abstract interface class LiveEventHook {
  /// An event the battle router doesn't handle: `invite.*`, `room.*`, `t.*`, `notify`, …
  void onEvent(ServerEvent event);

  /// After every `welcome`, with everything the user is in (`welcome.active`).
  void onWelcome(WelcomeEvent welcome);
}

/// The hooks registered by later phases. None yet.
final liveEventHooksProvider = Provider<List<LiveEventHook>>((ref) => const []);

/// Ids of the alerts this controller puts on the live layer.
abstract final class LiveAlertIds {
  static const prefix = 'live.';
  static const timeout = '${prefix}mm-timeout';
  static const cancelled = '${prefix}mm-cancelled';
  static const requeued = '${prefix}mm-requeued';
  static const busy = '${prefix}busy';
  static const superseded = '${prefix}rt-superseded';
  static const liveElsewhere = '${prefix}rt-live-elsewhere';

  static String found(String matchId) => '${prefix}found-$matchId';

  static String rejoin(String matchId) => '${prefix}rejoin-$matchId';

  static String ended(String matchId) => '${prefix}ended-$matchId';

  static String rematch(String matchId) => '${prefix}rematch-$matchId';
}

/// Remembers the game in progress (its id only, never question content), so a restarted app
/// can reopen it or say how it ended.
class ActiveMatchMemory {
  ActiveMatchMemory(this._prefs, this.userId);

  final SharedPreferences? _prefs;
  final String userId;

  String get _key => 'battle.active_match.$userId';

  String? read() => _prefs?.getString(_key);

  void remember(String matchId) => unawaited(_prefs?.setString(_key, matchId));

  void forget([String? matchId]) {
    if (matchId != null && read() != matchId) return;
    unawaited(_prefs?.remove(_key));
  }
}

/// The app's side of the always-on connection, one per signed-in (and onboarded) user.
///
/// - Holds the shell lease while the app is in the foreground and reports foreground and
///   background to the server.
/// - Handles the terminal states: revoked, superseded, update required, live elsewhere.
/// - Listens to the connection's events once and routes them: `mm.*` to the search state and the
///   live layer (pill, "Match found!", notices), match channels to their [LiveMatch], and
///   everything else to [LiveEventHook]s.
/// - Reopens games listed in `welcome.active`.
class LiveController {
  LiveController(this._ref, this.connection, {required this.me, this._hooks = const []}) {
    _events = connection.events.listen(_onEvent);
    _states = connection.states.listen(_onState);
    _router = _ref.read(routerProvider);
    _router.routerDelegate.addListener(_onRoute);
    SharedPreferences? prefs;
    try {
      prefs = _ref.read(sharedPrefsProvider);
    } on Object {
      prefs = null;
    }
    memory = ActiveMatchMemory(prefs, me);
  }

  final Ref _ref;
  final RealtimeConnection connection;

  /// The signed-in user's uid.
  final String me;
  final List<LiveEventHook> _hooks;
  late final ActiveMatchMemory memory;

  /// The matchmaking state, for the search screen and the Battle tab.
  final ValueNotifier<SearchState> search = ValueNotifier(const SearchState());

  late final StreamSubscription<ServerEvent> _events;
  late final StreamSubscription<ConnState> _states;
  late final GoRouter _router;
  final Map<String, LiveMatch> _matches = {};
  RealtimeLease? _shell;
  bool _disposed = false;
  bool _pillShown = false;

  /// The user asked for a game to start now (a bot game, a rematch): open it without the
  /// "Match found!" card.
  bool _openNext = false;

  /// The settings of the last search, for games that start without one (a rematch).
  SearchRequest? _lastRequest;

  LiveHub get _hub => _ref.read(liveHubProvider.notifier);

  /// Runs [change] now, or after the frame when a frame is being built (route changes can be
  /// reported mid-build, and providers can't change then).
  void _later(void Function() change) {
    if (SchedulerBinding.instance.schedulerPhase != SchedulerPhase.persistentCallbacks) {
      change();
      return;
    }
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!_disposed) change();
    });
  }

  String get _path => currentPath(_router);

  int get _serverNow => connection.serverClock.nowServerMs();

  bool get isDisposed => _disposed;

  // ------------------------------------------------------------------------------------------
  // Foreground and the shell lease

  /// The app came to the foreground (or left it). In the foreground the shell lease keeps the
  /// connection open on every tab; in the background it is let go, and the connection's linger
  /// keeps a quick app switch cheap.
  void setForeground(bool foreground) {
    if (_disposed) return;
    connection.setAppForeground(foreground);
    if (foreground) {
      _shell ??= connection.acquire('shell');
      // A game on another device may have ended meanwhile: try again (without taking over).
      if (connection.state case Terminal(reason: LiveElsewhere())) connection.connect();
    } else {
      _shell?.release();
      _shell = null;
    }
  }

  // ------------------------------------------------------------------------------------------
  // Commands

  /// Starts a search (or a Practice Bot game). Completes once the server accepted it; throws the
  /// server's [RealtimeError] otherwise (a `BUSY` answer also shows "Go there").
  Future<void> join(SearchRequest request, {int? online, int? p50WaitS}) async {
    if (_disposed) throw const RealtimeError(code: RealtimeErrorCode.closed);
    final previous = search.value;
    _lastRequest = request;
    search.value = SearchState.joining(request, online: online, p50WaitS: p50WaitS);
    if (request.isBot) _openNext = true;
    try {
      await connection.request('mm.join', request.toJoin(randomHexId()));
    } on RealtimeError catch (error) {
      _openNext = false;
      if (search.value.phase == SearchPhase.joining) {
        search.value = previous.isSearching ? previous : search.value.joinFailed();
      }
      if (error.code == RealtimeErrorCode.busy) showBusy(error.active);
      rethrow;
    }
  }

  /// Cancels the search. If a match was found in the meantime, opens it instead.
  Future<void> cancelSearch() async {
    try {
      await connection.request('mm.cancel', const {});
    } on RealtimeError catch (error) {
      final matchId = error.matchId;
      if (error.code == RealtimeErrorCode.alreadyMatched && matchId != null) {
        openMatch(matchId);
        _router.go(Routes.battleMatch(matchId));
        return;
      }
      rethrow;
    }
  }

  /// Answers `mm.timeout`: `keep`, `bot`, `invite` or `cancel`.
  Future<void> respond(String choice) async {
    _hub.dismiss(LiveAlertIds.timeout);
    if (choice == 'keep') search.value = search.value.keepSearching();
    if (choice == 'bot') _openNext = true;
    try {
      await connection.request('mm.respond', {'choice': choice});
    } on RealtimeError {
      if (choice == 'bot') _openNext = false;
      rethrow;
    }
  }

  /// Plays again with a finished game's settings. Returns false, without asking the server, when
  /// this device doesn't know them (a game reopened after a restart): the Battle tab is the place
  /// to pick then.
  Future<bool> playAgain(MatchView view) async {
    final request = view.intro?.request ?? _lastRequest;
    if (request == null) return false;
    await join(view.isBot ? request.withMode('bot') : request);
    return true;
  }

  /// Accepts (or offers) a rematch; the new match opens as soon as it's made.
  Future<void> rematch(String matchId, {bool accept = true}) async {
    final match = _matches[matchId];
    if (match == null) return;
    if (accept) _openNext = true;
    _hub.dismiss(LiveAlertIds.rematch(matchId));
    await match.rematch(accept: accept);
  }

  /// The live match [matchId], if this device knows it.
  LiveMatch? match(String matchId) => _matches[matchId];

  /// The live match [matchId]; opened (a snapshot and the REST result are asked for) if this
  /// device didn't see it start.
  LiveMatch openMatch(String matchId) {
    final known = _matches[matchId];
    if (known != null && !known.isDisposed) return known;
    final match = _createMatch(matchId);
    // Outside any provider build: the snapshot request and the REST read start right after.
    scheduleMicrotask(() {
      if (!match.isDisposed) match.resume();
    });
    return match;
  }

  /// The result screen closed: stop following the match.
  void closeMatch(String matchId) {
    final match = _matches.remove(matchId);
    match?.dispose();
    connection.forgetChannel('m:$matchId');
    memory.forget(matchId);
    _hub
      ..dismiss(LiveAlertIds.found(matchId))
      ..dismiss(LiveAlertIds.rejoin(matchId))
      ..dismiss(LiveAlertIds.ended(matchId))
      ..dismiss(LiveAlertIds.rematch(matchId));
  }

  /// "You're already in a match" with **Go there**, for a `BUSY` answer.
  void showBusy(ActiveEntry? active) {
    if (active?.kind == ActiveKind.queue) {
      search.value = search.value.adoptQueue(ticketId: active?.id);
      _syncPill();
    }
    final route = _busyRoute(active);
    _hub.show(
      LiveAlert(
        id: LiveAlertIds.busy,
        title: LiveText.busyTitle(active?.kind),
        message: active?.title,
        icon: AppIcons.alert,
        tone: PastelTone.peach,
        primary: route == null ? null : LiveAction('Go there', route: route),
      ),
    );
  }

  String? _busyRoute(ActiveEntry? active) {
    final action = active?.raw['action'];
    if (action is Map && action['route'] is String) return action['route']! as String;
    final id = active?.id ?? active?.channel?.replaceFirst('m:', '');
    return switch (active?.kind) {
      ActiveKind.match when id != null => Routes.battleMatch(id),
      ActiveKind.queue => Routes.battleSearch,
      ActiveKind.room => Routes.battle,
      ActiveKind.tournament when id != null => '${Routes.arena}?t=${Uri.encodeQueryComponent(id)}',
      ActiveKind.tournament => Routes.arena,
      _ => null,
    };
  }

  // ------------------------------------------------------------------------------------------
  // Events

  void _onEvent(ServerEvent event) {
    if (_disposed) return;
    switch (event) {
      case MmQueuedEvent() ||
          MmStatusEvent() ||
          MmTimeoutEvent() ||
          MmCancelledEvent() ||
          MmRequeuedEvent():
        _onMatchmaking(event);
      case MmFoundEvent():
        _onFound(event);
      default:
        final channel = event.channel;
        if (channel != null && channel.startsWith('m:')) {
          final match = _matches[channel.substring(2)];
          if (match != null) {
            match.apply(event);
            _afterMatchEvent(match, event);
          }
          return;
        }
        if (event is AckEvent || event is ErrorEvent || event is UnknownEvent) return;
        for (final hook in _hooks) {
          hook.onEvent(event);
        }
    }
  }

  void _onMatchmaking(ServerEvent event) {
    final previous = search.value;
    search.value = reduceSearch(previous, event, nowServerMs: _serverNow);
    final onSearchScreen = _path == Routes.battleSearch;
    switch (event) {
      case MmQueuedEvent():
        _hub.dismiss(LiveAlertIds.cancelled);
      case MmTimeoutEvent() when !onSearchScreen:
        _hub.show(
          LiveAlert(
            id: LiveAlertIds.timeout,
            title: 'No one found yet',
            message: 'Play the Practice Bot now, or keep looking.',
            icon: AppIcons.search,
            tone: PastelTone.lavender,
            priority: LivePriority.rematch,
            primary: LiveAction('Play the bot', run: () => respond('bot')),
            secondary: LiveAction('Keep searching', run: () => respond('keep')),
          ),
        );
      case MmCancelledEvent(:final reason, :final refunded):
        _hub.dismiss(LiveAlertIds.timeout);
        if (reason != 'user' && !onSearchScreen) {
          _hub.show(
            LiveAlert(
              id: LiveAlertIds.cancelled,
              title: LiveText.cancelledTitle(reason),
              message: LiveText.cancelledMessage(reason, refunded),
              icon: AppIcons.info,
            ),
          );
        }
      case MmRequeuedEvent():
        _hub.show(
          const LiveAlert(
            id: LiveAlertIds.requeued,
            title: 'Your opponent didn\'t join',
            message: 'Searching again…',
            icon: AppIcons.search,
            tone: PastelTone.sky,
          ),
        );
        // Back from the VS screen of the match that fell through.
        final failed = previous.matchId;
        if (failed != null) {
          final onFailed = Routes.isBattleMatch(_path, failed);
          closeMatch(failed);
          if (onFailed) _router.go(Routes.battleSearch);
        }
      default:
        break;
    }
    _syncPill();
  }

  void _onFound(MmFoundEvent event) {
    final request = search.value.request ?? _lastRequest;
    final intro = MatchIntro.fromFound(event, request: request);
    search.value = reduceSearch(search.value, event, nowServerMs: _serverNow);
    _syncPill();
    _hub
      ..dismiss(LiveAlertIds.timeout)
      ..dismiss(LiveAlertIds.requeued);
    // Finished games give way to the new one.
    for (final old in _matches.values.where((m) => m.isOver).toList()) {
      if (!Routes.isBattleMatch(_path, old.matchId)) closeMatch(old.matchId);
    }
    if (!_matches.containsKey(event.matchId)) _createMatch(event.matchId, intro: intro);
    memory.remember(event.matchId);

    final path = _path;
    final direct = _openNext || path == Routes.battleSearch || Routes.isBattleMatch(path);
    _openNext = false;
    final route = Routes.battleMatch(event.matchId);
    if (direct) {
      _router.go(route);
      return;
    }
    final subject = intro.request?.subjectLabel;
    _hub.show(
      LiveAlert(
        id: LiveAlertIds.found(event.matchId),
        title: 'Match found!',
        message: LiveText.foundMessage(
          opponent: event.opponent.displayName ?? event.opponent.handle ?? 'your opponent',
          bot: intro.bot,
          subject: subject,
        ),
        icon: AppIcons.battle,
        tone: PastelTone.sky,
        style: AlertStyle.takeover,
        priority: LivePriority.matchFound,
        autoRunAfter: const Duration(seconds: 2),
        primary: LiveAction('Play now', route: route),
      ),
    );
  }

  void _afterMatchEvent(LiveMatch match, ServerEvent event) {
    if (event is! RematchStatusEvent) return;
    final view = match.view;
    final id = match.matchId;
    // The result screen has its own Accept; anywhere else (the review too) gets a banner.
    if (view.state.rematch == Rematch.offeredByThem && _path != Routes.battleMatch(id)) {
      _hub.show(
        LiveAlert(
          id: LiveAlertIds.rematch(id),
          title: '${view.opponentName} wants a rematch',
          message: 'Casual · ${LiveText.coins(5)} entry',
          icon: AppIcons.refresh,
          tone: PastelTone.lavender,
          priority: LivePriority.rematch,
          primary: LiveAction('Accept', run: () => rematch(id)),
          secondary: LiveAction('Decline', run: () => rematch(id, accept: false)),
        ),
      );
    } else if (view.state.rematch != Rematch.offeredByThem) {
      _hub.dismiss(LiveAlertIds.rematch(id));
    }
  }

  LiveMatch _createMatch(String matchId, {MatchIntro? intro}) {
    final match = LiveMatch(
      matchId: matchId,
      me: me,
      connection: connection,
      matches: () => _ref.read(matchRepositoryProvider),
      intro: intro,
    );
    _matches[matchId] = match;
    return match;
  }

  // ------------------------------------------------------------------------------------------
  // Connection states

  void _onState(ConnState state) {
    if (_disposed) return;
    for (final match in _matches.values.toList()) {
      match.onConnectionState(state);
    }
    switch (state) {
      case Open(:final welcome):
        _hub
          ..dismiss(LiveAlertIds.superseded)
          ..dismiss(LiveAlertIds.liveElsewhere);
        _onWelcome(welcome);
      case Terminal(:final reason):
        _onTerminal(reason);
      default:
        break;
    }
  }

  void _onWelcome(WelcomeEvent welcome) {
    final active = welcome.active;
    final queue = active.where((a) => a.kind == ActiveKind.queue).firstOrNull;
    final current = search.value;
    if (queue != null) {
      search.value = current.adoptQueue(ticketId: queue.id);
    } else if (current.isSearching) {
      // The server let the search go while the app was away.
      search.value = current.stoppedWhileAway();
      if (_path != Routes.battleSearch) {
        _hub.show(
          LiveAlert(
            id: LiveAlertIds.cancelled,
            title: LiveText.cancelledTitle('away'),
            message: LiveText.cancelledMessage('away', 0),
            icon: AppIcons.info,
          ),
        );
      }
    }

    final live = <String>{};
    for (final entry in active.where((a) => a.kind == ActiveKind.match)) {
      final channel = entry.channel ?? (entry.id == null ? null : 'm:${entry.id}');
      if (channel == null || !channel.startsWith('m:')) continue;
      final id = channel.substring(2);
      live.add(id);
      var match = _matches[id];
      if (match == null) {
        // A cold start: ask for a snapshot to rebuild the game.
        match = _createMatch(id);
        connection.syncChannel(channel);
        memory.remember(id);
      }
      if (!Routes.isBattleMatch(_path, id) && !match.isOver) {
        _hub.show(
          LiveAlert(
            id: LiveAlertIds.rejoin(id),
            title: 'Your game is still on',
            message: 'Jump back in before the time runs out.',
            icon: AppIcons.battle,
            tone: PastelTone.sky,
            style: AlertStyle.takeover,
            priority: LivePriority.liveGame,
            primary: LiveAction('Rejoin', route: Routes.battleMatch(id)),
          ),
        );
      }
    }

    // A game this device remembers but the server no longer lists ended while the app was away.
    final remembered = memory.read();
    if (remembered != null && !live.contains(remembered) && !_matches.containsKey(remembered)) {
      _hub.show(
        LiveAlert(
          id: LiveAlertIds.ended(remembered),
          title: 'Your last game ended',
          message: 'See how it went.',
          icon: AppIcons.award,
          primary: LiveAction('See result', route: Routes.battleMatch(remembered)),
        ),
      );
    }

    for (final hook in _hooks) {
      hook.onWelcome(welcome);
    }
    _syncPill();
  }

  void _onTerminal(TerminalReason reason) {
    switch (reason) {
      case Revoked():
        // The session is over: the same path as a rejected refresh token.
        unawaited(
          _ref
              .read(tokenStoreProvider)
              .clear()
              .then<void>((_) {}, onError: (Object e) => debugPrint('Keeping tokens: $e')),
        );
        _ref.read(sessionExpiredProvider.notifier).fire();
      case Superseded():
        _hub.show(
          LiveAlert(
            id: LiveAlertIds.superseded,
            title: 'You\'re playing on another device',
            message: 'Live games and invites go there now.',
            icon: AppIcons.alert,
            tone: PastelTone.peach,
            primary: LiveAction('Play here', run: () async => connection.connect(takeover: true)),
          ),
        );
      case UpdateRequired():
        _ref.read(serverSignalsProvider.notifier).updateRequired();
      case LiveElsewhere(:final matchId):
        _hub.show(
          LiveAlert(
            id: LiveAlertIds.liveElsewhere,
            title: 'Your game is running on another device',
            message: 'Move it here?',
            icon: AppIcons.battle,
            tone: PastelTone.sky,
            style: AlertStyle.takeover,
            priority: LivePriority.liveGame,
            primary: LiveAction(
              'Move here',
              route: matchId == null ? null : Routes.battleMatch(matchId),
              run: () async => connection.connect(takeover: true),
            ),
            secondary: const LiveAction('Not now'),
          ),
        );
    }
  }

  // ------------------------------------------------------------------------------------------
  // The pill and the route

  void _onRoute() {
    if (_disposed) return;
    _later(() {
      final path = _path;
      if (path.startsWith('/battle/match/')) {
        for (final id in _matches.keys) {
          if (Routes.isBattleMatch(path, id)) {
            _hub
              ..dismiss(LiveAlertIds.found(id))
              ..dismiss(LiveAlertIds.rejoin(id));
          }
          if (path == Routes.battleMatch(id)) _hub.dismiss(LiveAlertIds.rematch(id));
        }
      }
      if (path == Routes.battleSearch) _hub.dismiss(LiveAlertIds.timeout);
      _syncPill();
    });
  }

  /// "Searching · 0:32" on every screen but the search screen itself.
  void _syncPill() {
    if (_disposed) return;
    final state = search.value;
    final show = state.isSearching && _path != Routes.battleSearch;
    if (!show) {
      if (_pillShown) _hub.setStatus(null);
      _pillShown = false;
      return;
    }
    final joinedAt = state.joinedAt;
    final now = _ref.read(liveClockProvider)();
    _hub.setStatus(
      LiveStatus(
        label: 'Searching',
        since: joinedAt == null
            ? null
            : now.subtract(Duration(milliseconds: (_serverNow - joinedAt).clamp(0, 1 << 31))),
        route: Routes.battleSearch,
        icon: AppIcons.search,
      ),
    );
    _pillShown = true;
  }

  // ------------------------------------------------------------------------------------------

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(_events.cancel());
    unawaited(_states.cancel());
    _router.routerDelegate.removeListener(_onRoute);
    _shell?.release();
    _shell = null;
    for (final match in _matches.values) {
      match.dispose();
    }
    _matches.clear();
    search.dispose();
  }
}
