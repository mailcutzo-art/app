import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:realtime_client/realtime_client.dart';

import '../../learn/data/fake_learn_repository.dart';
import '../data/battle_models.dart';
import 'demo_world.dart';

part 'demo_match.dart';
part 'demo_rooms.dart';

/// How the demo opponent answers one question: right or wrong, after [ms]. A `null` plan entry
/// means no answer.
@immutable
class DemoAnswerPlan {
  const DemoAnswerPlan({required this.correct, required this.ms});

  final bool correct;
  final int ms;
}

/// A scripted realtime server that runs inside the app (debug builds with "Demo data" on), so the
/// whole Quick Battle journey can be played without a backend. It speaks protocol v1 through the
/// same connector interface as the real socket:
///
/// - `mm.join` queues the user; Riya is found after about 6 s. The first search ever offers the
///   Practice Bot at 20 s instead, and a search still running at 15 s widens.
/// - Matches play 7 questions from the Learn sample questions, with a bot-like opponent (about
///   60% right, answers in a few seconds), reveals, `match.end` and `match.settled`.
/// - Cancel, the timeout options, the Practice Bot, forfeits, emotes, rematches, resume and
///   `sync` work as specified.
///
/// Tests turn the knobs (timings, the opponent's answers, a withheld settlement, a dropping
/// opponent, `BUSY`, `LIVE_ELSEWHERE`).
class DemoRealtimeServer implements WebSocketConnector {
  DemoRealtimeServer({
    required this.me,
    int Function()? nowMs,
    int seed = 7,
    List<FakeQuestion>? questions,
  }) : _nowMs = nowMs ?? (() => clock.now().millisecondsSinceEpoch),
       _random = Random(seed),
       _questions = questions ?? [for (final subject in sampleSubjects) ...subject.questions];

  final DemoPlayer me;
  final DemoWorld world = DemoWorld();
  final int Function() _nowMs;
  final Random _random;
  final List<FakeQuestion> _questions;

  // ------------------------------------------------------------------------------------------
  // Knobs

  /// One-way delay of every frame.
  Duration latency = const Duration(milliseconds: 20);
  Duration findAfter = const Duration(seconds: 6);
  Duration widenAt = const Duration(seconds: 15);
  Duration firstBotOfferAt = const Duration(seconds: 20);
  Duration botOfferAt = const Duration(seconds: 45);
  Duration keepFindAfter = const Duration(seconds: 4);
  Duration keepGivesUpAfter = const Duration(seconds: 60);
  Duration searchGivesUpAt = const Duration(seconds: 105);
  Duration opponentReadyAfter = const Duration(milliseconds: 800);
  Duration readyWait = const Duration(seconds: 10);
  Duration countdown = const Duration(seconds: 3);
  Duration questionLimit = const Duration(seconds: 15);
  Duration revealFor = const Duration(seconds: 3);
  Duration settleAfter = const Duration(milliseconds: 1500);
  int questionCount = 7;

  /// Players searching per subject, for "3 players searching · usually 20 s".
  int online = 3;
  int p50WaitS = 20;

  /// Nobody is ever found (only the bot offer and the timeout happen).
  bool noOneAround = false;

  /// The result is committed (REST has it), but `match.settled` is never sent.
  bool withholdSettlement = false;

  /// The opponent drops 2 s into this question, and is back after [opponentAwayFor].
  int? opponentDropsAtQ;
  Duration opponentAwayFor = const Duration(seconds: 8);

  /// The next opponent never gets ready: the match is aborted and the user requeued.
  bool opponentNeverReady = false;

  /// The opponent's answers, question by question. Unset: about 60% right in 3–9 s.
  List<DemoAnswerPlan?>? opponentPlan;

  /// When set, `mm.join` is answered `BUSY` with this as `details.active`.
  Map<String, Object?>? busyOnJoin;

  /// When set, `hello` without `takeover` is answered `LIVE_ELSEWHERE` for this match.
  String? liveElsewhereMatchId;

  /// How long a tournament game waits for the player to get ready.
  Duration tournamentReadyWait = const Duration(seconds: 90);

