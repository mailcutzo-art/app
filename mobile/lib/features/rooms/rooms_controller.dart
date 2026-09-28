import 'dart:async';

import 'package:design_system/design_system.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:realtime_client/realtime_client.dart';

import '../../app/live/live_hub.dart';
import '../../app/router.dart';
import '../../core/config/app_config.dart' show liveGameProvider;
import '../../core/network/app_failure.dart';
import '../../core/realtime/live_controller.dart';
import '../../core/realtime/live_providers.dart';
import 'data/room_models.dart';
import 'data/rooms_repository.dart';
import 'room_text.dart';

/// The room the user is in, as the lobby shows it.
@immutable
class RoomView {
  const RoomView({required this.state, required this.me, this.link});

  /// The reduced server state.
  final RoomState state;

  /// The signed-in user's uid.
  final String me;

  /// The link to share (`https://<domain>/j/<code>`), when this device created the room.
  final String? link;

  String get roomId => state.roomId;

  RoomKind get kind => RoomKind.parse(state.kind) ?? RoomKind.friend;

  bool get isHost => state.isHost(me);

  RoomMember? get mine => state.member(me);

  bool get isReady => mine?.ready ?? false;

  /// Everyone but me, in join order.
  List<RoomMember> get others => [
    for (final member in state.members)
      if (member.uid != me) member,
  ];

  /// "Riya", or "the host" before the lobby is known.
  String get hostName => nameOf(state.hostMember?.card) ?? 'the host';

  /// Where the user belongs now: the game while one is on, otherwise the lobby.
  String get route {
    final matchId = state.matchId;
    if (state.status == RoomStatus.playing && matchId != null) return Routes.battleMatch(matchId);
    return Routes.room(roomId);
  }

  /// What the room's invitation says when shared.
  String shareText() {
    final code = state.code ?? '';
    final what = kind == RoomKind.friend ? 'a Quiz Arena battle' : 'my Quiz Arena group battle';
    final link = this.link;
    return link == null ? 'Join $what with code $code.' : 'Join $what with code $code: $link';
  }

  RoomView copyWith({RoomState? state, String? link}) =>
      RoomView(state: state ?? this.state, me: me, link: link ?? this.link);
}

/// "Riya" for a player card: the name, else the handle.
String? nameOf(PlayerCard? card) => card?.displayName ?? card?.handle;

/// Where an invite I sent stands.
enum InviteState {
  sending,
  pending,
  accepted,
  declined,
  expired,
  cancelled,

  /// `BUSY`: the friend is in a game, a room or a tournament.
  busy,

  /// `NOT_ALLOWED`: their privacy settings or a block.
  notAllowed,
}

/// An invite I sent from the current room.
@immutable
class OutgoingInvite {
  const OutgoingInvite({required this.userId, required this.state, this.inviteId, this.expiresAt});

  final String userId;
  final InviteState state;
  final String? inviteId;

  /// When it lapses on this device's clock.
  final DateTime? expiresAt;

  /// Whether it can still be answered at [now].
  bool isOpenAt(DateTime now) =>
      state == InviteState.sending ||
      (state == InviteState.pending && (expiresAt == null || now.isBefore(expiresAt!)));
}

/// An invite someone sent me.
@immutable
class _Incoming {
  const _Incoming({
    required this.id,
    required this.from,
    required this.kind,
    required this.subject,
    required this.expiresAt,
  });

  final String id;
  final String from;
  final RoomKind? kind;
  final String? subject;
  final DateTime expiresAt;
}

/// Rooms and invites on the always-on connection, one per signed-in user
/// (docs/protocol.md section 8, docs/user-flows.md sections 5 and 6).
///
/// - Creates rooms (`POST /v1/rooms`, then `room.join`) and joins them by code, by id or through
///   an invite; follows the one room the user is in by reducing its `r:` events; and sends the
///   lobby actions (ready, settings, start, kick, lock, transfer, end, leave, rematch).
/// - Starts the room's game on `room.started` and opens it (or, when the user is elsewhere,
///   offers it on the live layer).
/// - Sends invites and tracks their answers; shows invites received as banners with Accept and
///   Decline on any screen, holding them back while a game is being played. Pending invites
///   are read over REST after every (re)connect, and every 20 s while the connection is down.
/// - Keeps an "In a room" pill on every screen but the lobby and the game, and notices for a new
///   host, a kick, a closed lobby or a declined invite.
class RoomsController implements LiveEventHook {
  RoomsController(this._ref, this.live) : me = live.me {
    _router = _ref.read(routerProvider);
    _router.routerDelegate.addListener(_onRoute);
    _poll = Timer.periodic(invitePollEvery, (_) => unawaited(_pollWhileDown()));
  }

