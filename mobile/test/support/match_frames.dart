import 'rt_server.dart';

/// Builds the frames of one 1v1 match for a [TestRealtimeServer], numbering `seq` like the
/// server's match log. Times are on the test's fake clock.
class MatchFrames {
  MatchFrames({
    this.matchId = 'm1',
    this.me = 'u1',
    this.them = 'riya',
    this.total = 7,
    this.kind = 'quick_rated',
    this.limitMs = 15000,
  });

  final String matchId;
  final String me;
  final String them;
  final int total;
  final String kind;
  final int limitMs;

  int seq = 0;

  String get ch => 'm:$matchId';

  Map<String, Object?> card(String uid) => uid == me
      ? {
          'uid': me,
          'handle': 'aarav',
          'display_name': 'Aarav',
          'avatar': {'tone': 'lime', 'symbol': 'rocket'},
          'level': 4,
          'is_bot': false,
        }
      : {
          'uid': them,
          'handle': 'riya_s',
          'display_name': them == 'bot' ? 'Practice Bot' : 'Riya',
          'avatar': {'tone': 'rose', 'symbol': 'dna'},
          'level': 6,
          'is_bot': them == 'bot',
        };

  Map<String, Object?> _next(String type, Map<String, Object?> data) =>
      frame(type, data, ch, ++seq);

  String option(int q, int index) => 'q$q-o$index';

  String correct(int q) => option(q, q % 4);

  String wrong(int q) => option(q, (q + 1) % 4);

  /// `mm.found` on `u`.
  Map<String, Object?> found({String mode = 'rated', bool bot = false}) => frame('mm.found', {
    'match_id': matchId,
    'ch': ch,
    'mode': mode,
    'opponent': {
      ...card(them),
      if (!bot) 'rating': {'display': '1548', 'value': 1548, 'provisional': false},
      if (!bot) 'record': {'wins': 3, 'losses': 1, 'draws': 0},
    },
    'sources': [
      {'chapter': 'kinematics', 'name': 'Kinematics', 'count': 4},
      {'chapter': 'laws-of-motion', 'name': 'Laws of Motion', 'count': 3},
    ],
    'bot': bot,
  }, 'u');

  Map<String, Object?> showData(int q, {required int shownAt}) => {
    'q': q,
    'total': total,
    'stem': 'Question $q: how far does a car go?',
    'options': [
      for (var i = 0; i < 4; i++) {'id': option(q, i), 'text': 'Answer ${'ABCD'[i]} of $q'},
    ],
    'shown_at': shownAt,
    'deadline_at': shownAt + limitMs,
    'limit_ms': limitMs,
    'chapter': 'Kinematics',
  };

  Map<String, Object?> snapshot({
    required String phase,
    int q = 0,
    int? endsAt,
    Map<String, int> scores = const {},
    Set<String> answered = const {},
    Map<String, Object?>? question,
    Map<String, Object?>? reveal,
    List<Map<String, Object?>> mine = const [],
    Map<String, Object?>? end,
    bool settled = false,
    bool themConnected = true,
    int? graceUntil,
  }) => frame(
    'match.snapshot',
    {
      'match_id': matchId,
      'kind': kind,
      'phase': phase,
      'ends_at': endsAt,
      'q': q,
      'total': total,
      'limit_ms': limitMs,
      'players': [
        for (final uid in [me, them])
          {
            ...card(uid),
            'connected': uid == them ? themConnected : true,
            'grace_until': uid == them ? graceUntil : null,
            'score': scores[uid] ?? 0,
            'correct': 0,
            'answered': answered.contains(uid),
          },
      ],
      'question': question,
      'reveal': reveal,
      'mine': mine,
      'end': end,
      'settled': settled,
    },
    ch,
    seq,
  );

  Map<String, Object?> phase(String phase, {int q = 0, int? endsAt}) =>
      _next('match.phase', {'phase': phase, 'q': q, 'ends_at': endsAt});

  Map<String, Object?> show(int q, {required int shownAt}) =>
      _next('q.show', showData(q, shownAt: shownAt));

  Map<String, Object?> progress(int q, List<String> answered) =>
      _next('q.progress', {'q': q, 'answered': answered});

  Map<String, Object?> ansAck(String ref, int q, {String status = 'accepted', bool dup = false}) =>
      frame('ans.ack', {'ref': ref, 'q': q, 'status': status, 'dup': dup}, ch);