  /// Features built on top of the battle server (the Arena's tournaments).
  final List<DemoServerExtension> extensions = [];

  /// Demo players join a room the user makes (Riya a friend room; Riya, Neha and Kabir a group),
  /// the first after [guestJoinAfter] and then every 2 s.
  bool guestsJoin = true;
  Duration guestJoinAfter = const Duration(seconds: 4);

  /// Demo players get ready this long after joining.
  Duration guestReadyAfter = const Duration(milliseconds: 1500);

  /// A friend duel starts this long after both are ready (docs/user-flows.md section 5); a room
  /// hosted by a demo player starts this long after everyone is.
  Duration roomAutoStartAfter = const Duration(seconds: 3);

  /// Friends who accept an invite do so after this long.
  Duration inviteAnswerAfter = const Duration(seconds: 2);

  /// When set, Riya invites the user to a friend duel this long after the first `welcome`.
  Duration? inviteAfterWelcome;

  // ------------------------------------------------------------------------------------------
  // State

  final Set<Timer> _timers = {};
  final Map<String, DemoMatch> _matches = {};
  _DemoSocket? _socket;
  _Ticket? _ticket;
  Timer? _backgroundTimer;
  Timer? _disconnectTimer;
  bool _foreground = true;
  bool _disposed = false;
  int _sockets = 0;
  int _tickets = 0;
  int _matchCount = 0;
  String? _lastFoundId;
  int _lastFoundAt = 0;
  int _lastEmoteMs = 0;
  final Map<String, DemoRoom> _rooms = {};
  int _roomCount = 0;
  final Map<String, _DemoInvite> _invites = {};
  int _inviteCount = 0;
  bool _welcomedOnce = false;

  /// Every message the app sent, decoded.
  final List<Map<String, Object?>> received = [];

  /// How many sockets the app opened.
  int get connections => _sockets;

  int get now => _nowMs();

  /// The messages of [type] the app sent.
  List<Map<String, Object?>> receivedOfType(String type) => [
    for (final message in received)
      if (message['t'] == type) message,
  ];

  /// The match being played (or the last one).
  DemoMatch? get currentMatch => _lastFoundId == null ? null : _matches[_lastFoundId];

  DemoMatch? match(String matchId) => _matches[matchId];

  /// Whether a search is queued.
  bool get searching => _ticket != null;

  /// Whether the app is connected (and said hello).
  bool get connected => _socket?.welcomed ?? false;

  // ------------------------------------------------------------------------------------------
  // The connector

  @override
  Future<RealtimeSocket> connect() async {
    if (_disposed) throw StateError('The demo server is closed');
    final socket = _DemoSocket(this);
    _sockets++;
    return socket;
  }

  /// Closes the app's socket with 4409, as a newer connection elsewhere would.
  void supersede() => _socket?.closeFromServer(4409, 'Replaced by a newer connection');

  /// Drops the app's socket without a close code, like a lost network.
  void dropConnection() => _socket?.closeFromServer();

  void dispose() {
    _disposed = true;
    for (final timer in _timers) {
      timer.cancel();
    }
    _timers.clear();
    _backgroundTimer?.cancel();
    _disconnectTimer?.cancel();
    for (final match in _matches.values) {
      match._cancelTimers();
    }
    for (final room in _rooms.values) {
      room._cancelTimers();
    }
    _socket?.closeFromServer(1001, 'Server stopped');
  }

  // ------------------------------------------------------------------------------------------
  // Plumbing

  Timer _after(Duration delay, void Function() callback) {
    late final Timer timer;
    timer = Timer(delay < Duration.zero ? Duration.zero : delay, () {
      _timers.remove(timer);
      if (!_disposed) callback();
    });
    _timers.add(timer);
    return timer;
  }

  void _cancel(Timer? timer) {
    if (timer == null) return;
    timer.cancel();
    _timers.remove(timer);
  }

  /// Sends a frame to the app, if it's connected.
  void _send(Map<String, Object?> frame) {
    final socket = _socket;
    if (socket == null || !socket.welcomed) return;
    _after(latency, () => socket.push(frame));
  }