  final Ref _ref;
  final LiveController live;
  final String me;

  /// How often pending invites are read while the connection is down.
  static const invitePollEvery = Duration(seconds: 20);

  /// How long an invite lasts when the server doesn't say.
  static const inviteLifetime = Duration(minutes: 2);

  /// The room the user is in, if any.
  final ValueNotifier<RoomView?> room = ValueNotifier(null);

  /// Invites sent from the current room, by friend id.
  final ValueNotifier<Map<String, OutgoingInvite>> outgoing = ValueNotifier(const {});

  late final GoRouter _router;
  late final Timer _poll;
  final Map<String, String> _links = {};
  final Map<String, _Incoming> _incoming = {};

  /// Invites shown (or answered) once: a later read of the pending list doesn't bring them back.
  final Set<String> _seen = {};

  /// Invites received during a game, shown when it ends.
  final List<String> _deferred = [];
  ({String? roomId, String? code})? _joining;
  Completer<RoomStateEvent>? _joinReply;
  bool _pillShown = false;
  bool _disposed = false;

  RealtimeConnection get connection => live.connection;

  RoomsRepository get _repo => _ref.read(roomsRepositoryProvider);

  LiveHub get _hub => _ref.read(liveHubProvider.notifier);

  DateTime get _clock => _ref.read(liveClockProvider)();

  String get _path => currentPath(_router);

  bool get isDisposed => _disposed;

  // ------------------------------------------------------------------------------------------
  // Creating and joining

  /// Creates a room and joins it. [idempotencyKey] makes a retried create return the same room.
  /// Throws an [AppFailure] from REST or a [RealtimeError] from `room.join`.
  Future<RoomView> create(
    RoomKind kind,
    RoomSettings settings, {
    required String idempotencyKey,
  }) async {
    final created = await _repo.create(
      kind: kind,
      settings: settings,
      idempotencyKey: idempotencyKey,
    );
    final link = created.link;
    if (link != null) _links[created.roomId] = link;
    return joinRoom(created.roomId);
  }

  /// Joins the room [roomId] (after accepting an invite, from `welcome.active`, …).
  Future<RoomView> joinRoom(String roomId) => _join({'room_id': roomId}, roomId: roomId);

  /// Joins a room by its code. Throws the server's [RealtimeError] (`NOT_FOUND`, `NOT_ALLOWED`,
  /// `BUSY`, which also shows "Go there").
  Future<RoomView> joinCode(String code) => _join({'code': code}, code: code);

  Future<RoomView> _join(Map<String, Object?> data, {String? roomId, String? code}) async {
    final current = room.value;
    if (current != null &&
        current.state.isKnown &&
        (current.roomId == roomId || (code != null && current.state.code == code))) {
      return current;
    }
    _joining = (roomId: roomId, code: code);
    _joinReply = Completer<RoomStateEvent>();
    try {
      final ack = await connection.request('room.join', data);
      final reply = ack.reply is RoomStateEvent
          ? ack.reply as RoomStateEvent
          // An `ack` first: the room's state follows on its channel.
          : await _joinReply!.future.timeout(const Duration(seconds: 10));
      final known = room.value;
      if (known != null && known.roomId == reply.roomId && known.state.isKnown) return known;
      final view = RoomView(
        state: reduceRoom(RoomState.initial(reply.roomId), reply),
        me: me,
        link: _links[reply.roomId],
      );
      _setRoom(view);
      return view;
    } on TimeoutException {
      throw const RealtimeError(code: RealtimeErrorCode.timeout, retryable: true);
    } on RealtimeError catch (error) {
      if (error.code == RealtimeErrorCode.busy) live.showBusy(error.active);
      rethrow;
    } finally {
      _joining = null;
      _joinReply = null;
    }
  }

  bool _isJoinReply(RoomStateEvent event) {
    final joining = _joining;
    if (joining == null) return false;
    return event.roomId == joining.roomId ||
        (joining.code != null && event.code?.toUpperCase() == joining.code!.toUpperCase());
  }

  // ------------------------------------------------------------------------------------------
  // Lobby actions

  Future<void> setReady({required bool ready}) => _send('room.ready', {'ready': ready});

