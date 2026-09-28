import 'dart:math';

import '../../../core/auth/user.dart';
import '../../../core/network/app_failure.dart';
import 'leaderboard_models.dart';
import 'leaderboard_repository.dart';

/// Calls of [FakeLeaderboardRepository] that tests can make fail.
enum FakeLeaderboardOp { hub, board }

/// A player on a [FakeBoard], with the exam they prepare for.
class FakeEntry {
  const FakeEntry(this.player, this.value, {this.goal, this.change1d});

  final PlayerCard player;
  final int value;
  final Goal? goal;
  final int? change1d;
}

/// One board of the fake server. Rows are ranked from [entries] on every
/// request, so the exam filter, paging and "around me" follow the contract.
class FakeBoard {
  FakeBoard({
    required this.title,
    required this.entries,
    this.endsAt,
    this.gamesToRank,
    this.filtered = true,
    this.valueSuffix = '',
  });

  final String title;
  final List<FakeEntry> entries;
  final DateTime? endsAt;

  /// Set when the viewer isn't on the board yet: rated games still needed.
  int? gamesToRank;

  /// Friends boards ignore the exam filter.
  final bool filtered;

  /// Appended to `value_display`, e.g. " XP".
  final String valueSuffix;
}

/// In-memory stand-in for the leaderboards API. Used by tests and by the
/// debug "Demo data" switch.
class FakeLeaderboardRepository implements LeaderboardRepository {
  FakeLeaderboardRepository({
    required this.meId,
    required this.boards,
    this.lastWeek = const [],
    this.latency = Duration.zero,
  });

  /// Sample boards around [me]: a busy weekly board, subject boards, an
  /// overall rating the viewer isn't on yet, and friends.
  factory FakeLeaderboardRepository.seeded({
    Me? me,
    Duration latency = Duration.zero,
    DateTime? now,
  }) {
    final random = Random(39);
    final viewer = PlayerCard(
      id: me?.id ?? 'me',
      handle: me?.handle ?? 'you',
      displayName: me?.displayName ?? 'You',
      avatar: me?.avatar ?? Avatar.fallback,
      level: 4,
    );
    final players = [
      for (var i = 0; i < 160; i++)
        (
          PlayerCard(
            id: 'p$i',
            handle: '${_names[i % _names.length].toLowerCase()}_${10 + i}',
            displayName: _names[i % _names.length],
            avatar: Avatar(
              tone: Avatar.tones[i % Avatar.tones.length],
              symbol: Avatar.symbols.keys.elementAt(i % Avatar.symbols.length),
            ),
            level: 2 + random.nextInt(20),
          ),
          i.isEven ? Goal.neet : Goal.jee,
        ),
    ];
    final viewerGoal = me?.goal ?? Goal.neet;
    final endsAt = _nextMondayIst(now ?? DateTime.now());

    List<FakeEntry> board(int count, int top, {int? myValue, bool Function(Goal)? who}) => [
      for (final (i, (player, goal)) in players.indexed.take(count))
        if (who == null || who(goal))
          FakeEntry(
            player,
            max(1, top - i * (top ~/ count) - random.nextInt(8)),
            goal: goal,
            change1d: random.nextInt(9) - 3,
          ),
      if (myValue != null) FakeEntry(viewer, myValue, goal: viewerGoal, change1d: 25),
    ];

    return FakeLeaderboardRepository(
      meId: viewer.id,
      latency: latency,
      lastWeek: [
        for (final (i, (player, _)) in players.indexed.skip(20).take(3))
          BoardRow(
            position: i + 1,
            user: player,
            value: 2400 - i * 180,
            valueDisplay: '${2400 - i * 180} XP',
          ),
      ],
      boards: {
        'weekly_xp': FakeBoard(
          title: 'This week',
          endsAt: endsAt,
          entries: board(150, 2200, myValue: 140),
          valueSuffix: ' XP',
        ),
        'weekly:physics': FakeBoard(
          title: 'Physics this week',
          endsAt: endsAt,
          entries: board(60, 420, myValue: 36),
          valueSuffix: ' pts',
        ),
        'weekly:chemistry': FakeBoard(
          title: 'Chemistry this week',
          endsAt: endsAt,
          entries: board(12, 180),
          valueSuffix: ' pts',
          gamesToRank: 1,
        ),
        'weekly:biology': FakeBoard(
          title: 'Biology this week',
          endsAt: endsAt,
          entries: board(30, 260, who: (g) => g == Goal.neet),
          valueSuffix: ' pts',
          gamesToRank: 1,
        ),
        'weekly:maths': FakeBoard(
          title: 'Maths this week',
          endsAt: endsAt,
          entries: board(30, 260, who: (g) => g == Goal.jee),
          valueSuffix: ' pts',
          gamesToRank: 1,
        ),
        'rating:overall': FakeBoard(
          title: 'Overall rating',
          entries: board(120, 2150),
          gamesToRank: 7,
        ),
        'rating:physics': FakeBoard(
          title: 'Physics rating',
          entries: board(90, 2050, myValue: 1523),
        ),
        'friends:weekly_xp': FakeBoard(
          title: 'Friends this week',
          endsAt: endsAt,
          filtered: false,
          entries: [
            FakeEntry(players[3].$1, 310, change1d: 0),
            FakeEntry(viewer, 140, change1d: 1),
            FakeEntry(players[8].$1, 90, change1d: -1),
          ],
          valueSuffix: ' XP',
        ),
      },
    );
  }