  static Map<String, Object?> _frame(
    String type,
    Map<String, Object?> data, {
    String? ch,
    int? seq,
    int? ts,
  }) => {'v': 1, 't': type, 'ch': ?ch, 'seq': ?seq, 'ts': ?ts, 'd': data};

  void _ack(String? ref) {
    if (ref != null) _send(_frame('ack', {'ref': ref}, ch: 'u', ts: now));
  }

  void _error(
    String? ref,
    String code,
    String message, {
    Map<String, Object?> details = const {},
    bool retryable = false,
  }) => _send(
    _frame(
      'error',
      {'ref': ?ref, 'code': code, 'message': message, 'retryable': retryable, 'details': details},
      ch: 'u',
      ts: now,
    ),
  );

  void _sendU(String type, Map<String, Object?> data) =>
      _send(_frame(type, data, ch: 'u', ts: now));

  // ------------------------------------------------------------------------------------------
  // For extensions

  /// Sends an event on the user's channel `u`.
  void sendUser(String type, Map<String, Object?> data) => _sendU(type, data);

  /// Sends an event on [channel] (no `seq`: for channels that aren't resumed, like `t:`).
  void sendOn(String channel, String type, Map<String, Object?> data) =>
      _send(_frame(type, data, ch: channel, ts: now));

  /// Confirms request [ref].
  void ack(String? ref) => _ack(ref);

  /// Refuses request [ref].
  void refuse(String? ref, String code, String message) => _error(ref, code, message);

  /// Runs [callback] after [delay] unless the server is disposed first.
  Timer after(Duration delay, void Function() callback) => _after(delay, callback);

  /// Starts a tournament game against [opponent]: [questions] questions, rated, and 90 s to get
  /// ready ([tournamentReadyWait]). [onEnd] gets the result from the player's side (`win`,
  /// `draw` or `loss`) once it's settled.
  DemoMatch startTournamentMatch({
    required String tournamentId,
    required DemoPlayer opponent,
    required String subject,
    int questions = 10,
    void Function(DemoMatch match, String result)? onEnd,
  }) {
    final id = 'demo-m${++_matchCount}';
    final match = DemoMatch._(
      this,
      id: id,
      mode: 'rated',
      subject: subject,
      chapter: null,
      opponents: [opponent],
      questions: _pick(subject, null, widened: true, count: questions),
      opponentNeverReady: false,
      requeue: null,
      tournamentId: tournamentId,
      onEnd: onEnd,
    );
    _matches[id] = match;
    _lastFoundId = id;
    _lastFoundAt = now;
    _after(latency * 2 + const Duration(milliseconds: 40), match._sendSnapshot);
    match._startReadyWait();
    return match;
  }

  void _socketClosed(_DemoSocket socket) {
    if (!identical(socket, _socket)) return;
    _socket = null;
    _roomPresence(connected: false, foreground: _foreground);
    // A queued search survives a disconnect for 10 s.
    if (_ticket != null) {
      _cancel(_disconnectTimer);
      _disconnectTimer = _after(const Duration(seconds: 10), () => _cancelTicket('disconnected'));
    }
  }

  void _receive(_DemoSocket socket, Map<String, Object?> message) {
    if (_disposed) return;
    received.add(message);
    final type = message['t'];
    final ref = message['id'] is String ? message['id']! as String : null;
    final data = switch (message['d']) {
      final Map<String, Object?> d => d,
      _ => const <String, Object?>{},
    };
    if (type == 'hello') {
      _hello(socket, data);
      return;
    }
    if (!identical(socket, _socket) || !socket.welcomed) return;
    switch (type) {
      case 'pong':
        break;
      case 'clock.ping':
        _send(_frame('clock.pong', {'c0': data['c0'], 's': now}));
      case 'client.state':
        _clientState(data['state'] == 'foreground');
      case 'mm.join':
        _join(ref, data);
      case 'mm.cancel':
        _cancelSearch(ref);
      case 'mm.respond':
        _respond(ref, data['choice']);
      case 'match.ready':
        _withMatch(ref, data, (match) => match._ready(ref));
      case 'ans.submit':
        _withMatch(ref, data, (match) => match._answer(ref, data));
      case 'emote':
        _withMatch(ref, data, (match) => _emote(match, ref, data['e']));
      case 'match.forfeit':
        _withMatch(ref, data, (match) => match._forfeit(ref));
      case 'match.rematch':
        _withMatch(ref, data, (match) => _rematch(match, ref, accept: data['accept'] != false));
      case 'sync':
        _sync(ref, data);
      case final String type when type.startsWith('room.'):
        _roomMessage(type, ref, data);
      default:
        if (type is String && extensions.any((e) => e.handle(type, ref, data))) return;
        _error(ref, 'BAD_REQUEST', 'Unknown message type');
    }
  }