  /// Host, lobby only.
  Future<void> updateSettings(RoomSettings settings) =>
      _send('room.settings', {'settings': settings.toJson()});

  /// Host; needs at least two connected players.
  Future<void> start() => _send('room.start', const {});

  /// Host: the player can't rejoin this room.
  Future<void> kick(String uid) => _send('room.kick', {'uid': uid});

  Future<void> lock({required bool locked}) => _send('room.lock', {'locked': locked});

  Future<void> transfer(String uid) => _send('room.transfer', {'uid': uid});

  /// Host: closes the room for everyone (and ends a game in progress on the current scores).
  Future<void> end() => _send('room.end', const {});

  /// Offers, accepts ([accept] true) or turns down a rematch after a game.
  Future<void> rematch({bool accept = true}) => _send('room.rematch', {'accept': accept});

  Future<void> _send(String type, Map<String, Object?> data) async {
    final view = room.value;
    if (view == null) throw const RealtimeError(code: RealtimeErrorCode.notFound);
    await connection.request(type, {'room_id': view.roomId, ...data});
  }

  /// Leaves the room. The user is out on this device at once, even if the server can't be told
  /// (it lets an empty lobby go by itself).
  Future<void> leave() async {
    final view = room.value;
    if (view == null) return;
    _clearRoom(view.roomId);
    try {
      await connection.request('room.leave', {'room_id': view.roomId});
    } on RealtimeError catch (error) {
      debugPrint('room.leave failed: $error');
    }
  }

  // ------------------------------------------------------------------------------------------
  // Invites I send

  /// Invites the friend [userId] to the current room. `BUSY` and `NOT_ALLOWED` answers become
  /// the invite's state; other failures are rethrown.
  Future<void> invite(String userId) async {
    final view = room.value;
    if (view == null) return;
    final open = outgoing.value[userId];
    if (open != null && open.isOpenAt(_clock)) return;
    _setOutgoing(OutgoingInvite(userId: userId, state: InviteState.sending));
    try {
      final sent = await _repo.invite(toUserId: userId, roomId: view.roomId);
      _setOutgoing(
        OutgoingInvite(
          userId: userId,
          state: InviteState.pending,
          inviteId: sent.inviteId,
          expiresAt: _localExpiry(sent.expiresAt),
        ),
      );
    } on AppFailure catch (failure) {
      final state = switch (failure) {
        ConflictFailure(code: 'BUSY') => InviteState.busy,
        ForbiddenFailure() || ConflictFailure(code: 'NOT_ALLOWED') => InviteState.notAllowed,
        _ => null,
      };
      if (state == null) {
        _removeOutgoing(userId);
        rethrow;
      }
      _setOutgoing(OutgoingInvite(userId: userId, state: state));
    }
  }

  /// Takes back a pending invite.
  Future<void> cancelInvite(String userId) async {
    final invite = outgoing.value[userId];
    final id = invite?.inviteId;
    if (invite == null || id == null) return;
    _setOutgoing(OutgoingInvite(userId: userId, state: InviteState.cancelled, inviteId: id));
    try {
      await _repo.cancel(id);
    } on AppFailure {
      _setOutgoing(invite);
      rethrow;
    }
  }

  DateTime _localExpiry(DateTime? serverTime) {
    if (serverTime == null) return _clock.add(inviteLifetime);
    // REST times are wall-clock UTC; map them onto the live clock through the synced offset.
    final left = serverTime.millisecondsSinceEpoch - connection.serverClock.nowServerMs();
    return _clock.add(Duration(milliseconds: left.clamp(0, inviteLifetime.inMilliseconds * 2)));
  }

  void _setOutgoing(OutgoingInvite invite) =>
      outgoing.value = Map.unmodifiable({...outgoing.value, invite.userId: invite});

  void _removeOutgoing(String userId) =>
      outgoing.value = Map.unmodifiable({...outgoing.value}..remove(userId));

  // ------------------------------------------------------------------------------------------
  // Invites I receive

  /// Accepts an invite and joins its room, then opens the lobby (or the game, when late).
  /// An invite that already lapsed says so instead of failing.
  Future<void> acceptInvite(String inviteId) async {
    _seen.add(inviteId);
    _deferred.remove(inviteId);
    final AcceptedInvite accepted;
    try {
      accepted = await _repo.accept(inviteId);
    } on NotFoundFailure {
      _incoming.remove(inviteId);
      _notice('Invite expired', 'Ask your friend to send a new one.', icon: AppIcons.hourglass);
      return;
    }
    _incoming.remove(inviteId);
    final view = await joinRoom(accepted.roomId);
    _router.go(view.route);
  }

