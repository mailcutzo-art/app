import 'rt_server.dart';

/// A player card as the socket sends it.
Map<String, Object?> playerCard(String uid, String name, {String tone = 'sky'}) => {
  'uid': uid,
  'handle': name.toLowerCase(),
  'display_name': name,
  'avatar': {'tone': tone, 'symbol': 'atom'},
  'level': 5,
  'is_bot': false,
};

/// The test user, `u1`, as the socket shows them.
final meCard = playerCard('u1', 'Aarav', tone: 'lime');
final riyaCard = playerCard('u2', 'Riya', tone: 'rose');
final nehaCard = playerCard('u3', 'Neha', tone: 'lavender');
final kabirCard = playerCard('u4', 'Kabir', tone: 'peach');

/// A lobby member: a card plus `ready`, `connected`, `away` and `role`.
Map<String, Object?> member(
  Map<String, Object?> card, {
  bool ready = false,
  bool connected = true,
  bool away = false,
  bool host = false,
}) => {
  ...card,
  'ready': ready,
  'connected': connected,
  'away': away,
  'role': host ? 'host' : 'member',
};

/// Builds the frames of one room's `r:` channel, numbering `seq` like the server's log.
class RoomFrames {
  RoomFrames({this.roomId = 'R1', this.code = 'K7M2QX', this.kind = 'group'});

  final String roomId;
  final String code;
  final String kind;
  int seq = 0;

  String get ch => 'r:$roomId';

  Map<String, Object?> state({
    String host = 'u1',
    String status = 'lobby',
    List<Map<String, Object?>>? members,
    Map<String, Object?>? settings,
    Map<String, Object?>? rematch,
    String? matchId,
    bool locked = false,
  }) => frame(
    'room.state',
    {
      'room_id': roomId,
      'kind': kind,
      'code': code,
      'host': host,
      'status': status,
      'locked': locked,
      'settings':
          settings ??
          {
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
          },
      'members': members ?? [member(meCard, host: host == 'u1')],
      'rematch': rematch,
      'match_id': ?matchId,
      'capacity': kind == 'friend' ? 2 : 8,
    },
    ch,
    ++seq,
  );

  Map<String, Object?> started(String matchId) =>
      frame('room.started', {'match_id': matchId, 'ch': 'm:$matchId'}, ch, ++seq);

  Map<String, Object?> closed(String reason) =>
      frame('room.closed', {'room_id': roomId, 'reason': reason}, ch, ++seq);

  Map<String, Object?> kicked() => frame('room.kicked', {'room_id': roomId}, ch, ++seq);
}

/// Answers `room.join` with [state] (built fresh each time) and acks every other `room.*`
/// message, like the server does. Returns the messages seen, for assertions.
void serveRoom(TestRealtimeServer server, Map<String, Object?> Function() state) {
  server.onMessage = (socket, message) {
    final type = message['t'];
    if (type == 'room.join') {
      socket.push(state());
    } else if (type is String && type.startsWith('room.')) {
      socket.push(frame('ack', {'ref': message['id']}, 'u'));
    }
  };
}

/// Frames of a group battle on `m:<id>` for [players] (uids, the user first).
class GroupMatchFrames {
  GroupMatchFrames({
    this.matchId = 'g1',
    required this.players,
    this.total = 5,
    this.limitMs = 15000,
  });

  final String matchId;
  final List<Map<String, Object?>> players;
  final int total;
  final int limitMs;
  int seq = 0;

  String get ch => 'm:$matchId';

  String option(int q, int index) => 'q$q-o$index';

  String correct(int q) => option(q, 0);

  Map<String, Object?> showData(int q, {required int shownAt}) => {
    'q': q,
    'total': total,
    'stem': 'Group question $q',
    'options': [
      for (var i = 0; i < 4; i++) {'id': option(q, i), 'text': 'Option ${'ABCD'[i]} of $q'},
    ],
    'shown_at': shownAt,
    'deadline_at': shownAt + limitMs,
    'limit_ms': limitMs,
    'chapter': 'Kinematics',
  };

  /// A snapshot at question [q] (0 before the first) in [phase].
  Map<String, Object?> snapshot({
    String phase = 'ready_wait',
    int q = 0,
    Map<String, int> scores = const {},
    List<Map<String, Object?>>? who,
    Map<String, Object?>? end,
  }) => frame(
    'match.snapshot',
    {
      'match_id': matchId,
      'kind': 'group',
      'phase': phase,
      'ends_at': null,
      'q': q,
      'total': total,
      'limit_ms': limitMs,
      'players': [
        for (final card in who ?? players)
          {
            ...card,
            'connected': true,
            'score': scores[card['uid']] ?? 0,
            'correct': 0,
            'answered': false,
          },
      ],
      'question': phase == 'q_open' ? showData(q, shownAt: serverNow() - 1000) : null,
      'reveal': null,
      'mine': <Object?>[],
      'end': end,
      'settled': false,
    },
    ch,
    seq,
  );

  Map<String, Object?> show(int q) => frame('q.show', showData(q, shownAt: serverNow()), ch, ++seq);

  Map<String, Object?> progress(int q, List<String> answered) =>
      frame('q.progress', {'q': q, 'answered': answered}, ch, ++seq);

  /// A reveal where [points] is each player's running total and [standings] the leaderboard
  /// (`uid`, `place`, `change`).
  Map<String, Object?> reveal(
    int q, {
    required Map<String, int> gained,
    required Map<String, int> points,
    List<(String, int, int)> standings = const [],
  }) => frame(
    'q.reveal',
    {
      'q': q,
      'correct': correct(q),
      'players': {
        for (final MapEntry(key: uid, value: pts) in gained.entries)
          uid: {
            'opt': pts > 0 ? correct(q) : option(q, 1),
            'correct': pts > 0,
            'pts': pts,
            'time_ms': 4000,
            'speed': 'even',
          },
      },
      'totals': {
        for (final MapEntry(key: uid, value: total) in points.entries)
          uid: {'points': total, 'correct': total ~/ 100},
      },
      'standings': [
        for (final (uid, place, change) in standings)
          {'uid': uid, 'points': points[uid] ?? 0, 'place': place, 'change': change},
      ],
    },
    ch,
    ++seq,
  );

  Map<String, Object?> end({
    required String result,
    required List<List<String>> ranking,
    required Map<String, int> points,
    String reason = 'normal',
  }) => frame(
    'match.end',
    {
      'result': result,
      'reason': reason,
      'totals': {
        for (final MapEntry(key: uid, value: total) in points.entries)
          uid: {'points': total, 'correct': total ~/ 100},
      },
      'ranking': ranking,
    },
    ch,
    ++seq,
  );
}