  void _withMatch(String? ref, Map<String, Object?> data, void Function(DemoMatch match) action) {
    final match = _matches[data['match_id']];
    if (match == null) {
      _error(ref, 'NOT_FOUND', 'That match doesn\'t exist.');
      return;
    }
    action(match);
  }

  // ------------------------------------------------------------------------------------------
  // Connecting

  void _hello(_DemoSocket socket, Map<String, Object?> data) {
    final takeover = data['takeover'] == true;
    final elsewhere = liveElsewhereMatchId;
    if (elsewhere != null && !takeover) {
      socket.push(
        _frame(
          'error',
          {
            'code': 'LIVE_ELSEWHERE',
            'message': 'Your game is running on another device.',
            'retryable': false,
            'details': {'match_id': elsewhere},
          },
          ch: 'u',
          ts: now,
        ),
      );
      _after(latency, () => socket.closeFromServer(4409, 'Live elsewhere'));
      return;
    }
    if (takeover) liveElsewhereMatchId = null;
    if (_socket != null && !identical(_socket, socket)) _socket!.closeFromServer(4409, 'Replaced');
    _socket = socket;
    socket.welcomed = true;
    _cancel(_disconnectTimer);
    socket.push(
      _frame(
        'welcome',
        {
          'conn_id': 'demo-${_sockets.toString().padLeft(3, '0')}',
          'user_id': me.uid,
          'server_ms': now,
          'hb_s': 10,
          'active': [
            if (_ticket case final ticket?) {'kind': 'queue', 'id': ticket.id, 'state': 'queued'},
            for (final match in _matches.values)
              if (!match.isOver) {'kind': 'match', 'ch': match.channel, 'state': match.phase},
            for (final extension in extensions) ...extension.active,
            if (currentRoom case final room?) {'kind': 'room', 'id': room.id, 'ch': room.channel},
          ],
        },
        ch: 'u',
        ts: now,
      ),
    );
    socket.startPings(const Duration(seconds: 10));
    final resume = data['resume'];
    if (resume is List) {
      for (final entry in resume) {
        if (entry is Map && entry['ch'] is String) {
          final lastSeq = entry['last_seq'] is int ? entry['last_seq']! as int : 0;
          final channel = entry['ch']! as String;
          if (channel.startsWith('r:')) {
            _rooms[channel.substring(2)]?._resume(lastSeq);
          } else {
            _matches[channel.replaceFirst('m:', '')]?._resume(lastSeq);
          }
        }
      }
    }
    _roomPresence(connected: true, foreground: _foreground);
    final inviteAfter = inviteAfterWelcome;
    if (!_welcomedOnce && inviteAfter != null) _after(inviteAfter, sendInvite);
    _welcomedOnce = true;
  }

  void _clientState(bool foreground) {
    final changed = _foreground != foreground;
    _foreground = foreground;
    if (changed) _roomPresence(connected: true, foreground: foreground);
    _cancel(_backgroundTimer);
    // A queued search stops after 10 s in the background, without a penalty.
    if (!foreground && _ticket != null) {
      _backgroundTimer = _after(const Duration(seconds: 10), () => _cancelTicket('background'));
    }
  }

