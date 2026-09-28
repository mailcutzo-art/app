part of 'demo_server.dart';

class _Pick {
  const _Pick({required this.opt, required this.ms, required this.status});

  final String? opt;
  final int ms;
  final String status;
}

/// One demo match: the server side of the match state machine, for a Quick Battle, a Practice
/// Bot game, a friend duel or a group battle of up to 8.
class DemoMatch {
  DemoMatch._(
    this._server, {
    required this.id,
    required this.mode,
    required this.subject,
    required this.chapter,
    required List<DemoPlayer> opponents,
    required this._questions,
    required this.opponentNeverReady,
    required this._requeue,
    this.room,
    this.leaderboard = false,
    int? limitMs,
  }) : opponents = List.unmodifiable(opponents),
       bot = opponents.first.isBot,
       createdAt = _server.now,
       _limit = limitMs {
    for (final player in opponents) {
      _theirs[player.uid] = {};
      _points[player.uid] = 0;
      _correct[player.uid] = 0;
    }
  }

  final DemoRealtimeServer _server;
  final String id;
  final String mode;
  final String subject;
  final String? chapter;

  /// Everyone but the user, in join order. A Quick Battle has one.
  final List<DemoPlayer> opponents;
  final List<_DemoQuestion> _questions;
  final bool bot;
  final bool opponentNeverReady;
  final _Ticket? _requeue;
  final int createdAt;

  /// The room this game was started in, if any.
  final DemoRoom? room;

  /// Whether `q.reveal` carries the group standings.
  final bool leaderboard;
  final int? _limit;

  DemoPlayer get opponent => opponents.first;

  String get channel => 'm:$id';

  bool get isGroup => room?.kind == 'group';

  String get kind => switch (room?.kind) {
    final String roomKind => roomKind,
    _ => bot ? 'bot' : (mode == 'casual' ? 'quick_casual' : 'quick_rated'),
  };

  int seq = 0;
  final List<Map<String, Object?>> _log = [];
  String phase = 'ready_wait';
  int q = 0;
  int? endsAt;
  bool _meReady = false;
  bool _opponentReady = false;
  final Map<int, _Pick> _mine = {};
  final Map<String, Map<int, _Pick>> _theirs = {};
  final Map<int, Map<String, Object?>> _reveals = {};
  final Map<int, int> _shownAt = {};
  final Map<String, int> _points = {};
  final Map<String, int> _correct = {};
  final Map<String, int> _places = {};
  int myPoints = 0;
  int myCorrect = 0;
  final Set<String> _away = {};
  int? _graceUntil;
  Map<String, Object?>? _end;
  Map<String, Object?>? _settlement;
  bool settled = false;
  final Set<Timer> _timers = {};

  /// The first opponent's points (the opponent of a Quick Battle).
  int get opponentPoints => _points[opponent.uid] ?? 0;

  int get opponentCorrect => _correct[opponent.uid] ?? 0;

  bool get isOver => phase == 'finished' || phase == 'aborted' || phase == 'voided';

  String get _me => _server.me.uid;

  int get _now => _server.now;

