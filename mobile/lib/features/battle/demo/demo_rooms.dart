part of 'demo_server.dart';

/// A failure of a demo REST call about rooms or invites, as the real API would answer.
class DemoRoomError implements Exception {
  const DemoRoomError(this.status, this.code, this.message, {this.details = const {}});

  final int status;
  final String code;
  final String message;
  final Map<String, Object?> details;

  @override
  String toString() => 'DemoRoomError($status $code)';
}

class DemoRoomMember {
  DemoRoomMember(this.player, {required this.joinedAt});

  final DemoPlayer player;
  final int joinedAt;
  bool ready = false;
  bool connected = true;
  bool away = false;

  String get uid => player.uid;
}

class _DemoInvite {
  _DemoInvite({
    required this.id,
    required this.from,
    required this.to,
    required this.room,
    required this.expiresAt,
  });

  final String id;
  final DemoPlayer from;
  final DemoPlayer to;
  final DemoRoom room;
  final int expiresAt;
  String status = 'pending';
  Timer? timer;
}

/// One demo room: a lobby on `r:<id>`, its settings and members, and the games it starts.
class DemoRoom {
  DemoRoom._(
    this._server, {
    required this.id,
    required this.kind,
    required this.code,
    required this.hostUid,
    required Map<String, Object?> settings,
  }) : settings = {...settings};

  final DemoRealtimeServer _server;
  final String id;

  /// `friend` or `group`.
  final String kind;
  final String code;
  String hostUid;
  String status = 'lobby';
  bool locked = false;
  final Map<String, Object?> settings;
  final List<DemoRoomMember> members = [];
  final Set<String> kicked = {};
  DemoMatch? match;
  Map<String, Object?>? rematch;
  final Set<String> _rematchAccepted = {};
  int seq = 0;
  final List<Map<String, Object?>> _log = [];
  final Set<Timer> _timers = {};
  Timer? _autoStart;

  /// Created over REST; the host joins over the socket next.
  bool _pendingHost = false;

  String get channel => 'r:$id';

  bool get isClosed => status == 'closed';

  int get capacity => kind == 'friend' ? 2 : 8;

  bool get isFull => members.length >= capacity;

  bool has(String uid) => members.any((m) => m.uid == uid);

  DemoRoomMember? member(String uid) => members.where((m) => m.uid == uid).firstOrNull;

  String get _me => _server.me.uid;

  /// The guests (everyone but the user).
  List<DemoPlayer> get guests => [
    for (final member in members)
      if (member.uid != _me) member.player,
  ];

  void _after(Duration delay, void Function() callback) {
    late final Timer timer;
    timer = _server._after(delay, () {
      _timers.remove(timer);
      if (!isClosed) callback();
    });
    _timers.add(timer);
  }

  void _cancelTimers() {
    for (final timer in _timers) {
      _server._cancel(timer);
    }
    _timers.clear();
    _server._cancel(_autoStart);
  }

  Map<String, Object?> state() => {
    'room_id': id,
    'kind': kind,
    'code': code,
    'host': hostUid,
    'status': status,
    'locked': locked,
    'settings': settings,
    'members': [
      for (final member in members)
        {
          ...member.player.card(),
          'ready': member.ready,
          'connected': member.connected,
          'away': member.away,
          'role': member.uid == hostUid ? 'host' : 'member',
        },
    ],
    'rematch': rematch == null ? null : {...rematch!, 'accepted': _rematchAccepted.toList()},
    'match_id': status == 'lobby' ? null : match?.id,
    'capacity': capacity,
  };

  /// A shared event: numbered and kept in the channel's log.
  void _shared(String type, Map<String, Object?> data) {
    final frame = DemoRealtimeServer._frame(type, data, ch: channel, seq: ++seq, ts: _server.now);
    _log.add(frame);
    if (has(_me)) _server._send(frame);
  }

  void _broadcast() => _shared('room.state', state());

  void _sendSnapshot() => _server._send(
    DemoRealtimeServer._frame('room.state', state(), ch: channel, seq: seq, ts: _server.now),
  );