  void _sync(String? ref, Map<String, Object?> data) {
    final channel = data['ch'];
    if (channel is String && channel.startsWith('r:')) {
      final room = _rooms[channel.substring(2)];
      if (room == null || room.isClosed || !room.has(me.uid)) {
        _error(ref, 'NOT_FOUND', 'That room is gone.');
        return;
      }
      room._resume(data['last_seq'] is int ? data['last_seq']! as int : 0);
      return;
    }
    final match = channel is String ? _matches[channel.replaceFirst('m:', '')] : null;
    if (match == null) {
      _error(ref, 'NOT_FOUND', 'That game is gone.');
      return;
    }
    final lastSeq = data['last_seq'] is int ? data['last_seq']! as int : 0;
    match._resume(lastSeq);
  }

  // ------------------------------------------------------------------------------------------
  // Matchmaking

  void _join(String? ref, Map<String, Object?> data) {
    final mode = data['mode'] is String ? data['mode']! as String : 'rated';
    final subject = data['subject'] is String ? data['subject']! as String : 'physics';
    final chapter = data['chapter'] is String ? data['chapter']! as String : null;
    final idem = data['idem'] is String ? data['idem']! as String : '';
    final busy = busyOnJoin;
    if (busy != null) {
      _error(ref, 'BUSY', 'You\'re already in a match.', details: {'active': busy});
      return;
    }
    final ticket = _ticket;
    if (ticket != null) {
      if (ticket.idem == idem) {
        _queued(ticket);
      } else {
        _error(
          ref,
          'BUSY',
          'You\'re already searching.',
          details: {
            'active': {'kind': 'queue', 'id': ticket.id, 'title': 'Quick battle'},
          },
        );
      }
      return;
    }
    if (currentRoom case final room?) {
      _error(
        ref,
        'BUSY',
        'You\'re in a room.',
        details: {
          'active': {'kind': 'room', 'id': room.id, 'title': 'Room ${room.code}'},
        },
      );
      return;
    }
    final live = _matches.values.where((m) => !m.isOver).firstOrNull;
    if (live != null) {
      _error(
        ref,
        'BUSY',
        'You\'re already in a match.',
        details: {
          'active': {
            'kind': 'match',
            'id': live.id,
            'title': 'Quick battle vs ${live.opponent.name}',
          },
        },
      );
      return;
    }
    if (mode == 'casual' && world.coins < 5) {
      _error(ref, 'INSUFFICIENT_COINS', 'You need 5 coins.');
      return;
    }
    if (mode != 'bot') {
      world.last = BattleSelection(
        subject: subject,
        chapter: chapter,
        mode: mode == 'casual' ? BattleMode.casual : BattleMode.rated,
      );
    }
    if (mode == 'bot') {
      _startMatch(bot: true, mode: 'bot', subject: subject, chapter: chapter);
      return;
    }
    if (mode == 'casual') world.coins -= 5;
    final first = world.firstSearch;
    world.firstSearch = false;
    final queued = _Ticket(
      id: 'demo-t${++_tickets}',
      mode: mode,
      subject: subject,
      chapter: chapter,
      idem: idem,
      joinedAt: now,
    );
    _ticket = queued;
    _queued(queued);
    _sendU('mm.status', {
      'waited_s': 0,
      'widened': false,
      'window': 150,
      'online': online,
      'p50_wait_s': p50WaitS,
    });
    queued.timers
      ..add(_after(widenAt, () => _widen(queued)))
      ..add(_after(first ? firstBotOfferAt : botOfferAt, () => _offer(queued)))
      ..add(_after(searchGivesUpAt, () => _cancelTicket('timeout')));
    if (!first && !noOneAround) queued.timers.add(_after(findAfter, () => _found(queued)));
    if (!_foreground) _clientState(false);
  }

  void _queued(_Ticket ticket) => _sendU('mm.queued', {
    'ticket_id': ticket.id,
    'mode': ticket.mode,
    'subject': ticket.subject,
    'chapter': ticket.chapter,
    'joined_at': ticket.joinedAt,
  });