  Future<void> declineInvite(String inviteId) async {
    _seen.add(inviteId);
    _deferred.remove(inviteId);
    _incoming.remove(inviteId);
    _hub.dismiss(LiveAlertIds.invite(inviteId));
    try {
      await _repo.decline(inviteId);
    } on AppFailure catch (failure) {
      // It lapses by itself in two minutes anyway.
      debugPrint('Declining $inviteId failed: $failure');
    }
  }

  /// Reads pending invites: incoming ones not shown yet get their banner, and outgoing ones of
  /// the current room are listed. Failures keep what is known.
  Future<void> refreshInvites() async {
    final InviteList list;
    try {
      list = await _repo.invites();
    } on AppFailure catch (failure) {
      debugPrint('Reading invites failed: $failure');
      return;
    }
    if (_disposed) return;
    for (final invite in list.incoming) {
      if (_seen.contains(invite.inviteId)) continue;
      _receive(
        _Incoming(
          id: invite.inviteId,
          from: invite.user.displayName,
          kind: invite.kind,
          subject: invite.subject,
          expiresAt: _localExpiry(invite.expiresAt),
        ),
      );
    }
    final roomId = room.value?.roomId;
    for (final invite in list.outgoing) {
      if (invite.roomId != roomId || outgoing.value.containsKey(invite.user.id)) continue;
      _setOutgoing(
        OutgoingInvite(
          userId: invite.user.id,
          state: InviteState.pending,
          inviteId: invite.inviteId,
          expiresAt: _localExpiry(invite.expiresAt),
        ),
      );
    }
  }

  void _receive(_Incoming invite) {
    _incoming[invite.id] = invite;
    _seen.add(invite.id);
    if (_ref.read(liveGameProvider) || live.playing) {
      if (!_deferred.contains(invite.id)) _deferred.add(invite.id);
      return;
    }
    _showInvite(invite);
  }

  void _showInvite(_Incoming invite) {
    if (!_clock.isBefore(invite.expiresAt)) {
      _incoming.remove(invite.id);
      return;
    }
    final what = [
      invite.kind?.label ?? 'A battle',
      if (invite.subject != null) RoomText.subject(invite.subject),
    ];
    _hub.show(
      LiveAlert(
        id: LiveAlertIds.invite(invite.id),
        title: '${invite.from} invited you',
        message: what.join(' · '),
        icon: AppIcons.userAdd,
        tone: PastelTone.lavender,
        priority: LivePriority.invite,
        expiresAt: invite.expiresAt,
        primary: LiveAction('Accept', run: () => acceptInvite(invite.id)),
        secondary: LiveAction('Decline', run: () => declineInvite(invite.id)),
      ),
    );
  }

  /// A game ended: invites that came in meanwhile show now, newest last.
  void flushDeferredInvites() {
    if (_disposed || live.playing) return;
    final waiting = List.of(_deferred);
    _deferred.clear();
    for (final id in waiting) {
      final invite = _incoming[id];
      if (invite != null) _showInvite(invite);
    }
  }

  Future<void> _pollWhileDown() async {
    if (_disposed || !_ref.read(appForegroundProvider)) return;
    if (connection.state is Open) return;
    await refreshInvites();
  }

  // ------------------------------------------------------------------------------------------
  // Events

  /// A `room.*` or `invite.*` event from the connection.
  @override
  void onEvent(ServerEvent event) {
    if (_disposed) return;
    switch (event) {
      case RoomStateEvent() || RoomStartedEvent() || RoomKickedEvent() || RoomClosedEvent():
        _onRoomEvent(event);
      case InviteReceivedEvent():
        _receive(
          _Incoming(
            id: event.inviteId,
            from: nameOf(event.from) ?? 'A friend',
            kind: RoomKind.parse(event.kind),
            subject: event.subject,
            expiresAt: _serverToLocal(event.expiresAt) ?? _clock.add(inviteLifetime),
          ),
        );
      case InviteUpdatedEvent():
        _onInviteUpdated(event);
      default:
        break;
    }
  }

  DateTime? _serverToLocal(int? serverMs) {
    if (serverMs == null) return null;
    return _clock.add(Duration(milliseconds: serverMs - connection.serverClock.nowServerMs()));
  }