  void _resume(int lastSeq) {
    if (lastSeq <= 0 || lastSeq > seq) {
      _sendSnapshot();
      return;
    }
    for (final frame in _log.where((f) => (f['seq']! as int) > lastSeq)) {
      _server._send(frame);
    }
  }

  void _add(DemoPlayer player) {
    if (has(player.uid) || isFull) return;
    members.add(DemoRoomMember(player, joinedAt: _server.now));
    _broadcast();
    if (player.uid != _me) _after(_server.guestReadyAfter, () => _guestReady(player.uid));
  }

  void _guestReady(String uid) {
    final member = this.member(uid);
    if (member == null || status != 'lobby') return;
    member.ready = true;
    _broadcast();
    _checkAutoStart();
  }

  /// A friend duel starts 3 s after both are ready; a room hosted by a demo player starts when
  /// everyone is ready.
  void _checkAutoStart() {
    _server._cancel(_autoStart);
    final everyoneReady = members.length >= 2 && members.every((m) => m.ready && m.connected);
    if (status != 'lobby' || !everyoneReady) return;
    if (kind != 'friend' && hostUid == _me) return;
    _autoStart = _server._after(_server.roomAutoStartAfter, () {
      if (status == 'lobby' && members.length >= 2 && members.every((m) => m.ready)) _start();
    });
  }

  void _start() {
    _server._cancel(_autoStart);
    rematch = null;
    _rematchAccepted.clear();
    final chapters = settings['chapters'];
    final chapter = chapters is List && chapters.isNotEmpty ? chapters.first as String? : null;
    final subject = settings['subject'] is String ? settings['subject']! as String : 'physics';
    final questions = settings['questions'] is int ? settings['questions']! as int : 7;
    final seconds = settings['seconds'] is int ? settings['seconds']! as int : 15;
    final started = DemoMatch._(
      _server,
      id: 'demo-m${++_server._matchCount}',
      mode: kind,
      subject: subject,
      chapter: chapter,
      opponents: guests,
      questions: _server._pick(subject, chapter, widened: chapter == null, count: questions),
      opponentNeverReady: false,
      requeue: null,
      room: this,
      leaderboard: settings['leaderboard'] != false,
      limitMs: seconds * 1000,
    );
    match = started;
    _server._matches[started.id] = started;
    _server._lastFoundId = started.id;
    _server._lastFoundAt = _server.now;
    status = 'playing';
    for (final member in members) {
      member.ready = false;
    }
    _shared('room.started', {'match_id': started.id, 'ch': started.channel});
    _broadcast();
    _server._after(_server.latency * 2 + const Duration(milliseconds: 40), started._sendSnapshot);
    started._startReadyWait();
  }

  /// The room's game ended: back to the lobby's after-game state, with a rematch possible.
  void _matchOver(DemoMatch ended) {
    if (!identical(ended, match) || isClosed) return;
    status = 'finished';
    _broadcast();
  }

  void _close(String reason) {
    if (isClosed) return;
    _cancelTimers();
    status = 'closed';
    final live = match;
    if (live != null && !live.isOver) live.endByHost();
    _shared('room.closed', {'room_id': id, 'reason': reason});
  }

  void _offerRematch(String by) {
    if (status != 'finished') return;
    if (rematch == null) {
      rematch = {'offered_by': by, 'until': _server.now + (kind == 'friend' ? 30000 : 180000)};
      final offer = rematch;
      _after(Duration(milliseconds: kind == 'friend' ? 30000 : 180000), () {
        if (!identical(rematch, offer) || status != 'finished') return;
        rematch = null;
        _rematchAccepted.clear();
        _broadcast();
      });
    }
    _rematchAccepted.add(by);
    _broadcast();
    if (members.every((m) => _rematchAccepted.contains(m.uid) || !m.connected)) {
      _after(const Duration(milliseconds: 600), _start);
    }
  }
}