  void _widen(_Ticket ticket) {
    if (!identical(ticket, _ticket)) return;
    ticket.widened = true;
    _sendU('mm.status', {
      'waited_s': ((now - ticket.joinedAt) / 1000).round(),
      'widened': true,
      'window': null,
      'online': online,
      'p50_wait_s': p50WaitS,
    });
  }

  void _offer(_Ticket ticket) {
    if (!identical(ticket, _ticket)) return;
    _sendU('mm.timeout', {
      'waited_s': ((now - ticket.joinedAt) / 1000).round(),
      'options': ['keep', 'bot', 'invite', 'cancel'],
    });
  }

  void _respond(String? ref, Object? choice) {
    final ticket = _ticket;
    if (ticket == null) {
      _error(ref, 'NOT_FOUND', 'You\'re not searching.');
      return;
    }
    _ack(ref);
    switch (choice) {
      case 'keep':
        // 60 s more, then the search stops by itself.
        for (final timer in ticket.timers) {
          _cancel(timer);
        }
        ticket.timers.add(_after(keepGivesUpAfter, () => _cancelTicket('timeout')));
        if (!noOneAround) ticket.timers.add(_after(keepFindAfter, () => _found(ticket)));
      case 'bot':
        _cancelTicket('user');
        _startMatch(bot: true, mode: 'bot', subject: ticket.subject, chapter: ticket.chapter);
      default:
        _cancelTicket('user');
    }
  }

  void _cancelSearch(String? ref) {
    if (_ticket != null) {
      _ack(ref);
      _cancelTicket('user');
      return;
    }
    final found = _lastFoundId;
    if (found != null && now - _lastFoundAt < 5000 && !(_matches[found]?.isOver ?? true)) {
      _error(ref, 'ALREADY_MATCHED', 'A match was just found.', details: {'match_id': found});
      return;
    }
    _ack(ref);
  }

  void _cancelTicket(String reason) {
    final ticket = _ticket;
    if (ticket == null) return;
    for (final timer in ticket.timers) {
      _cancel(timer);
    }
    _cancel(_backgroundTimer);
    _cancel(_disconnectTimer);
    _ticket = null;
    final refunded = ticket.mode == 'casual' ? 5 : 0;
    world.coins += refunded;
    _sendU('mm.cancelled', {'reason': reason, 'refunded': refunded});
  }

  void _found(_Ticket ticket) {
    if (!identical(ticket, _ticket)) return;
    for (final timer in ticket.timers) {
      _cancel(timer);
    }
    _cancel(_backgroundTimer);
    _ticket = null;
    _startMatch(
      bot: false,
      mode: ticket.mode,
      subject: ticket.subject,
      chapter: ticket.chapter,
      widened: ticket.widened,
      requeue: ticket,
    );
  }

  void _startMatch({
    required bool bot,
    required String mode,
    required String subject,
    String? chapter,
    bool widened = false,
    _Ticket? requeue,
  }) {
    final id = 'demo-m${++_matchCount}';
    final opponent = bot ? DemoPlayer.bot : DemoPlayer.riya;
    final questions = _pick(subject, chapter, widened: widened);
    final neverReady = opponentNeverReady && !bot;
    opponentNeverReady = false;
    final match = DemoMatch._(
      this,
      id: id,
      mode: mode,
      subject: subject,
      chapter: chapter,
      opponents: [opponent],
      questions: questions,
      opponentNeverReady: neverReady,
      requeue: requeue,
    );
    _matches[id] = match;
    _lastFoundId = id;
    _lastFoundAt = now;
    _sendU('mm.found', {
      'match_id': id,
      'ch': match.channel,
      'mode': mode,
      'opponent': {
        ...opponent.card(),
        if (!bot) 'rating': {'display': opponent.rating, 'value': 1548, 'provisional': false},
        if (!bot) 'record': {'wins': 3, 'losses': 1, 'draws': 0},
      },
      'sources': match.sources,
      'bot': bot,
    });
    // The first frame on the match channel.
    _after(latency * 2 + const Duration(milliseconds: 40), match._sendSnapshot);
    match._startReadyWait();
  }