  int get _limitMs => _limit ?? _server.questionLimit.inMilliseconds;

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
          ..._server.me.card(),
          'connected': true,
          'score': myPoints,
          'correct': myCorrect,
          'answered': _mine.containsKey(q) && q > 0,
        },
        for (final player in opponents)
          {
            ...player.card(),
            'connected': !_away.contains(player.uid),
            'grace_until': _away.contains(player.uid) ? _graceUntil : null,
            'score': _points[player.uid],
            'correct': _correct[player.uid],
            'answered': _theirs[player.uid]!.containsKey(q) && q > 0,
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
    room?._matchOver(this);
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

    for (final (index, player) in opponents.indexed) {
      final plan = _server.opponentPlan;
      final DemoAnswerPlan? answer;
      if (plan != null && index == 0) {
        answer = number <= plan.length ? plan[number - 1] : null;
      } else {
        final random = _server._random;
        final accuracy = bot ? 0.55 : 0.6;
        // Log-normal around 6 s, never under 1.5 s.
        final gaussian =
            sqrt(-2 * log(1 - random.nextDouble())) * cos(2 * pi * random.nextDouble());
        final ms = (6000 * exp(0.35 * gaussian)).round().clamp(1500, _limitMs - 800);
        answer = DemoAnswerPlan(correct: random.nextDouble() < accuracy, ms: ms);
      }
      if (answer != null) {
        final plan = answer;
        _after(
          Duration(milliseconds: shownAt + plan.ms - _now),
          () => _opponentAnswers(player, number, plan),
        );
      }
    }
    if (_server.opponentDropsAtQ == number && !bot) {
      _after(Duration(milliseconds: shownAt + 2000 - _now), _opponentDrops);
    }
    _after(Duration(milliseconds: endsAt! + 250 - _now), () => _reveal(number));
  }

  void _opponentDrops() {
    if (isOver) return;
    _away.add(opponent.uid);
    _graceUntil = _now + (room == null ? 30000 : 60000);
    _shared('opp.conn', {'uid': opponent.uid, 'state': 'reconnecting', 'grace_until': _graceUntil});
    _after(_server.opponentAwayFor, () {
      if (isOver) return;
      _away.remove(opponent.uid);
      _graceUntil = null;
      _shared('opp.conn', {'uid': opponent.uid, 'state': 'connected', 'grace_until': null});
    });
  }

  void _opponentAnswers(DemoPlayer player, int number, DemoAnswerPlan plan) {
    final theirs = _theirs[player.uid]!;
    if (phase != 'q_open' ||
        q != number ||
        _away.contains(player.uid) ||
        theirs.containsKey(number)) {
      return;
    }
    final question = _questions[number - 1];
    final wrong = question.options.where((o) => o.$1 != question.correctId).toList();
    final opt = plan.correct ? question.correctId : wrong[_server._random.nextInt(wrong.length)].$1;
    theirs[number] = _Pick(opt: opt, ms: plan.ms, status: 'accepted');
    _progress(number);
  }

  void _progress(int number) {
    _shared('q.progress', {
      'q': number,
      'answered': [
        if (_mine[number]?.status == 'accepted') _me,
        for (final player in opponents)
          if (_theirs[player.uid]!.containsKey(number)) player.uid,
      ],
    });
    final everyone =
        _mine[number]?.status == 'accepted' &&
        opponents.every((p) => _theirs[p.uid]!.containsKey(number));
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

  int _pointsFor(bool correct, int ms) {
    if (!correct) return 0;
    final t = ((ms - 1000) / (_limitMs - 1000)).clamp(0.0, 1.0);
    return 100 + (50 * (1 - t)).round();
  }

  /// Every player's pick of question [number]: mine first.
  Map<String, _Pick?> _picks(int number) => {
    _me: _mine[number],
    for (final player in opponents) player.uid: _theirs[player.uid]![number],
  };

  void _reveal(int number) {
    if (isOver || _reveals.containsKey(number) || number != q) return;
    phase = 'q_reveal';
    endsAt = null;
    final question = _questions[number - 1];
    final picks = _picks(number);
    final times = {
      for (final MapEntry(key: uid, value: pick) in picks.entries)
        if (pick?.opt != null) uid: pick!.ms,
    };

    String? speed(String uid) {
      if (bot) return null;
      final mine = times[uid];
      final others = [
        for (final MapEntry(key: other, value: ms) in times.entries)
          if (other != uid) ms,
      ]..sort();
      if (mine == null && others.isEmpty) return null;
      if (mine == null) return 'slow';
      if (others.isEmpty) return 'fast';
      // The opponent in a duel, the median of those who answered in a group.
      final other = others[others.length ~/ 2];
      if (mine < other - 250) return 'fast';
      if (mine > other + 250) return 'slow';
      return 'even';
    }

    final players = <String, Object?>{};
    for (final MapEntry(key: uid, value: pick) in picks.entries) {
      final opt = pick?.opt;
      final right = opt == question.correctId;
      final pts = _pointsFor(right, pick?.ms ?? 0);
      if (uid == _me) {
        myPoints += pts;
        if (right) myCorrect++;
      } else {
        _points[uid] = _points[uid]! + pts;
        if (right) _correct[uid] = _correct[uid]! + 1;
      }
      players[uid] = {
        'opt': opt,
        'correct': right,
        'pts': pts,
        'time_ms': opt == null ? null : pick!.ms,
        'speed': speed(uid),
      };
    }
    final reveal = {
      'q': number,
      'correct': question.correctId,
      'players': players,
      'totals': _totals(),
      'ref': question.source.ref,
      if (isGroup && leaderboard) 'standings': _standings(),
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
    for (final player in opponents)
      player.uid: {'points': _points[player.uid], 'correct': _correct[player.uid]},
  };

  int _pointsOf(String uid) => uid == _me ? myPoints : _points[uid]!;

  int _correctOf(String uid) => uid == _me ? myCorrect : _correct[uid]!;

  /// Total time on correct answers, the last tie-break.
  int _timeOf(String uid) {
    final picks = uid == _me ? _mine : _theirs[uid]!;
    return [
      for (final MapEntry(key: number, value: pick) in picks.entries)
        if (pick.opt == _questions[number - 1].correctId) pick.ms,
    ].fold(0, (sum, ms) => sum + ms);
  }

  /// Places, best first; players level on points, correct answers and time share one.
  List<List<String>> _ranking() {
    final uids = [_me, for (final player in opponents) player.uid];
    int compare(String a, String b) {
      final points = _pointsOf(b).compareTo(_pointsOf(a));
      if (points != 0) return points;
      final correct = _correctOf(b).compareTo(_correctOf(a));
      if (correct != 0) return correct;
      return _timeOf(a).compareTo(_timeOf(b));
    }

    uids.sort(compare);
    final places = <List<String>>[];
    for (final uid in uids) {
      if (places.isNotEmpty && compare(places.last.first, uid) == 0) {
        places.last.add(uid);
      } else {
        places.add([uid]);
      }
    }
    return places;
  }

  List<Map<String, Object?>> _standings() {
    final rows = <Map<String, Object?>>[];
    for (final (index, place) in _ranking().indexed) {
      final rank = index + 1;
      for (final uid in place) {
        final before = _places[uid];
        rows.add({
          'uid': uid,
          'points': _pointsOf(uid),
          'place': rank,
          'change': before == null ? 0 : before - rank,
        });
        _places[uid] = rank;
      }
    }
    return rows;
  }

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

  /// The host ended a group game early, on the current scores.
  void endByHost() => _finish('ended_by_host');

  String _result(List<List<String>> ranking) {
    final top = ranking.first;
    if (!top.contains(_me)) return 'loss';
    return top.length == 1 ? 'win' : 'draw';
  }

  void _finish(String reason, {String? forcedResult}) {
    if (isOver) return;
    _cancelTimers();
    phase = 'finished';
    endsAt = null;
    var ranking = _ranking();
    if (forcedResult == 'loss') {
      ranking = [
        for (final place in ranking)
          if (place.any((uid) => uid != _me))
            [
              for (final uid in place)
                if (uid != _me) uid,
            ],
        [_me],
      ];
    }
    final result = forcedResult ?? _result(ranking);
    _end = {'result': result, 'reason': reason, 'totals': _totals(), 'ranking': ranking};
    _shared('match.end', _end!);
    room?._matchOver(this);
    _after(_server.settleAfter, () {
      _settlement = _settle(result);
      settled = true;
      if (!_server.withholdSettlement) _private('match.settled', {'match_id': id, ..._settlement!});
    });
  }

  Map<String, Object?> _settle(String result) {
    final world = _server.world;
    final win = result == 'win';
    final draw = result == 'draw';
    Map<String, Object?>? rating;
    Map<String, Object?>? rank;
    if (mode == 'rated' && !bot && room == null) {
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
    // Rooms are free: no coins either way.
    final coins = bot || room != null ? 0 : (win ? 10 : (draw && mode == 'casual' ? 5 : 0));
    world.coins += coins;
    final xp = switch (room?.kind) {
      // Group: 20 for a win, 10 for taking part.
      'group' => win ? 20 : 10,
      // Friend duels and the bot: half XP.
      'friend' => (win ? 30 : (draw ? 20 : 10)) ~/ 2,
      _ => (win ? 30 : (draw ? 20 : 10)) ~/ (bot ? 2 : 1),
    };
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
      'coins': room != null ? null : {'delta': coins, 'balance': world.coins, 'capped': false},
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
    final ranking = end?['ranking'];
    int? place;
    if (isGroup && ranking is List) {
      for (final (index, uids) in ranking.indexed) {
        if (uids is List && uids.contains(_me)) place = index + 1;
      }
    }
    return {
      'id': id,
      'kind': kind,
      'subject': subject,
      'chapters': [for (final source in sources) source['name']],
      'played_at': DateTime.fromMillisecondsSinceEpoch(createdAt, isUtc: true).toIso8601String(),
      'result': result,
      'reason': end?['reason'],
      'score': {'me': myPoints, 'best_other': opponents.map((p) => _points[p.uid]!).fold(0, max)},
      'opponents': [for (final player in opponents) player.card()..['id'] = player.uid],
      'rating_delta': (_settlement?['rating'] as Map?)?['delta'],
      'coins_delta': (_settlement?['coins'] as Map?)?['delta'],
      'place': place,
      'status': switch (phase) {
        'aborted' => 'aborted',
        'voided' => 'voided',
        'finished' => settled ? 'settled' : 'settling',
        _ => 'live',
      },
      'totals': _totals(),
      'ranking': ranking,
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