/// Rooms and invites of the demo server: the `room.*` messages, and the REST calls the demo
/// rooms repository makes.
extension DemoRooms on DemoRealtimeServer {
  /// The room the user is in, if any.
  DemoRoom? get currentRoom => _rooms.values.where((r) => !r.isClosed && r.has(me.uid)).firstOrNull;

  DemoRoom? room(String roomId) => _rooms[roomId];

  DemoRoom _newRoom({
    required String kind,
    required DemoPlayer host,
    required Map<String, Object?> settings,
    String? code,
  }) {
    final n = ++_roomCount;
    final room = DemoRoom._(
      this,
      id: 'demo-r$n',
      kind: kind,
      code: code ?? _roomCode(n),
      hostUid: host.uid,
      settings: settings,
    );
    _rooms[room.id] = room;
    room.members.add(DemoRoomMember(host, joinedAt: this.now)..ready = host.uid != me.uid);
    return room;
  }

  static const _alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

  /// A Crockford code, different for every room.
  String _roomCode(int n) {
    final chars = List.generate(6, (i) => _alphabet[(n * 7 + i * 13 + _random.nextInt(32)) % 32]);
    return chars.join();
  }

  /// The demo's standing room: a group battle hosted by Riya that anyone can join with code
  /// `K7M2QX`.
  DemoRoom _openRoom() {
    final existing = _rooms.values.where((r) => r.code == demoRoomCode && !r.isClosed).firstOrNull;
    if (existing != null) return existing;
    final room = _newRoom(
      kind: 'group',
      host: DemoPlayer.riya,
      code: demoRoomCode,
      settings: const {
        'subject': 'physics',
        'chapters': <String>[],
        'questions': 5,
        'seconds': 15,
        'difficulty': 'mixed',
        'late_join': 'halfway',
        'leaderboard': true,
        'join': 'code',
      },
    );
    room.members.add(DemoRoomMember(DemoPlayer.kabir, joinedAt: this.now)..ready = true);
    return room;
  }

  // ------------------------------------------------------------------------------------------
  // REST

  /// `POST /v1/rooms`.
  Map<String, Object?> createRoomJson(String kind, Map<String, Object?> settings) {
    final busy = currentRoom;
    if (busy != null) {
      throw DemoRoomError(
        409,
        'BUSY',
        'You\'re already in a room.',
        details: {
          'active': {'kind': 'room', 'id': busy.id, 'title': 'Room ${busy.code}'},
        },
      );
    }
    final room = _newRoom(kind: kind, host: me, settings: _withDefaults(kind, settings));
    // Nobody is in it until the host joins over the socket.
    room.members.clear();
    room._pendingHost = true;
    return {
      'room_id': room.id,
      'code': room.code,
      'link': 'https://quizarena.app/j/${room.code}',
      'expires_at': DateTime.fromMillisecondsSinceEpoch(
        this.now + 15 * 60000,
        isUtc: true,
      ).toIso8601String(),
    };
  }

  Map<String, Object?> _withDefaults(String kind, Map<String, Object?> settings) => {
    'subject': 'physics',
    'chapters': <String>[],
    'questions': kind == 'friend' ? 7 : 10,
    'seconds': 15,
    if (kind == 'group') ...{
      'difficulty': 'mixed',
      'late_join': 'halfway',
      'leaderboard': true,
      'join': 'code',
    },
    ...settings,
  };

  /// `GET /v1/rooms/code/{code}`.
  Map<String, Object?> previewJson(String code) {
    final room = code == demoRoomCode
        ? _openRoom()
        : _rooms.values.where((r) => r.code == code && !r.isClosed).firstOrNull;
    if (room == null) throw const DemoRoomError(404, 'ROOM_NOT_FOUND', 'That code isn\'t active.');
    final host = room.member(room.hostUid)?.player ?? me;
    final reason = room.kicked.contains(me.uid)
        ? 'blocked'
        : room.locked
        ? 'locked'
        : room.isFull
        ? 'full'
        : room.status != 'lobby'
        ? 'started'
        : null;
    final chapters = room.settings['chapters'];
    return {
      'room_id': room.id,
      'kind': room.kind,
      'host': host.card()..['id'] = host.uid,
      'subject': _subjectName(room.settings['subject']),
      'chapters': [
        if (chapters is List)
          for (final slug in chapters) _chapterName(slug),
      ],
      'questions': room.settings['questions'],
      'seconds': room.settings['seconds'],
      'members': room.members.length,
      'capacity': room.capacity,
      'joinable': reason == null || room.has(me.uid),
      'reason': room.has(me.uid) ? null : reason,
    };
  }