  /// Seven questions: the chapter's first, then the rest of the subject, then anything.
  List<_DemoQuestion> _pick(String subject, String? chapter, {required bool widened, int? count}) {
    final ordered = <FakeQuestion>[
      ..._questions.where((q) => q.subject == subject && q.chapter.slug == chapter),
      ..._questions.where((q) => q.subject == subject && q.chapter.slug != chapter),
      ..._questions.where((q) => q.subject != subject),
    ];
    final picked = [for (var i = 0; i < (count ?? questionCount); i++) ordered[i % ordered.length]];
    return [for (final question in picked) _DemoQuestion(question, _random)];
  }

  void _emote(DemoMatch match, String? ref, Object? emote) {
    if (emote is! String || match.isOver) {
      _error(ref, 'NOT_ALLOWED', 'The game is over.');
      return;
    }
    if (now - _lastEmoteMs < 3000) {
      _error(ref, 'RATE_LIMITED', 'Slow down.', details: {'retry_after_s': 3}, retryable: true);
      return;
    }
    _lastEmoteMs = now;
    _ack(ref);
    match._shared('emote', {'uid': me.uid, 'e': emote});
    if (!match.bot && _random.nextBool()) {
      _after(const Duration(milliseconds: 1200), () {
        if (!match.isOver) {
          match._shared('emote', {
            'uid': match.opponent.uid,
            'e': emote == 'oops' ? 'nice' : emote,
          });
        }
      });
    }
  }

  void _rematch(DemoMatch match, String? ref, {required bool accept}) {
    if (match.mode != 'casual' || match.phase != 'finished') {
      _error(ref, 'NOT_ALLOWED', 'Rematches are for casual games.');
      return;
    }
    if (!accept) {
      match._shared('rematch.status', {
        'match_id': match.id,
        'state': 'declined',
        'by': me.uid,
        'reason': null,
      });
      return;
    }
    match._shared('rematch.status', {
      'match_id': match.id,
      'state': 'offered',
      'by': me.uid,
      'reason': null,
    });
    _after(const Duration(milliseconds: 1500), () {
      if (world.coins < 5) {
        match._shared('rematch.status', {
          'match_id': match.id,
          'state': 'failed',
          'by': match.opponent.uid,
          'reason': 'insufficient_coins',
        });
        return;
      }
      match._shared('rematch.status', {
        'match_id': match.id,
        'state': 'accepted',
        'by': match.opponent.uid,
        'reason': null,
      });
      world.coins -= 5;
      _startMatch(bot: false, mode: 'casual', subject: match.subject, chapter: match.chapter);
    });
  }

  /// Requeues a search whose opponent never got ready.
  void _requeue(_Ticket ticket) {
    final waited = ((now - ticket.joinedAt) / 1000).round();
    final again = _Ticket(
      id: 'demo-t${++_tickets}',
      mode: ticket.mode,
      subject: ticket.subject,
      chapter: ticket.chapter,
      idem: ticket.idem,
      joinedAt: ticket.joinedAt,
    )..widened = ticket.widened;
    if (ticket.mode == 'casual') world.coins -= 5;
    _ticket = again;
    _sendU('mm.requeued', {'reason': 'opponent_not_ready', 'waited_s': waited});
    again.timers
      ..add(_after(findAfter, () => _found(again)))
      ..add(_after(searchGivesUpAt - Duration(seconds: waited), () => _cancelTicket('timeout')));
  }

  // ------------------------------------------------------------------------------------------
  // REST, for the demo repositories

  /// `GET /v1/matches/{id}`, as JSON.
  Map<String, Object?>? summaryJson(String matchId) => _matches[matchId]?._summary();

  /// `GET /v1/matches/{id}/review`, as JSON; null until the match has ended.
  Map<String, Object?>? reviewJson(String matchId, {Set<String> bookmarks = const {}}) {
    final match = _matches[matchId];
    if (match == null || !match.isOver) return null;
    return match._review(bookmarks);
  }