  final String meId;

  /// Boards by id, in hub order.
  final Map<String, FakeBoard> boards;
  List<BoardRow> lastWeek;

  /// Delay before every response, to see loading states.
  Duration latency;

  /// Calls that fail until removed from the map.
  final Map<FakeLeaderboardOp, AppFailure> failures = {};

  /// Every call: `hub:<goal>` or `<board>:<goal>:<cursor>`.
  final List<String> calls = [];

  static const pageSize = 50;
  static const topRows = 100;

  @override
  Future<LeaderboardHub> hub({Goal? goal}) async {
    calls.add('hub:${goal?.name}');
    await _wait(FakeLeaderboardOp.hub);
    final scope = ExamScope.of(goal);
    return LeaderboardHub(
      boards: [
        for (final MapEntry(key: id, value: board) in boards.entries)
          if (scope.shows(boardSubject(id))) ?_summary(id, board, goal),
      ],
      lastWeek: lastWeek,
    );
  }

  @override
  Future<BoardPage> board(String board, {Goal? goal, String? cursor, int? limit}) async {
    calls.add('$board:${goal?.name}:$cursor');
    await _wait(FakeLeaderboardOp.board);
    final fake = boards[board];
    if (fake == null || !ExamScope.of(goal).shows(boardSubject(board))) {
      throw const NotFoundFailure('This board isn\'t available.', code: 'NOT_FOUND');
    }
    final rows = _ranked(fake, goal);
    final start = int.tryParse(cursor ?? '') ?? 0;
    final size = min(limit ?? pageSize, pageSize);
    final end = min(min(start + size, rows.length), topRows);
    final mine = rows.indexWhere((row) => row.user.id == meId);
    return BoardPage(
      board: board,
      title: fake.title,
      period: fake.endsAt == null ? null : 'week',
      items: start >= end ? const [] : rows.sublist(start, end),
      nextCursor: end < min(rows.length, topRows) ? '$end' : null,
      me: mine == -1 ? null : rows[mine],
      aroundMe: mine == -1
          ? const []
          : rows.sublist(max(0, mine - 10), min(rows.length, mine + 11)),
      gamesToRank: mine == -1 ? fake.gamesToRank : null,
      players: rows.length,
      endsAt: fake.endsAt,
    );
  }

  BoardSummary? _summary(String id, FakeBoard board, Goal? goal) {
    final rows = _ranked(board, goal);
    final subject = boardSubject(id);
    // Empty subject boards are hidden.
    if (rows.isEmpty && subject != null) return null;
    final mine = rows.where((row) => row.user.id == meId).firstOrNull;
    return BoardSummary(
      board: id,
      title: board.title,
      endsAt: board.endsAt,
      leader: rows.firstOrNull,
      me: mine != null
          ? BoardStanding(position: mine.position, value: mine.value, change1d: mine.change1d)
          : BoardStanding(gamesToRank: board.gamesToRank),
    );
  }

  List<BoardRow> _ranked(FakeBoard board, Goal? goal) {
    final entries = [
      for (final entry in board.entries)
        if (!board.filtered || goal == null || entry.goal == null || entry.goal == goal) entry,
    ]..sort((a, b) => b.value.compareTo(a.value));
    return [
      for (final (i, entry) in entries.indexed)
        BoardRow(
          position: i + 1,
          user: entry.player,
          value: entry.value,
          valueDisplay: '${entry.value}${board.valueSuffix}',
          change1d: entry.change1d,
        ),
    ];
  }

  Future<void> _wait(FakeLeaderboardOp op) async {
    if (latency > Duration.zero) await Future<void>.delayed(latency);
    if (failures[op] case final failure?) throw failure;
  }

  /// Weekly boards reset on Monday 00:00 IST (Sunday 18:30 UTC).
  static DateTime _nextMondayIst(DateTime now) {
    final ist = now.toUtc().add(const Duration(hours: 5, minutes: 30));
    final days = DateTime.daysPerWeek - (ist.weekday - DateTime.monday);
    final monday = DateTime.utc(ist.year, ist.month, ist.day + days);
    return monday.subtract(const Duration(hours: 5, minutes: 30));
  }

  static const _names = [
    'Riya',
    'Arjun',
    'Ananya',
    'Kabir',
    'Meera',
    'Vivaan',
    'Diya',
    'Ishaan',
    'Saanvi',
    'Aditya',
    'Priya',
    'Rohan',
    'Kavya',
    'Aryan',
    'Nisha',
    'Dev',
  ];
}
