import 'package:realtime_client/realtime_client.dart' show PlayerAvatar, PlayerCard;

import '../../../core/network/app_failure.dart';
import '../../../core/network/paging.dart';
import '../../battle/data/battle_models.dart' show RatingInfo;
import '../../practice/data/practice_models.dart' show PracticeMode;
import 'profile_models.dart';
import 'profile_repository.dart';

/// Calls of [FakeProfileRepository] that tests can make fail.
enum FakeProfileOp { stats, matches, practice, opponents }

/// In-memory Profile data for tests and the debug "Demo data" mode.
class FakeProfileRepository implements ProfileRepository {
  FakeProfileRepository({
    PlayerStats Function(StatsRange range)? stats,
    List<MatchHistoryItem> matches = const [],
    List<PracticeHistoryItem> practice = const [],
    this.opponentList = const [],
    this.pageSize = 10,
    this.latency = Duration.zero,
  }) : _stats = stats ?? ((_) => const PlayerStats()),
       _matches = [...matches],
       _practice = [...practice];

  /// A few weeks of play.
  factory FakeProfileRepository.seeded({Duration latency = Duration.zero, DateTime? now}) {
    final at = now ?? DateTime.now();
    return FakeProfileRepository(
      stats: (range) => sampleStats(range, now: at),
      matches: sampleMatches(at),
      practice: samplePractice(at),
      opponentList: [
        RecentOpponent(
          user: _riya,
          h2h: const WinDrawLoss(wins: 3, draws: 1, losses: 2),
          relationship: 'none',
          lastPlayedAt: at.subtract(const Duration(hours: 3)),
        ),
      ],
      latency: latency,
    );
  }

  final PlayerStats Function(StatsRange range) _stats;
  final List<MatchHistoryItem> _matches;
  final List<PracticeHistoryItem> _practice;
  List<RecentOpponent> opponentList;
  final int pageSize;

  /// Delay before every response, to see loading states.
  Duration latency;

  /// Calls that fail until removed from the map.
  final Map<FakeProfileOp, AppFailure> failures = {};

  /// Ranges asked for, in order.
  final List<StatsRange> statsCalls = [];

  /// Cursors asked for by `matches`, in order.
  final List<String?> matchCalls = [];

  @override
  Future<PlayerStats> stats(StatsRange range) async {
    statsCalls.add(range);
    await _wait(FakeProfileOp.stats);
    return _stats(range);
  }

  @override
  Future<CursorPage<MatchHistoryItem>> matches({String? cursor}) async {
    matchCalls.add(cursor);
    await _wait(FakeProfileOp.matches);
    return _page(_matches, cursor);
  }

  @override
  Future<CursorPage<PracticeHistoryItem>> practiceSessions({String? cursor}) async {
    await _wait(FakeProfileOp.practice);
    return _page(_practice, cursor);
  }

  @override
  Future<List<RecentOpponent>> opponents({int days = 30}) async {
    await _wait(FakeProfileOp.opponents);
    return opponentList;
  }

  CursorPage<T> _page<T>(List<T> all, String? cursor) {
    final start = cursor == null ? 0 : int.parse(cursor);
    final end = (start + pageSize).clamp(0, all.length);
    return CursorPage(
      List.unmodifiable(all.sublist(start, end)),
      nextCursor: end < all.length ? '$end' : null,
    );
  }

  Future<void> _wait(FakeProfileOp op) async {
    if (latency > Duration.zero) await Future<void>.delayed(latency);
    if (failures[op] case final failure?) throw failure;
  }
}

const _riya = PlayerCard(
  uid: 'demo-riya',
  handle: 'riya_s',
  displayName: 'Riya',
  avatar: PlayerAvatar(tone: 'rose', symbol: 'dna'),
  level: 6,
);

const _kabir = PlayerCard(
  uid: 'demo-kabir',
  handle: 'kabir_k',
  displayName: 'Kabir',
  avatar: PlayerAvatar(tone: 'sky', symbol: 'atom'),
  level: 5,
);

/// Stats with a rating history that has more points the longer the range.
PlayerStats sampleStats(StatsRange range, {required DateTime now}) {
  final days = switch (range) {
    StatsRange.days30 => 30,
    StatsRange.days90 => 90,
    StatsRange.all => 150,
  };
  final points = (days / 5).round();
  return PlayerStats(
    level: const LevelInfo(level: 4, intoLevel: 120, forNext: 250),
    ratings: const [
      ScopeRating(
        scope: 'overall',
        rating: RatingInfo(display: '1523', value: 1523),
        position: 214,
      ),
      ScopeRating(
        scope: 'physics',
        name: 'Physics',
        rating: RatingInfo(display: '1548', value: 1548),
        position: 42,
      ),
      ScopeRating(
        scope: 'chemistry',
        name: 'Chemistry',
        rating: RatingInfo(display: '1498?', value: 1498, provisional: true),
      ),
    ],
    records: const {
      'rated': WinDrawLoss(wins: 12, draws: 2, losses: 9),
      'casual': WinDrawLoss(wins: 3, losses: 2),
      'bot': WinDrawLoss(wins: 4, losses: 1),
    },
    accuracy: 0.68,
    questionsAnswered: 1240,
    currentStreak: 4,
    bestStreak: 11,
    ratingHistory: [
      for (var i = 0; i < points; i++)
        RatingPoint(
          at: now.subtract(Duration(days: days - i * 5)),
          value: 1450 + i * 4 + (i.isEven ? 6 : -3),
        ),
    ],
  );
}

/// Recent games, newest first.
List<MatchHistoryItem> sampleMatches(DateTime now) => [
  MatchHistoryItem(
    id: 'demo-m3',
    kind: 'rated',
    subject: 'physics',
    chapters: const ['Motion in a Straight Line'],
    playedAt: now.subtract(const Duration(hours: 3)),
    result: 'win',
    scoreMe: 820,
    scoreOther: 640,
    opponents: const [_riya],
    ratingDelta: 14,
  ),
  MatchHistoryItem(
    id: 'demo-m2',
    kind: 'casual',
    subject: 'chemistry',
    playedAt: now.subtract(const Duration(days: 1)),
    result: 'aborted',
    reason: 'no_show',
    opponents: const [_kabir],
    coinsDelta: 0,
  ),
  MatchHistoryItem(
    id: 'demo-m1',
    kind: 'group',
    subject: 'physics',
    playedAt: now.subtract(const Duration(days: 2)),
    result: 'loss',
    scoreMe: 510,
    scoreOther: 700,
    opponents: const [_riya, _kabir],
    place: 2,
  ),
];

/// Practice sessions, newest first; the first one can still be continued.
List<PracticeHistoryItem> samplePractice(DateTime now) => [
  PracticeHistoryItem(
    sessionId: 'demo-p2',
    mode: PracticeMode.chapter,
    title: 'Physics · Laws of Motion',
    createdAt: now.subtract(const Duration(hours: 1)),
    answered: 6,
    correct: 4,
  ),
  PracticeHistoryItem(
    sessionId: 'demo-p1',
    mode: PracticeMode.challenge,
    title: 'Self Challenge · Physics',
    createdAt: now.subtract(const Duration(days: 2)),
    finishedAt: now.subtract(const Duration(days: 2)),
    answered: 20,
    correct: 14,
    score: 50,
    maxScore: 80,
  ),
];