  String _subjectName(Object? slug) =>
      slug is String && slug.isNotEmpty ? slug[0].toUpperCase() + slug.substring(1) : 'Physics';

  String _chapterName(Object? slug) =>
      _questions.where((q) => q.chapter.slug == slug).firstOrNull?.chapter.name ?? '$slug';

  /// `POST /v1/invites`: busy friends say so; Kabir never answers; everyone else accepts after
  /// [DemoRealtimeServer.inviteAnswerAfter] and joins.
  Map<String, Object?> inviteJson(String toUserId, String roomId) {
    final room = _rooms[roomId];
    if (room == null || room.isClosed) {
      throw const DemoRoomError(404, 'NOT_FOUND', 'That room is closed.');
    }
    final to = _guest(toUserId);
    if (to.uid == DemoPlayer.meera.uid || to.uid == DemoPlayer.ishaan.uid) {
      throw DemoRoomError(
        409,
        'BUSY',
        '${to.name} is busy.',
        details: {'reason': to.uid == DemoPlayer.meera.uid ? 'in_battle' : 'in_tournament'},
      );
    }
    final invite = _DemoInvite(
      id: 'demo-i${++_inviteCount}',
      from: me,
      to: to,
      room: room,
      expiresAt: this.now + 120000,
    );
    _invites[invite.id] = invite;
    if (to.uid == DemoPlayer.kabir.uid) {
      invite.timer = _after(const Duration(minutes: 2), () => _answerInvite(invite, 'expired'));
    } else {
      invite.timer = _after(inviteAnswerAfter, () {
        _answerInvite(invite, 'accepted');
        if (!room.isClosed && room.status == 'lobby') room._add(to);
      });
    }
    return {
      'invite_id': invite.id,
      'expires_at': DateTime.fromMillisecondsSinceEpoch(
        invite.expiresAt,
        isUtc: true,
      ).toIso8601String(),
    };
  }

  DemoPlayer _guest(String uid) =>
      [
        DemoPlayer.riya,
        DemoPlayer.rahul,
        DemoPlayer.kabir,
        DemoPlayer.meera,
        DemoPlayer.ishaan,
        DemoPlayer.neha,
      ].where((p) => p.uid == uid).firstOrNull ??
      DemoPlayer(uid: uid, name: 'Friend');

  void _answerInvite(_DemoInvite invite, String status) {
    if (invite.status != 'pending') return;
    invite.status = status;
    _cancel(invite.timer);
    _sendU('invite.updated', {'invite_id': invite.id, 'status': status});
  }

  /// `GET /v1/me/invites`.
  Map<String, Object?> invitesJson() {
    Map<String, Object?> json(_DemoInvite invite, {required bool incoming}) => {
      'invite_id': invite.id,
      if (incoming) 'from': invite.from.card()..['id'] = invite.from.uid,
      if (!incoming) 'to': invite.to.card()..['id'] = invite.to.uid,
      'room_id': invite.room.id,
      'kind': invite.room.kind,
      'subject': invite.room.settings['subject'],
      'expires_at': DateTime.fromMillisecondsSinceEpoch(
        invite.expiresAt,
        isUtc: true,
      ).toIso8601String(),
    };
    final pending = _invites.values.where((i) => i.status == 'pending' && i.expiresAt > this.now);
    return {
      'incoming': [
        for (final invite in pending)
          if (invite.to.uid == me.uid) json(invite, incoming: true),
      ],
      'outgoing': [
        for (final invite in pending)
          if (invite.from.uid == me.uid) json(invite, incoming: false),
      ],
    };
  }

