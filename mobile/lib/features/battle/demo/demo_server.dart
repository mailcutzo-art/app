import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:realtime_client/realtime_client.dart';

import '../../learn/data/fake_learn_repository.dart';
import '../data/battle_models.dart';
import 'demo_world.dart';

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
      opponent: opponent,
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
          _matches[(entry['ch']! as String).replaceFirst('m:', '')]?._resume(lastSeq);
        }
      }
    }
  }

  void _clientState(bool foreground) {
    _foreground = foreground;
    _cancel(_backgroundTimer);
    // A queued search stops after 10 s in the background, without a penalty.
    if (!foreground && _ticket != null) {
      _backgroundTimer = _after(const Duration(seconds: 10), () => _cancelTicket('background'));
    }
  }

  void _sync(String? ref, Map<String, Object?> data) {
    final channel = data['ch'];
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
      opponent: opponent,
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

class _Pick {
  const _Pick({required this.opt, required this.ms, required this.status});

  final String? opt;
  final int ms;
  final String status;
}

/// One demo match: the server side of the match state machine.
class DemoMatch {
  DemoMatch._(
    this._server, {
    required this.id,
    required this.mode,
    required this.subject,
    required this.chapter,
    required this.opponent,
    required this._questions,
    required this.opponentNeverReady,
    required this._requeue,
    this.tournamentId,
    this._onEnd,
  }) : bot = opponent.isBot,
       createdAt = _server.now;

  final DemoRealtimeServer _server;
  final String id;
  final String mode;
  final String subject;
  final String? chapter;
  final DemoPlayer opponent;
  final List<_DemoQuestion> _questions;
  final bool bot;
  final bool opponentNeverReady;
  final _Ticket? _requeue;

  /// Set for a tournament round's game.
  final String? tournamentId;
  final void Function(DemoMatch match, String result)? _onEnd;
  final int createdAt;

  String get channel => 'm:$id';

  String get kind => tournamentId != null
      ? 'tournament'
      : bot
      ? 'bot'
      : (mode == 'casual' ? 'quick_casual' : 'quick_rated');

  int seq = 0;
  final List<Map<String, Object?>> _log = [];
  String phase = 'ready_wait';
  int q = 0;
  int? endsAt;
  bool _meReady = false;
  bool _opponentReady = false;
  final Map<int, _Pick> _mine = {};
  final Map<int, _Pick> _theirs = {};
  final Map<int, Map<String, Object?>> _reveals = {};
  final Map<int, int> _shownAt = {};
  int myPoints = 0;
  int myCorrect = 0;
  int opponentPoints = 0;
  int opponentCorrect = 0;
  bool _opponentConnected = true;
  int? _graceUntil;
  Map<String, Object?>? _end;
  Map<String, Object?>? _settlement;
  bool settled = false;
  final Set<Timer> _timers = {};

  bool get isOver => phase == 'finished' || phase == 'aborted' || phase == 'voided';

  String get _me => _server.me.uid;

  int get _now => _server.now;

  int get _limitMs => _server.questionLimit.inMilliseconds;

  /// Where the questions come from: `[{chapter, name, count}]`.
  List<Map<String, Object?>> get sources {
    final counts = <String, (String, int)>{};
    for (final question in _questions) {
      final chapter = question.source.chapter;
      final (name, count) = counts[chapter.slug] ?? (chapter.name, 0);
      counts[chapter.slug] = (name, count + 1);
    }
    return [
      for (final MapEntry(key: slug, value: (name, count)) in counts.entries)
        {'chapter': slug, 'name': name, 'count': count},
    ];
  }

  void _after(Duration delay, void Function() callback) {
    late final Timer timer;
    timer = _server._after(delay, () {
      _timers.remove(timer);
      callback();
    });
    _timers.add(timer);
  }

  void _cancelTimers() {
    for (final timer in _timers) {
      _server._cancel(timer);
    }
    _timers.clear();
  }

  /// A shared event: numbered and kept in the channel's log.
  void _shared(String type, Map<String, Object?> data) {
    final frame = DemoRealtimeServer._frame(type, data, ch: channel, seq: ++seq, ts: _now);
    _log.add(frame);
    _server._send(frame);
  }

  /// A message for this player only: no seq, never logged.
  void _private(String type, Map<String, Object?> data) =>
      _server._send(DemoRealtimeServer._frame(type, data, ch: channel, ts: _now));

  void _sendSnapshot() => _server._send(
    DemoRealtimeServer._frame('match.snapshot', _snapshot(), ch: channel, seq: seq, ts: _now),
  );

  /// Replays what the app missed, or sends a snapshot when the log can't.
  void _resume(int lastSeq) {
    if (lastSeq <= 0 || lastSeq > seq) {
      _sendSnapshot();
      return;
    }
    for (final frame in _log.where((f) => (f['seq']! as int) > lastSeq)) {
      _server._send(frame);
    }
  }

  Map<String, Object?> _card(DemoPlayer player) => player.card();

  Map<String, Object?> _snapshot() {
    final question = q == 0 ? null : _questions[q - 1];
    return {
      'match_id': id,
      'kind': kind,
      'phase': phase,
      'ends_at': endsAt,
      'q': q,
      'total': _questions.length,
      'limit_ms': _limitMs,
      'players': [
        {
          ..._card(_server.me),
          'connected': true,
          'score': myPoints,
          'correct': myCorrect,
          'answered': _mine.containsKey(q) && q > 0,
        },
        {
          ..._card(opponent),
          'connected': _opponentConnected,
          'grace_until': _graceUntil,
          'score': opponentPoints,
          'correct': opponentCorrect,
          'answered': _theirs.containsKey(q) && q > 0,
        },
      ],
      'question': question == null || (phase != 'q_open' && phase != 'q_reveal') ? null : _show(q),
      'reveal': _reveals.isEmpty ? null : _reveals[_reveals.keys.reduce(max)],
      'mine': [
        for (final MapEntry(key: number, value: pick) in _mine.entries)
          {'q': number, 'opt': pick.opt, 'status': pick.status},
      ],
      'end': _end,
      'settled': settled,
    };
  }

  Map<String, Object?> _show(int number) {
    final question = _questions[number - 1];
    final shownAt = _shownAt[number]!;
    return {
      'q': number,
      'total': _questions.length,
      'stem': question.source.stem,
      'options': [
        for (final (id, text, _) in question.options) {'id': id, 'text': text},
      ],
      'shown_at': shownAt,
      'deadline_at': shownAt + _limitMs,
      'limit_ms': _limitMs,
      'chapter': question.source.chapter.name,
    };
  }

  // ---------------------------------------------------------------------------------------
  // Ready and countdown

  void _startReadyWait() {
    if (!opponentNeverReady) {
      _after(bot ? Duration.zero : _server.opponentReadyAfter, () {
        _opponentReady = true;
        _maybeStart();
      });
    }
    if (tournamentId != null) {
      // A tournament player who never gets ready gives the opponent a forfeit win.
      _after(_server.tournamentReadyWait, () {
        if (phase == 'ready_wait') _finish('no_show', forcedResult: _meReady ? 'win' : 'loss');
      });
      return;
    }
    _after(_server.readyWait, () {
      if (phase != 'ready_wait') return;
      _abort();
    });
  }

  void _ready(String? ref) {
    _server._ack(ref);
    _meReady = true;
    _maybeStart();
  }

  void _maybeStart() {
    if (phase != 'ready_wait' || !_meReady || !_opponentReady) return;
    phase = 'countdown';
    endsAt = _now + _server.countdown.inMilliseconds;
    _shared('match.phase', {'phase': 'countdown', 'q': 0, 'ends_at': endsAt});
    final shownAt = endsAt!;
    _after(_server.countdown - const Duration(milliseconds: 400), () => _showQuestion(1, shownAt));
  }

  void _abort() {
    phase = 'aborted';
    endsAt = null;
    _cancelTimers();
    _end = {'result': 'draw', 'reason': 'aborted', 'totals': <String, Object?>{}, 'ranking': []};
    _shared('match.end', _end!);
    if (mode == 'casual') _server.world.coins += 5;
    final ticket = _requeue;
    if (_meReady && ticket != null) _server._requeue(ticket);
  }

  // ---------------------------------------------------------------------------------------
  // Questions

  void _showQuestion(int number, int shownAt) {
    if (isOver) return;
    q = number;
    phase = 'q_open';
    _shownAt[number] = shownAt;
    endsAt = shownAt + _limitMs;
    _shared('q.show', _show(number));

    final plan = _server.opponentPlan;
    final DemoAnswerPlan? answer;
    if (plan != null) {
      answer = number <= plan.length ? plan[number - 1] : null;
    } else {
      final random = _server._random;
      final accuracy = bot ? 0.55 : 0.6;
      // Log-normal around 6 s, never under 1.5 s.
      final gaussian = sqrt(-2 * log(1 - random.nextDouble())) * cos(2 * pi * random.nextDouble());
      final ms = (6000 * exp(0.35 * gaussian)).round().clamp(1500, _limitMs - 800);
      answer = DemoAnswerPlan(correct: random.nextDouble() < accuracy, ms: ms);
    }
    if (answer != null) {
      final plan = answer;
      _after(
        Duration(milliseconds: shownAt + plan.ms - _now),
        () => _opponentAnswers(number, plan),
      );
    }
    if (_server.opponentDropsAtQ == number && !bot) {
      _after(Duration(milliseconds: shownAt + 2000 - _now), _opponentDrops);
    }
    _after(Duration(milliseconds: endsAt! + 250 - _now), () => _reveal(number));
  }

  void _opponentDrops() {
    if (isOver) return;
    _opponentConnected = false;
    _graceUntil = _now + 30000;
    _shared('opp.conn', {'uid': opponent.uid, 'state': 'reconnecting', 'grace_until': _graceUntil});
    _after(_server.opponentAwayFor, () {
      if (isOver) return;
      _opponentConnected = true;
      _graceUntil = null;
      _shared('opp.conn', {'uid': opponent.uid, 'state': 'connected', 'grace_until': null});
    });
  }

  void _opponentAnswers(int number, DemoAnswerPlan plan) {
    if (phase != 'q_open' || q != number || !_opponentConnected || _theirs.containsKey(number)) {
      return;
    }
    final question = _questions[number - 1];
    final wrong = question.options.where((o) => o.$1 != question.correctId).toList();
    final opt = plan.correct ? question.correctId : wrong[_server._random.nextInt(wrong.length)].$1;
    _theirs[number] = _Pick(opt: opt, ms: plan.ms, status: 'accepted');
    _progress(number);
  }

  void _progress(int number) {
    _shared('q.progress', {
      'q': number,
      'answered': [
        if (_mine[number]?.status == 'accepted') _me,
        if (_theirs.containsKey(number)) opponent.uid,
      ],
    });
    final everyone = _mine[number]?.status == 'accepted' && _theirs.containsKey(number);
    if (everyone) _after(const Duration(milliseconds: 300), () => _reveal(number));
  }

  void _answer(String? ref, Map<String, Object?> data) {
    final number = data['q'] is int ? data['q']! as int : 0;
    final first = _mine[number];
    if (first != null) {
      _private('ans.ack', {'ref': ref, 'q': number, 'status': first.status, 'dup': true});
      return;
    }
    if (phase != 'q_open' || number != q) {
      _private('ans.ack', {'ref': ref, 'q': number, 'status': 'wrong_phase', 'dup': false});
      return;
    }
    final opt = data['opt'];
    final question = _questions[number - 1];
    if (opt is! String || !question.options.any((o) => o.$1 == opt)) {
      _private('ans.ack', {'ref': ref, 'q': number, 'status': 'invalid', 'dup': false});
      return;
    }
    final raw = _now - _shownAt[number]!;
    final elMs = data['el_ms'] is int ? data['el_ms']! as int : raw;
    final effective = elMs.clamp(raw - 100, raw);
    final status = raw < 0
        ? 'too_early'
        : (effective > _limitMs || raw > _limitMs + 100 ? 'late' : 'accepted');
    _mine[number] = _Pick(opt: status == 'accepted' ? opt : null, ms: effective, status: status);
    _private('ans.ack', {'ref': ref, 'q': number, 'status': status, 'dup': false});
    if (status == 'accepted') _progress(number);
  }

  int _points(bool correct, int ms) {
    if (!correct) return 0;
    final t = ((ms - 1000) / (_limitMs - 1000)).clamp(0.0, 1.0);
    return 100 + (50 * (1 - t)).round();
  }

  void _reveal(int number) {
    if (isOver || _reveals.containsKey(number) || number != q) return;
    phase = 'q_reveal';
    endsAt = null;
    final question = _questions[number - 1];
    final mine = _mine[number];
    final theirs = _theirs[number];
    final myOpt = mine?.opt;
    final theirOpt = theirs?.opt;
    final iAmRight = myOpt == question.correctId;
    final theyAreRight = theirOpt == question.correctId;
    final myPts = _points(iAmRight, mine?.ms ?? 0);
    final theirPts = _points(theyAreRight, theirs?.ms ?? 0);
    myPoints += myPts;
    opponentPoints += theirPts;
    if (iAmRight) myCorrect++;
    if (theyAreRight) opponentCorrect++;
    String? speed(int? mineMs, int? otherMs) {
      if (bot) return null;
      if (mineMs == null && otherMs == null) return null;
      if (mineMs == null) return 'slow';
      if (otherMs == null) return 'fast';
      if (mineMs < otherMs - 250) return 'fast';
      if (mineMs > otherMs + 250) return 'slow';
      return 'even';
    }

    final myMs = myOpt == null ? null : mine!.ms;
    final theirMs = theirOpt == null ? null : theirs!.ms;
    final reveal = {
      'q': number,
      'correct': question.correctId,
      'players': {
        _me: {
          'opt': myOpt,
          'correct': iAmRight,
          'pts': myPts,
          'time_ms': myMs,
          'speed': speed(myMs, theirMs),
        },
        opponent.uid: {
          'opt': theirOpt,
          'correct': theyAreRight,
          'pts': theirPts,
          'time_ms': theirMs,
          'speed': speed(theirMs, myMs),
        },
      },
      'totals': _totals(),
      'ref': question.source.ref,
    };
    _reveals[number] = reveal;
    _shared('q.reveal', reveal);
    if (number < _questions.length) {
      final nextShown = _now + _server.revealFor.inMilliseconds;
      _after(
        _server.revealFor - const Duration(milliseconds: 400),
        () => _showQuestion(number + 1, nextShown),
      );
    } else {
      _after(const Duration(seconds: 2), () => _finish('normal'));
    }
  }

  Map<String, Object?> _totals() => {
    _me: {'points': myPoints, 'correct': myCorrect},
    opponent.uid: {'points': opponentPoints, 'correct': opponentCorrect},
  };

  // ---------------------------------------------------------------------------------------
  // The end

  void _forfeit(String? ref) {
    _server._ack(ref);
    if (isOver) return;
    if (q == 0) {
      _abort();
      return;
    }
    _finish('forfeit', forcedResult: 'loss');
  }

  String _result() {
    if (myPoints != opponentPoints) return myPoints > opponentPoints ? 'win' : 'loss';
    if (myCorrect != opponentCorrect) return myCorrect > opponentCorrect ? 'win' : 'loss';
    int time(Map<int, _Pick> picks) => [
      for (final MapEntry(key: number, value: pick) in picks.entries)
        if (pick.opt == _questions[number - 1].correctId) pick.ms,
    ].fold(0, (sum, ms) => sum + ms);
    final mine = time(_mine);
    final theirs = time(_theirs);
    if (mine == theirs) return 'draw';
    return mine < theirs ? 'win' : 'loss';
  }

  void _finish(String reason, {String? forcedResult}) {
    if (isOver) return;
    _cancelTimers();
    phase = 'finished';
    endsAt = null;
    final result = forcedResult ?? _result();
    _end = {
      'result': result,
      'reason': reason,
      'totals': _totals(),
      'ranking': switch (result) {
        'win' => [
          [_me],
          [opponent.uid],
        ],
        'loss' => [
          [opponent.uid],
          [_me],
        ],
        _ => [
          [_me, opponent.uid],
        ],
      },
    };
    _shared('match.end', _end!);
    _after(_server.settleAfter, () {
      _settlement = _settle(result);
      settled = true;
      if (!_server.withholdSettlement) _private('match.settled', {'match_id': id, ..._settlement!});
      _onEnd?.call(this, result);
    });
  }

  Map<String, Object?> _settle(String result) {
    final world = _server.world;
    final win = result == 'win';
    final draw = result == 'draw';
    Map<String, Object?>? rating;
    Map<String, Object?>? rank;
    if (mode == 'rated' && !bot) {
      final subjectRating = world.rating(subject);
      final before = subjectRating.display;
      final delta = win ? 16 : (draw ? 2 : -12);
      subjectRating.value = (subjectRating.value ?? 1500) + delta;
      rating = {'scope': subject, 'before': before, 'after': subjectRating.display, 'delta': delta};
      final position = subjectRating.position;
      if (position != null) {
        final after = (position + (win ? -5 : (draw ? 0 : 2))).clamp(1, 100000);
        rank = {'board': 'rating:$subject', 'before': position, 'after': after};
        subjectRating.position = after;
      } else {
        subjectRating.gamesToRank = max(0, subjectRating.gamesToRank - 1);
        rank = {'board': 'rating:$subject', 'games_to_rank': subjectRating.gamesToRank};
      }
    }
    // Tournament games pay out in the tournament's prizes, not per game.
    final coins = bot || tournamentId != null ? 0 : (win ? 10 : (draw && mode == 'casual' ? 5 : 0));
    world.coins += coins;
    // Tournament games give 10 XP for each round played.
    final xp = tournamentId != null ? 10 : (win ? 30 : (draw ? 20 : 10)) ~/ (bot ? 2 : 1);
    final levelUp = world.addXp(xp);
    world.gamesToday++;
    if (win) world.wins++;
    final extended = !world.playedToday;
    if (extended) world.streakDays++;
    world.playedToday = true;
    final slower = [
      for (final reveal in _reveals.values)
        if (((reveal['players']! as Map)[_me]! as Map)['speed'] == 'slow') reveal,
    ].length;
    final chapterName = _questions.first.source.chapter.name;
    final chapterSlug = _questions.first.source.chapter.slug;
    return {
      'rating': rating,
      'rank': rank,
      'coins': {'delta': coins, 'balance': world.coins, 'capped': false},
      'xp': {
        'delta': xp,
        'level': world.level,
        'into_level': world.intoLevel,
        'for_next': world.forNext,
        'level_up': levelUp,
        'capped': false,
      },
      'resets_at': DateTime.fromMillisecondsSinceEpoch(_now)
          .add(const Duration(days: 1))
          .copyWith(hour: 0, minute: 0, second: 0, millisecond: 0, microsecond: 0)
          .millisecondsSinceEpoch,
      'missions': [
        {
          'id': 'play-3',
          'title': 'Play 3 battles',
          'progress': min(world.gamesToday, 3),
          'target': 3,
          'done': world.gamesToday >= 3,
        },
        {
          'id': 'win-1',
          'title': 'Win a battle',
          'progress': min(world.wins, 1),
          'target': 1,
          'done': world.wins >= 1,
        },
      ],
      'streak': {'days': world.streakDays, 'extended': extended},
      'achievements': [
        if (win && world.wins == 1) {'id': 'first-win', 'title': 'First win'},
      ],
      'tip': slower >= 2
          ? {
              'message':
                  'You were slower on $slower of ${_questions.length}. Try a timed set in $chapterName.',
              'action': 'timed_practice',
              'params': {'subject': subject, 'chapter': chapterSlug},
            }
          : {
              'message': 'Keep it going: 10 more questions in $chapterName.',
              'action': 'practice',
              'params': {'subject': subject, 'chapter': chapterSlug, 'count': '10'},
            },
    };
  }

  Map<String, Object?> _summary() {
    final end = _end;
    final result = switch (phase) {
      'aborted' => 'aborted',
      'voided' => 'voided',
      _ => end?['result'],
    };
    return {
      'id': id,
      'kind': kind,
      'subject': subject,
      'chapters': [for (final source in sources) source['name']],
      'played_at': DateTime.fromMillisecondsSinceEpoch(createdAt, isUtc: true).toIso8601String(),
      'result': result,
      'reason': end?['reason'],
      'score': {'me': myPoints, 'best_other': opponentPoints},
      'opponents': [_card(opponent)..['id'] = opponent.uid],
      'rating_delta': (_settlement?['rating'] as Map?)?['delta'],
      'coins_delta': (_settlement?['coins'] as Map?)?['delta'],
      'status': switch (phase) {
        'aborted' => 'aborted',
        'voided' => 'voided',
        'finished' => settled ? 'settled' : 'settling',
        _ => 'live',
      },
      'totals': _totals(),
      'settlement': settled ? _settlement : null,
    };
  }

  Map<String, Object?> _review(Set<String> bookmarks) => {
    'questions': [
      for (final (i, question) in _questions.indexed)
        {
          'q': i + 1,
          'ref': question.source.ref,
          'stem': question.source.stem,
          'options': [
            for (final (id, text, _) in question.options) {'id': id, 'text': text},
          ],
          'correct': question.correctId,
          'explanation': question.source.explanation,
          'chapter': question.source.chapter.name,
          'topic': question.source.chapter.topicName(question.source.topic),
          'players': {
            if (_reveals[i + 1] case final reveal?) ...(reveal['players']! as Map<String, Object?>),
          },
          'bookmarked': bookmarks.contains(question.source.ref),
        },
    ],
  };
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