  void _onRoomEvent(ServerEvent event) {
    final current = room.value;
    if (event is RoomStateEvent &&
        (current == null || current.roomId != event.roomId) &&
        _isJoinReply(event)) {
      final reply = _joinReply;
      if (reply != null && !reply.isCompleted) reply.complete(event);
      _setRoom(
        RoomView(
          state: reduceRoom(RoomState.initial(event.roomId), event),
          me: me,
          link: _links[event.roomId],
        ),
      );
      return;
    }
    if (current == null) return;
    final before = current.state;
    final next = reduceRoom(before, event);
    if (identical(next, before)) return;
    _setRoom(current.copyWith(state: next));

    if (before.isKnown && before.host != next.host && next.host != null) _hostChanged(next);
    if (event is RoomStartedEvent) _started(next, event.matchId);
    if (next.status.isGone) _gone(next);
  }

  void _hostChanged(RoomState state) {
    final host = state.hostMember;
    _notice(
      state.isHost(me)
          ? 'You\'re now the host'
          : '${nameOf(host?.card) ?? 'Someone'} is now the host',
      state.isHost(me) ? 'You can start the game and change the settings.' : null,
      icon: AppIcons.crown,
    );
  }

  void _started(RoomState state, String matchId) {
    live.startRoomMatch(matchId, roomId: state.roomId, kind: state.kind ?? 'friend');
    final path = _path;
    final direct =
        Routes.isRoom(path, state.roomId) ||
        Routes.isBattleMatch(path) ||
        path == Routes.battleJoin ||
        path.startsWith('${Routes.battle}/room/');
    final route = Routes.battleMatch(matchId);
    if (direct) {
      _router.go(route);
      return;
    }
    _hub.show(
      LiveAlert(
        id: LiveAlertIds.roomStarting(matchId),
        title: 'Your game is starting',
        message: state.kind == 'group' ? 'Group battle' : 'Friend battle',
        icon: AppIcons.battle,
        tone: PastelTone.sky,
        style: AlertStyle.takeover,
        priority: LivePriority.liveGame,
        primary: LiveAction('Play now', route: route),
      ),
    );
  }

  void _gone(RoomState state) {
    final onLobby = Routes.isRoom(_path, state.roomId);
    _clearRoom(state.roomId);
    if (state.status == RoomStatus.kicked) {
      _notice(RoomText.kicked, null, icon: AppIcons.alert);
    } else {
      _notice(RoomText.closed(state.closedReason), null, icon: AppIcons.info);
    }
    if (onLobby) _router.go(Routes.battle);
  }

  void _onInviteUpdated(InviteUpdatedEvent event) {
    // Mine, answered: the lobby's invite list shows it; elsewhere a decline gets a notice.
    for (final invite in outgoing.value.values) {
      if (invite.inviteId != event.inviteId) continue;
      final state = switch (event.status) {
        InviteStatus.accepted => InviteState.accepted,
        InviteStatus.declined => InviteState.declined,
        InviteStatus.expired => InviteState.expired,
        InviteStatus.cancelled => InviteState.cancelled,
        InviteStatus.unknown => invite.state,
      };
      _setOutgoing(
        OutgoingInvite(
          userId: invite.userId,
          state: state,
          inviteId: invite.inviteId,
          expiresAt: invite.expiresAt,
        ),
      );
      final view = room.value;
      if (state == InviteState.declined && view != null && !Routes.isRoom(_path, view.roomId)) {
        _notice(
          'Your friend declined',
          'Invite someone else from the lobby.',
          icon: AppIcons.userAdd,
        );
      }
      return;
    }
    // Sent to me: it's no longer answerable.
    if (event.status != InviteStatus.accepted) {
      _incoming.remove(event.inviteId);
      _deferred.remove(event.inviteId);
      _hub.dismiss(LiveAlertIds.invite(event.inviteId));
    }
  }

  /// After every `welcome`: rejoin a room the server says the user is in (after a restart), let
  /// go of one that ended while away, and pick up invites that came in meanwhile.
  @override
  void onWelcome(WelcomeEvent welcome) {
    if (_disposed) return;
    final entry = welcome.active.where((a) => a.kind == ActiveKind.room).firstOrNull;
    final channel = entry?.channel;
    final roomId =
        entry?.id ?? (channel != null && channel.startsWith('r:') ? channel.substring(2) : null);
    final current = room.value;
    if (roomId != null && current == null) {
      _setRoom(RoomView(state: RoomState.initial(roomId), me: me));
      try {
        connection.syncChannel('r:$roomId');
      } on Object catch (error) {
        debugPrint('Could not sync room $roomId: $error');
      }
    } else if (current != null && current.state.isKnown && roomId != current.roomId) {
      _gone(current.state.status.isGone ? current.state : _closedWhileAway(current.state));
    }
    unawaited(refreshInvites());
  }