  /// `POST /v1/invites/{id}/accept`.
  Map<String, Object?> acceptInviteJson(String inviteId) {
    final invite = _invites[inviteId];
    if (invite == null || invite.status != 'pending' || invite.expiresAt <= this.now) {
      throw const DemoRoomError(410, 'INVITE_EXPIRED', 'That invite expired.');
    }
    _answerInvite(invite, 'accepted');
    return {'room_id': invite.room.id, 'code': invite.room.code};
  }

  /// `POST /v1/invites/{id}/decline`.
  void declineInvite(String inviteId) {
    final invite = _invites[inviteId];
    if (invite != null) _answerInvite(invite, 'declined');
  }

  /// `DELETE /v1/invites/{id}`.
  void cancelInvite(String inviteId) {
    final invite = _invites[inviteId];
    if (invite != null) _answerInvite(invite, 'cancelled');
  }

  /// A friend ([from], Riya by default) invites the user to a new room of [kind] they host.
  String sendInvite({DemoPlayer from = DemoPlayer.riya, String kind = 'friend'}) {
    final room = _newRoom(kind: kind, host: from, settings: _withDefaults(kind, const {}));
    final invite = _DemoInvite(
      id: 'demo-i${++_inviteCount}',
      from: from,
      to: me,
      room: room,
      expiresAt: this.now + 120000,
    );
    _invites[invite.id] = invite;
    invite.timer = _after(const Duration(minutes: 2), () => _answerInvite(invite, 'expired'));
    _sendU('invite.received', {
      'invite_id': invite.id,
      'from': from.card(),
      'kind': kind,
      'room_id': room.id,
      'subject': room.settings['subject'],
      'expires_at': invite.expiresAt,
    });
    return invite.id;
  }

  // ------------------------------------------------------------------------------------------
  // The socket

  void _roomMessage(String type, String? ref, Map<String, Object?> data) {
    if (type == 'room.join') {
      _roomJoin(ref, data);
      return;
    }
    final room = _rooms[data['room_id']];
    if (room == null || room.isClosed || !room.has(me.uid)) {
      _error(ref, 'NOT_FOUND', 'That room isn\'t open.');
      return;
    }
    final host = room.hostUid == me.uid;
    bool hostOnly() {
      if (host) return true;
      _error(ref, 'NOT_ALLOWED', 'Only the host can do that.');
      return false;
    }

    switch (type) {
      case 'room.leave':
        _ack(ref);
        _roomLeave(room);
      case 'room.ready':
        _ack(ref);
        room.member(me.uid)!.ready = data['ready'] != false;
        room._broadcast();
        room._checkAutoStart();
      case 'room.settings':
        if (!hostOnly()) return;
        final settings = data['settings'];
        if (room.status != 'lobby' || settings is! Map<String, Object?>) {
          _error(ref, 'NOT_ALLOWED', 'Settings change in the lobby only.');
          return;
        }
        _ack(ref);
        room.settings.addAll(settings);
        for (final member in room.members) {
          if (member.uid == me.uid) member.ready = false;
        }
        room._broadcast();
      case 'room.start':
        if (!hostOnly()) return;
        if (room.status != 'lobby' || room.members.where((m) => m.connected).length < 2) {
          _error(ref, 'NOT_ALLOWED', 'You need at least 2 players.');
          return;
        }
        _ack(ref);
        room._start();
      case 'room.kick':
        if (!hostOnly()) return;
        final uid = data['uid'];
        if (uid is! String || uid == me.uid || !room.has(uid)) {
          _error(ref, 'BAD_REQUEST', 'Not a member.');
          return;
        }
        _ack(ref);
        room.members.removeWhere((m) => m.uid == uid);
        room.kicked.add(uid);
        room._broadcast();
      case 'room.lock':
        if (!hostOnly()) return;
        _ack(ref);
        room.locked = data['locked'] != false;
        room._broadcast();
      case 'room.transfer':
        if (!hostOnly()) return;
        final uid = data['uid'];
        if (uid is! String || !room.has(uid)) {
          _error(ref, 'BAD_REQUEST', 'Not a member.');
          return;
        }
        _ack(ref);
        room.hostUid = uid;
        room._broadcast();
        room._checkAutoStart();
      case 'room.end':
        if (!hostOnly()) return;
        _ack(ref);
        room._close('host_ended');
      case 'room.rematch':
        if (room.status != 'finished') {
          _error(ref, 'NOT_ALLOWED', 'There\'s no game to replay.');
          return;
        }
        _ack(ref);
        if (data['accept'] == false) {
          room.rematch = null;
          room._rematchAccepted.clear();
          room._broadcast();
          return;
        }
        room._offerRematch(me.uid);
        for (final (i, guest) in room.guests.indexed) {
          room._after(Duration(milliseconds: 1200 + 400 * i), () => room._offerRematch(guest.uid));
        }
      default:
        _error(ref, 'BAD_REQUEST', 'Unknown message type');
    }
  }

