import 'frames.dart';

/// Builds the frames of one 1v1 match on `m:<matchId>`, numbering `seq` like the server's match
/// log. Snapshots carry the current seq; every other shared event takes the next one. Per-player
/// messages (`ans.ack`, `match.settled`) carry no seq.
final class MatchScript {
  MatchScript({
    this.matchId = 'M1',
    this.me = 'u1',
    this.them = 'u2',
    this.total = 7,
    this.t0 = 1790000000000,
  });

  final String matchId;
  final String me;
  final String them;
  final int total;

  /// Server ms when the match was created.
  final int t0;

  /// The last seq emitted on the channel.
  int seq = 0;

  String get channel => 'm:$matchId';

  static const limitMs = 15000;

  /// When question [q] goes live: 3 s countdown, 400 ms lead, then one question every 20 s.
  int shownAt(int q) => t0 + 3400 + (q - 1) * 20000;

  int deadlineAt(int q) => shownAt(q) + limitMs;

  String option(int q, int index) => 'q$q-o$index';

  String correctOption(int q) => option(q, q % 4);

  Map<String, Object?> _next(String type, Map<String, Object?> data) =>
      frame(type, data, channel, ++seq, t0 + seq * 10);

  Map<String, Object?> snapshot({
    required String phase,
    int q = 0,
    int? endsAt,
    Map<String, int> scores = const {},
    Map<String, int> correct = const {},
    Map<String, bool> connected = const {},
    Map<String, int> graceUntil = const {},
    Set<String> answered = const {},
    bool withQuestion = false,
    Map<String, Object?>? reveal,
    List<Map<String, Object?>> mine = const [],
    Map<String, Object?>? end,
    bool settled = false,
  }) => frame(
    'match.snapshot',
    {
      'match_id': matchId,
      'kind': 'quick_rated',
      'phase': phase,
      'ends_at': endsAt,
      'q': q,
      'total': total,
      'limit_ms': limitMs,
      'players': [
        for (final uid in [me, them])
          {
            ...card(uid),
            'connected': connected[uid] ?? true,
            'grace_until': graceUntil[uid],
            'score': scores[uid] ?? 0,
            'correct': correct[uid] ?? 0,
            'answered': answered.contains(uid),
          },
      ],
      'question': withQuestion ? showData(q) : null,
      'reveal': reveal,
      'mine': mine,
      'end': end,
      'settled': settled,
    },
    channel,
    seq,
    t0 + seq * 10,
  );

  Map<String, Object?> phase(String phase, {int q = 0, int? endsAt}) =>
      _next('match.phase', {'phase': phase, 'q': q, 'ends_at': endsAt});

  Map<String, Object?> showData(int q) => {
    'q': q,
    'total': total,
    'stem': 'Question $q?',
    'options': [
      for (var i = 0; i < 4; i++) {'id': option(q, i), 'text': 'Option $i of question $q'},
    ],
    'shown_at': shownAt(q),
    'deadline_at': deadlineAt(q),
    'limit_ms': limitMs,
    'chapter': 'Kinematics',
  };

  Map<String, Object?> show(int q) => _next('q.show', showData(q));

  Map<String, Object?> progress(int q, List<String> answered) =>
      _next('q.progress', {'q': q, 'answered': answered});

  /// `ans.ack` goes to one player only, without a seq. [status] is the verdict; a repeat sends
  /// the first verdict again with [dup].
  Map<String, Object?> ansAck(String ref, int q, String status, {bool dup = false}) =>
      frame('ans.ack', {'ref': ref, 'q': q, 'status': status, 'dup': dup}, channel);

  /// A reveal payload. [picks] maps uid → (option, points, time, speed); a `null` option means no
  /// answer.
  Map<String, Object?> revealData(
    int q, {
    required Map<String, (String?, int, int?, String?)> picks,
    required Map<String, (int, int)> totals,
  }) => {
    'q': q,
    'correct': correctOption(q),
    'players': {
      for (final MapEntry(key: uid, value: (opt, pts, timeMs, speed)) in picks.entries)
        uid: {
          'opt': opt,
          'correct': opt == correctOption(q),
          'pts': pts,
          'time_ms': timeMs,
          'speed': speed,
        },
    },
    'totals': {
      for (final MapEntry(key: uid, value: (points, correct)) in totals.entries)
        uid: {'points': points, 'correct': correct},
    },
    'ref': 'ref-$q',
  };

  Map<String, Object?> reveal(
    int q, {
    required Map<String, (String?, int, int?, String?)> picks,
    required Map<String, (int, int)> totals,
  }) => _next('q.reveal', revealData(q, picks: picks, totals: totals));

  Map<String, Object?> oppConn(String uid, String state, {int? graceUntil}) =>
      _next('opp.conn', {'uid': uid, 'state': state, 'grace_until': graceUntil});

  Map<String, Object?> emote(String uid, String e) => _next('emote', {'uid': uid, 'e': e});

  /// The `match.end` payload, also used as a snapshot's `end`.
  Map<String, Object?> endData({
    required String result,
    String reason = 'normal',
    required Map<String, (int, int)> totals,
    List<List<String>>? ranking,
  }) => {
    'result': result,
    'reason': reason,
    'totals': {
      for (final MapEntry(key: uid, value: (points, correct)) in totals.entries)
        uid: {'points': points, 'correct': correct},
    },
    'ranking':
        ranking ??
        [
          [me],
          [them],
        ],
  };

  Map<String, Object?> end({
    required String result,
    String reason = 'normal',
    required Map<String, (int, int)> totals,
    List<List<String>>? ranking,
  }) =>
      _next('match.end', endData(result: result, reason: reason, totals: totals, ranking: ranking));

  /// `match.settled` goes to one player only, without a seq.
  Map<String, Object?> settled({String? matchId}) => frame('match.settled', {
    'match_id': matchId ?? this.matchId,
    'rating': {'scope': 'physics', 'before': '1502?', 'after': '1518?', 'delta': 16},
    'coins': {'delta': 10, 'balance': 245, 'capped': false},
    'xp': {'delta': 30, 'level': 4, 'into_level': 120, 'for_next': 250, 'level_up': false},
    'resets_at': t0 + 86400000,
    'missions': [
      {'id': 'win-3', 'title': 'Win 3 battles', 'progress': 2, 'target': 3, 'done': false},
    ],
  }, channel);
}