  RoomState _closedWhileAway(RoomState state) => RoomState(
    roomId: state.roomId,
    kind: state.kind,
    status: RoomStatus.closed,
    closedReason: 'away',
  );

  // ------------------------------------------------------------------------------------------
  // State, notices and the pill

  void _setRoom(RoomView? view) {
    if (_disposed) return;
    final previous = room.value;
    if (previous != null && view?.roomId != previous.roomId) outgoing.value = const {};
    room.value = view;
    _later(_syncPill);
  }

  void _clearRoom(String roomId) {
    if (room.value?.roomId != roomId) return;
    _setRoom(null);
    connection.forgetChannel('r:$roomId');
  }

  void _notice(String title, String? message, {required HugeIconData icon}) =>
      _hub.show(LiveAlert(id: LiveAlertIds.room, title: title, message: message, icon: icon));

  void _onRoute() {
    if (_disposed) return;
    _later(_syncPill);
  }

  void _later(void Function() change) {
    if (SchedulerBinding.instance.schedulerPhase != SchedulerPhase.persistentCallbacks) {
      change();
      return;
    }
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!_disposed) change();
    });
  }

  /// "Room K7M2QX" on every screen but the lobby and the games.
  void _syncPill() {
    if (_disposed) return;
    final view = room.value;
    final path = _path;
    final show =
        view != null &&
        view.state.isKnown &&
        !Routes.isRoom(path, view.roomId) &&
        !Routes.isBattleMatch(path) &&
        !path.startsWith('${Routes.battle}/room/');
    if (!show) {
      if (_pillShown) _hub.setStatus(null);
      _pillShown = false;
      return;
    }
    // Searching can't happen while in a room, so the pill is free.
    _hub.setStatus(
      LiveStatus(
        label: view.state.code == null ? 'In a room' : 'Room ${view.state.code}',
        route: view.route,
        icon: AppIcons.userAdd,
      ),
    );
    _pillShown = true;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _poll.cancel();
    _router.routerDelegate.removeListener(_onRoute);
    if (_pillShown) _hub.setStatus(null);
    final reply = _joinReply;
    if (reply != null && !reply.isCompleted) {
      reply.completeError(const RealtimeError(code: RealtimeErrorCode.closed));
    }
    room.dispose();
    outgoing.dispose();
  }
}

/// The rooms side of the live connection while a user is signed in and onboarded.
final roomsControllerProvider = Provider<RoomsController?>((ref) {
  final live = ref.watch(liveControllerProvider);
  if (live == null) return null;
  final controller = RoomsController(ref, live);
  live.addHook(controller);
  ref
    // Invites wait while a game is on and show once it's over.
    ..listen(liveGameProvider, (_, playing) {
      if (!playing) scheduleMicrotask(controller.flushDeferredInvites);
    })
    ..onDispose(() {
      live.removeHook(controller);
      controller.dispose();
    });
  return controller;
});

/// The room the user is in, for the lobby and the game.
final roomViewProvider = NotifierProvider<RoomViewNotifier, RoomView?>(RoomViewNotifier.new);

class RoomViewNotifier extends Notifier<RoomView?> {
  @override
  RoomView? build() {
    final rooms = ref.watch(roomsControllerProvider);
    if (rooms == null) return null;
    final room = rooms.room;
    void sync() => state = room.value;
    room.addListener(sync);
    ref.onDispose(() => room.removeListener(sync));
    return room.value;
  }
}

/// Invites sent from the current room, by friend id.
final outgoingInvitesProvider = NotifierProvider<OutgoingInvites, Map<String, OutgoingInvite>>(
  OutgoingInvites.new,
);

class OutgoingInvites extends Notifier<Map<String, OutgoingInvite>> {
  @override
  Map<String, OutgoingInvite> build() {
    final rooms = ref.watch(roomsControllerProvider);
    if (rooms == null) return const {};
    final outgoing = rooms.outgoing;
    void sync() => state = outgoing.value;
    outgoing.addListener(sync);
    ref.onDispose(() => outgoing.removeListener(sync));
    return outgoing.value;
  }
}

/// Runs [action] on the rooms controller, if there is one (signed in, connected layer up).
RoomsController? roomsOf(WidgetRef ref) => ref.read(roomsControllerProvider);