  Map<String, Object?> revealData(
    int q, {
    String? myPick,
    String? theirPick,
    int myMs = 4000,
    int theirMs = 5200,
    required (int, int) myTotals,
    required (int, int) theirTotals,
    bool bot = false,
  }) {
    String? speed(String? pick, int ms, String? other, int otherMs) {
      if (bot) return null;
      if (pick == null) return other == null ? null : 'slow';
      if (other == null) return 'fast';
      if (ms < otherMs - 250) return 'fast';
      if (ms > otherMs + 250) return 'slow';
      return 'even';
    }

    int points(String? pick, int ms) =>
        pick == correct(q) ? 100 + (50 * (1 - ((ms - 1000) / (limitMs - 1000)))).round() : 0;
    return {
      'q': q,
      'correct': correct(q),
      'players': {
        me: {
          'opt': myPick,
          'correct': myPick == correct(q),
          'pts': points(myPick, myMs),
          'time_ms': myPick == null ? null : myMs,
          'speed': speed(myPick, myMs, theirPick, theirMs),
        },
        them: {
          'opt': theirPick,
          'correct': theirPick == correct(q),
          'pts': points(theirPick, theirMs),
          'time_ms': theirPick == null ? null : theirMs,
          'speed': speed(theirPick, theirMs, myPick, myMs),
        },
      },
      'totals': {
        me: {'points': myTotals.$1, 'correct': myTotals.$2},
        them: {'points': theirTotals.$1, 'correct': theirTotals.$2},
      },
      'ref': 'phy-kin-00$q',
    };
  }

  Map<String, Object?> reveal(
    int q, {
    String? myPick,
    String? theirPick,
    int myMs = 4000,
    int theirMs = 5200,
    required (int, int) myTotals,
    required (int, int) theirTotals,
    bool bot = false,
  }) => _next(
    'q.reveal',
    revealData(
      q,
      myPick: myPick,
      theirPick: theirPick,
      myMs: myMs,
      theirMs: theirMs,
      myTotals: myTotals,
      theirTotals: theirTotals,
      bot: bot,
    ),
  );

  Map<String, Object?> oppConn(String state, {int? graceUntil}) =>
      _next('opp.conn', {'uid': them, 'state': state, 'grace_until': graceUntil});

  Map<String, Object?> emote(String uid, String e) => _next('emote', {'uid': uid, 'e': e});

  Map<String, Object?> endData({
    required String result,
    String reason = 'normal',
    (int, int) myTotals = (0, 0),
    (int, int) theirTotals = (0, 0),
  }) => {
    'result': result,
    'reason': reason,
    'totals': {
      me: {'points': myTotals.$1, 'correct': myTotals.$2},
      them: {'points': theirTotals.$1, 'correct': theirTotals.$2},
    },
    'ranking': result == 'loss'
        ? [
            [them],
            [me],
          ]
        : [
            [me],
            [them],
          ],
  };

  Map<String, Object?> end({
    required String result,
    String reason = 'normal',
    (int, int) myTotals = (0, 0),
    (int, int) theirTotals = (0, 0),
  }) => _next(
    'match.end',
    endData(result: result, reason: reason, myTotals: myTotals, theirTotals: theirTotals),
  );

  /// The settlement of a rated win: +16, #47 → #42, 10 coins, 30 XP.
  Map<String, Object?> settlementData({bool levelUp = false, bool rated = true}) => {
    'rating': rated ? {'scope': 'physics', 'before': '1502?', 'after': '1518?', 'delta': 16} : null,
    'rank': rated ? {'board': 'rating:physics', 'before': 47, 'after': 42} : null,
    'coins': {'delta': rated ? 10 : 0, 'balance': 255, 'capped': false},
    'xp': {
      'delta': 30,
      'level': levelUp ? 5 : 4,
      'into_level': levelUp ? 10 : 150,
      'for_next': levelUp ? 300 : 250,
      'level_up': levelUp,
      'capped': false,
    },
    'resets_at': serverNow() + 3600000,
    'missions': [
      {'id': 'play-3', 'title': 'Play 3 battles', 'progress': 1, 'target': 3, 'done': false},
    ],
    'streak': {'days': 5, 'extended': true},
    'achievements': [
      {'id': 'first-win', 'title': 'First win'},
    ],
    'tip': {
      'message': 'You were slower on 4 of 7. Try a timed set in Kinematics.',
      'action': 'timed_practice',
      'params': {'subject': 'physics', 'chapter': 'kinematics'},
    },
  };

  Map<String, Object?> settled({bool levelUp = false, bool rated = true}) => frame(
    'match.settled',
    {'match_id': matchId, ...settlementData(levelUp: levelUp, rated: rated)},
    ch,
  );

  Map<String, Object?> rematch(String state, {required String by, String? reason}) =>
      _next('rematch.status', {'match_id': matchId, 'state': state, 'by': by, 'reason': reason});
}
