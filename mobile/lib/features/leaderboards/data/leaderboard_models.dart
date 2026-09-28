import 'package:flutter/foundation.dart';

import '../../../core/auth/user.dart';
import '../../../core/network/json.dart';

/// Another player as boards show them (`docs/api-play.md` "user card").
@immutable
class PlayerCard {
  const PlayerCard({
    required this.id,
    required this.displayName,
    this.handle,
    this.avatar = Avatar.fallback,
    this.level,
  });

  factory PlayerCard.fromJson(Object? json) {
    final r = JsonReader(json, 'user card');
    final handle = r.optString('handle');
    final name = r.optString('display_name');
    return PlayerCard(
      id: r.string('id'),
      handle: handle,
      // Non-friends may be shown with little more than a handle.
      displayName: name == null || name.isEmpty ? (handle ?? 'Player') : name,
      avatar: Avatar.parse(r['avatar']),
      level: r.optInt('level'),
    );
  }

  final String id;
  final String? handle;
  final String displayName;
  final Avatar avatar;
  final int? level;

  Map<String, Object?> toJson() => {
    'id': id,
    'handle': handle,
    'display_name': displayName,
    'avatar': avatar.toJson(),
    'level': level,
  };
}

/// One ranked line of a board.
@immutable
class BoardRow {
  const BoardRow({
    required this.position,
    required this.user,
    required this.value,
    required this.valueDisplay,
    this.change1d,
  });

  factory BoardRow.fromJson(Object? json) {
    final r = JsonReader(json, 'leaderboard row');
    final value = r.integer('value');
    return BoardRow(
      position: r.integer('position'),
      user: r.object('user', PlayerCard.fromJson),
      value: value,
      valueDisplay: r.optString('value_display') ?? '$value',
      change1d: r.optInt('change_1d'),
    );
  }

  final int position;
  final PlayerCard user;
  final int value;
  final String valueDisplay;

  /// Places gained (positive) or lost since yesterday's snapshot. Null when
  /// there was no snapshot to compare with (new on the board).
  final int? change1d;

  Map<String, Object?> toJson() => {
    'position': position,
    'user': user.toJson(),
    'value': value,
    'value_display': valueDisplay,
    'change_1d': change1d,
  };
}

/// The viewer's standing on a hub card: a position, or how many rated games
/// are still needed to appear.
@immutable
class BoardStanding {
  const BoardStanding({this.position, this.value, this.change1d, this.gamesToRank});

  factory BoardStanding.fromJson(Object? json) {
    final r = JsonReader(json, 'board standing');
    return BoardStanding(
      position: r.optInt('position'),
      value: r.optInt('value'),
      change1d: r.optInt('change_1d'),
      gamesToRank: r.optInt('games_to_rank'),
    );
  }

  final int? position;
  final int? value;
  final int? change1d;
  final int? gamesToRank;

  bool get ranked => position != null;
}

/// What kind of board an id names (`docs/api-play.md` boards table).
enum BoardFamily {
  weeklyXp,
  weeklySubject,
  rating,
  friendsWeekly,
  friendsRating,
  hallOfFame,
  other;

  static BoardFamily of(String board) {
    final id = board.endsWith(':last') ? board.substring(0, board.length - 5) : board;
    if (id == 'weekly_xp') return weeklyXp;
    if (id.startsWith('weekly:')) return weeklySubject;
    if (id.startsWith('rating:')) return rating;
    if (id == 'friends:weekly_xp') return friendsWeekly;
    if (id == 'friends:rating') return friendsRating;
    if (id.startsWith('hall_of_fame:')) return hallOfFame;
    return other;
  }

  /// Boards that reset every Monday and show a countdown.
  bool get weekly => this == weeklyXp || this == weeklySubject || this == friendsWeekly;

  /// Boards that need settled ratings (10 rated games) to appear on.
  bool get rated => this == rating || this == friendsRating;
}

/// The subject a board is about (`rating:physics` → `physics`), or null for
/// `overall`, XP and friends boards.
String? boardSubject(String board) {
  final parts = board.split(':');
  if (parts.length < 2) return null;
  final family = BoardFamily.of(board);
  if (family != BoardFamily.rating &&
      family != BoardFamily.weeklySubject &&
      family != BoardFamily.hallOfFame) {
    return null;
  }
  final subject = parts[1];
  return subject == 'overall' ? null : subject;
}