  void _roomJoin(String? ref, Map<String, Object?> data) {
    final code = data['code'] is String ? (data['code']! as String).toUpperCase() : null;
    final DemoRoom? room;
    if (code == demoRoomCode) {
      room = _openRoom();
    } else if (code != null) {
      room = _rooms.values.where((r) => r.code == code && !r.isClosed).firstOrNull;
    } else {
      room = _rooms[data['room_id']];
    }
    if (room == null || room.isClosed) {
      _error(ref, 'NOT_FOUND', 'That code isn\'t active.');
      return;
    }
    final mine = room.member(me.uid);
    if (mine != null) {
      mine
        ..connected = true
        ..away = !_foreground;
      room._broadcast();
      return;
    }
    final other = currentRoom;
    if (other != null) {
      _error(
        ref,
        'BUSY',
        'You\'re already in a room.',
        details: {
          'active': {'kind': 'room', 'id': other.id, 'title': 'Room ${other.code}'},
        },
      );
      return;
    }
    final live = _matches.values.where((m) => !m.isOver).firstOrNull;
    if (live != null) {
      _error(
        ref,
        'BUSY',
        'You\'re in a match.',
        details: {
          'active': {'kind': 'match', 'id': live.id, 'title': 'A battle'},
        },
      );
      return;
    }
    if (room.kicked.contains(me.uid) || room.locked || room.isFull) {
      _error(ref, 'NOT_ALLOWED', 'You can\'t join this room.');
      return;
    }
    if (room.status != 'lobby') {
      _error(ref, 'NOT_ALLOWED', 'The game has already started.');
      return;
    }
    final firstJoin = room._pendingHost;
    room._pendingHost = false;
    room._add(me);
    if (firstJoin && guestsJoin) _inviteGuests(room);
    room._checkAutoStart();
  }

  /// Demo players join a room the user just made, as if they had the link.
  void _inviteGuests(DemoRoom room) {
    final guests = room.kind == 'friend'
        ? [DemoPlayer.riya]
        : [DemoPlayer.riya, DemoPlayer.neha, DemoPlayer.kabir];
    for (final (i, guest) in guests.indexed) {
      room._after(guestJoinAfter + Duration(seconds: 2 * i), () {
        if (room.status == 'lobby' && !room.kicked.contains(guest.uid)) room._add(guest);
      });
    }
  }

  void _roomLeave(DemoRoom room) {
    room.members.removeWhere((m) => m.uid == me.uid);
    // Nobody real is left: the demo room goes.
    room._cancelTimers();
    room.status = 'closed';
    final live = room.match;
    if (live != null && !live.isOver) live._forfeit(null);
  }

  /// The app went to the background or came back: the user is away in their room.
  void _roomPresence({required bool connected, required bool foreground}) {
    final room = currentRoom;
    final mine = room?.member(me.uid);
    if (room == null || mine == null) return;
    mine
      ..connected = connected
      ..away = !foreground;
    room._broadcast();
  }
}

/// The code of the demo's standing group room, hosted by Riya.
const demoRoomCode = 'K7M2QX';