  /// The correct option of question [q] of [matchId], for tests.
  String? correctOption(String matchId, int q) {
    final match = _matches[matchId];
    if (match == null || q < 1 || q > match._questions.length) return null;
    return match._questions[q - 1].correctId;
  }

  /// The text of option [optionId] of question [q] of [matchId], for tests.
  String? optionText(String matchId, int q, String? optionId) {
    final match = _matches[matchId];
    if (match == null || q < 1 || q > match._questions.length) return null;
    return match._questions[q - 1].options.where((o) => o.$1 == optionId).firstOrNull?.$2;
  }

  /// A wrong option of question [q] of [matchId], for tests.
  String? wrongOption(String matchId, int q) {
    final match = _matches[matchId];
    if (match == null || q < 1 || q > match._questions.length) return null;
    final question = match._questions[q - 1];
    return question.options.firstWhere((o) => o.$1 != question.correctId).$1;
  }
}

class _Ticket {
  _Ticket({
    required this.id,
    required this.mode,
    required this.subject,
    required this.chapter,
    required this.idem,
    required this.joinedAt,
  });

  final String id;
  final String mode;
  final String subject;
  final String? chapter;
  final String idem;
  final int joinedAt;
  bool widened = false;
  final List<Timer> timers = [];
}

class _DemoQuestion {
  _DemoQuestion(this.source, Random random) {
    final order = List.generate(source.options.length, (i) => i)..shuffle(random);
    options = [for (final index in order) (_optionId(random), source.options[index], index)];
    correctId = options.firstWhere((o) => o.$3 == source.answer).$1;
  }

  final FakeQuestion source;

  /// (id, text, authored index), in the order shown.
  late final List<(String, String, int)> options;
  late final String correctId;

  static const _alphabet = 'ABCDEFGHJKMNPQRSTVWXYZabcdefghjkmnpqrstvwxyz23456789';

  static String _optionId(Random random) =>
      String.fromCharCodes(List.generate(5, (_) => _alphabet.codeUnitAt(random.nextInt(52))));
}

/// A feature that adds message types to the demo server (the Arena's `sub` and `unsub`).
abstract interface class DemoServerExtension {
  /// Handles a message of [type]; false when it isn't one of this extension's.
  bool handle(String type, String? ref, Map<String, Object?> data);

  /// What to add to `welcome.active` (a running tournament).
  List<Map<String, Object?>> get active;
}

/// The app's end of a demo connection.
final class _DemoSocket implements RealtimeSocket {
  _DemoSocket(this._server);

  final DemoRealtimeServer _server;
  final StreamController<Object?> _frames = StreamController<Object?>();
  bool _closed = false;
  int? _closeCode;
  String? _closeReason;
  Timer? _pings;
  int _pingCount = 0;
  bool welcomed = false;

  @override
  Stream<Object?> get frames => _frames.stream;

  @override
  int? get closeCode => _closeCode;

  @override
  String? get closeReason => _closeReason;

  @override
  void send(String text) {
    if (_closed) return;
    final Object? message;
    try {
      message = jsonDecode(text);
    } on FormatException {
      return;
    }
    if (message is! Map<String, Object?>) return;
    final map = message;
    _server._after(_server.latency, () {
      if (!_closed) _server._receive(this, map);
    });
  }

  @override
  Future<void> close([int? code, String? reason]) async {
    if (_closed) return;
    _closed = true;
    _pings?.cancel();
    unawaited(_frames.close());
    _server._socketClosed(this);
  }

  void push(Map<String, Object?> frame) {
    if (!_closed) _frames.add(jsonEncode(frame));
  }

  void startPings(Duration every) {
    _pings?.cancel();
    _pings = Timer.periodic(every, (_) {
      if (_server._disposed) {
        _pings?.cancel();
        return;
      }
      push(DemoRealtimeServer._frame('ping', {'n': ++_pingCount}, ch: 'u', ts: _server.now));
    });
  }

  void closeFromServer([int? code, String? reason]) {
    if (_closed) return;
    _closed = true;
    _closeCode = code;
    _closeReason = reason;
    _pings?.cancel();
    unawaited(_frames.close());
    _server._socketClosed(this);
  }
}