/// One card of the hub.
@immutable
class BoardSummary {
  const BoardSummary({required this.board, required this.title, this.endsAt, this.leader, this.me});

  factory BoardSummary.fromJson(Object? json) {
    final r = JsonReader(json, 'leaderboard card');
    final ends = r.optString('ends_at');
    return BoardSummary(
      board: r.string('board'),
      title: r.string('title'),
      endsAt: ends == null ? null : DateTime.tryParse(ends),
      leader: r.optObject('leader', BoardRow.fromJson),
      me: r.optObject('me', BoardStanding.fromJson),
    );
  }

  final String board;
  final String title;

  /// When a weekly board resets.
  final DateTime? endsAt;
  final BoardRow? leader;
  final BoardStanding? me;

  BoardFamily get family => BoardFamily.of(board);
  String? get subject => boardSubject(board);
}

/// `GET /v1/leaderboards?goal=`.
@immutable
class LeaderboardHub {
  const LeaderboardHub({required this.boards, this.lastWeek = const []});

  /// Cards that can't be read are skipped rather than failing the hub.
  factory LeaderboardHub.fromJson(Object? json) {
    final r = JsonReader(json, 'leaderboards');
    if (r['boards'] is! List) throw const FormatException('leaderboards: "boards" must be a list');
    return LeaderboardHub(
      boards: _lenientList(r['boards'], BoardSummary.fromJson),
      lastWeek: _lenientList(r['last_week'], BoardRow.fromJson),
    );
  }

  final List<BoardSummary> boards;

  /// The top 3 of last week's weekly XP board.
  final List<BoardRow> lastWeek;
}

/// One page of `GET /v1/leaderboards/{board}`.
@immutable
class BoardPage {
  const BoardPage({
    required this.board,
    required this.title,
    required this.items,
    this.period,
    this.nextCursor,
    this.me,
    this.aroundMe = const [],
    this.gamesToRank,
    this.players,
    this.endsAt,
  });

  factory BoardPage.fromJson(Object? json) {
    final r = JsonReader(json, 'leaderboard');
    final notRanked = r['not_ranked'];
    final ends = r.optString('ends_at');
    return BoardPage(
      board: r.string('board'),
      title: r.string('title'),
      period: r.optString('period'),
      items: r.list('items', BoardRow.fromJson),
      nextCursor: r.optString('next_cursor'),
      me: r.optObject('me', BoardRow.fromJson),
      aroundMe: _lenientList(r['around_me'], BoardRow.fromJson),
      gamesToRank: notRanked is Map
          ? JsonReader(notRanked, 'not_ranked').optInt('games_to_rank')
          : null,
      players: r.optInt('players'),
      endsAt: ends == null ? null : DateTime.tryParse(ends),
    );
  }

  final String board;
  final String title;
  final String? period;
  final List<BoardRow> items;
  final String? nextCursor;

  /// The viewer's own row, or null when they aren't on the board.
  final BoardRow? me;

  /// Up to 10 rows above and 10 below the viewer.
  final List<BoardRow> aroundMe;

  /// Rated games still needed before the viewer appears (`not_ranked`).
  final int? gamesToRank;

  /// How many players the board holds under this filter, when the server says.
  final int? players;

  /// When a weekly board resets, when the server says.
  final DateTime? endsAt;
}

List<T> _lenientList<T>(Object? value, T Function(Object? json) parse) {
  if (value is! List) return List<T>.unmodifiable(const []);
  final parsed = <T>[];
  for (final item in value) {
    try {
      parsed.add(parse(item));
    } on FormatException catch (e) {
      debugPrint('Skipping unreadable leaderboard entry: $e');
    }
  }
  return List.unmodifiable(parsed);
}

/// The exam filter of every board: the viewer's own exam, or All India.
enum ExamScope {
  neet('NEET'),
  jee('JEE'),
  allIndia('All India');

  const ExamScope(this.label);

  final String label;

  /// The `goal` query parameter; null for everyone.
  Goal? get goal => switch (this) {
    neet => Goal.neet,
    jee => Goal.jee,
    allIndia => null,
  };

  static ExamScope of(Goal? goal) => switch (goal) {
    Goal.neet => neet,
    Goal.jee => jee,
    null => allIndia,
  };

  /// NEET views never show Maths, and JEE views never show Biology.
  bool shows(String? subject) => switch ((this, subject)) {
    (neet, 'maths') => false,
    (jee, 'biology') => false,
    _ => true,
  };
}
