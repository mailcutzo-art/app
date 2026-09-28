import 'package:flutter/foundation.dart';

import '../../../core/auth/user.dart';
import '../../../core/network/json.dart';
import '../../leaderboards/data/leaderboard_models.dart' show PlayerCard;

/// Where a tournament is in its life (`docs/plan.md` Phase 5, "Lifecycle").
enum TournamentStatus {
  scheduled('scheduled'),
  regOpen('reg_open'),
  checkIn('check_in'),
  locked('locked'),
  running('running'),
  finalizing('finalizing'),
  finished('finished'),
  cancelled('cancelled');

  const TournamentStatus(this.wire);

  final String wire;

  /// Unknown values read as [scheduled]: the card still shows, with nothing to press.
  static TournamentStatus parse(Object? value) =>
      values.where((s) => s.wire == value).firstOrNull ?? scheduled;

  /// Rounds are being played (or the last one is being wrapped up).
  bool get isLive => this == running || this == finalizing;

  /// Over, one way or another.
  bool get isOver => this == finished || this == cancelled;

  /// Registration takes new players.
  bool get takesEntries => this == regOpen || this == checkIn;

  /// The Arena filter a tournament in this state is listed under.
  ArenaFilter get filter => switch (this) {
    regOpen || checkIn => ArenaFilter.open,
    scheduled || locked => ArenaFilter.upcoming,
    running || finalizing => ArenaFilter.live,
    finished || cancelled => ArenaFilter.finished,
  };
}

/// The Arena tab's filters: Open = REG_OPEN or CHECK_IN, Upcoming = SCHEDULED or LOCKED,
/// Live = RUNNING, Finished = FINISHED or CANCELLED.
enum ArenaFilter {
  open('open', 'Open'),
  upcoming('upcoming', 'Upcoming'),
  live('live', 'Live'),
  finished('finished', 'Finished');

  const ArenaFilter(this.wire, this.label);

  /// `?status=` of `GET /v1/tournaments`.
  final String wire;
  final String label;

  static ArenaFilter? parse(String? value) => values.where((f) => f.wire == value).firstOrNull;
}

/// Which exam a tournament is for. `any` is only used for the subjects both exams share.
enum TournamentGoal {
  neet('neet', 'NEET'),
  jee('jee', 'JEE'),
  any('any', 'NEET & JEE');

  const TournamentGoal(this.wire, this.label);

  final String wire;
  final String label;

  static TournamentGoal parse(Object? value) =>
      values.where((g) => g.wire == value).firstOrNull ?? any;

  /// Whether a player preparing for [goal] can enter.
  bool admits(Goal? goal) => this == any || goal == null || goal.name == wire;
}

/// The viewer's place in a tournament, on its card (`me`).
@immutable
class TournamentEntry {
  const TournamentEntry({this.registered = false, this.checkedIn = false, this.withdrawn = false});

  factory TournamentEntry.fromJson(Object? json) {
    final r = JsonReader(json, 'tournament me');
    return TournamentEntry(
      registered: r.flag('registered'),
      checkedIn: r.flag('checked_in'),
      withdrawn: r.flag('withdrawn'),
    );
  }

  final bool registered;
  final bool checkedIn;
  final bool withdrawn;

  /// Registered and still in.
  bool get entered => registered && !withdrawn;

  Map<String, Object?> toJson() => {
    'registered': registered,
    'checked_in': checkedIn,
    'withdrawn': withdrawn,
  };

  @override
  bool operator ==(Object other) =>
      other is TournamentEntry &&
      other.registered == registered &&
      other.checkedIn == checkedIn &&
      other.withdrawn == withdrawn;

  @override
  int get hashCode => Object.hash(registered, checkedIn, withdrawn);
}

/// How long before the start check-in opens, and when it closes.
abstract final class CheckInWindow {
  static const opensBefore = Duration(minutes: 15);
  static const closesBefore = Duration(minutes: 2);

  /// Registration closes (the badge shows LOCKED) this long before the start.
  static const locksBefore = Duration(minutes: 5);
}

/// A tournament card (`GET /v1/tournaments`), the shape every list uses.
@immutable
class Tournament {
  const Tournament({
    required this.id,
    required this.title,
    required this.status,
    required this.startsAt,
    required this.rounds,
    required this.capacity,
    this.goal = TournamentGoal.any,
    this.subject,
    this.tone = 'lemon',
    this.regOpensAt,
    this.checkinOpensAt,
    this.endsAtEstimate,
    this.entryFee = 0,
    this.prizePool = 0,
    this.effectivePool,
    this.players = 0,
    this.minPlayers = 8,
    this.me,
  });

  factory Tournament.fromJson(Object? json) {
    final r = JsonReader(json, 'tournament');
    return Tournament(
      id: r.string('id'),
      title: r.string('title'),
      goal: TournamentGoal.parse(r['goal']),
      subject: r.optString('subject'),
      tone: r.optString('tone') ?? 'lemon',
      status: TournamentStatus.parse(r['status']),
      regOpensAt: _optTime(r, 'reg_opens_at'),
      checkinOpensAt: _optTime(r, 'checkin_opens_at'),
      startsAt: r.dateTime('starts_at'),
      endsAtEstimate: _optTime(r, 'ends_at_estimate'),
      rounds: r.integer('rounds'),
      entryFee: r.optInt('entry_fee') ?? 0,
      prizePool: r.optInt('prize_pool') ?? 0,
      effectivePool: r.optInt('effective_pool'),
      players: r.optInt('players') ?? 0,
      minPlayers: r.optInt('min_players') ?? 8,
      capacity: r.integer('capacity'),
      me: r.optObject('me', TournamentEntry.fromJson),
    );
  }

  final String id;
  final String title;
  final TournamentGoal goal;

  /// The subject slug, or null for all subjects.
  final String? subject;

  /// The card's pastel tone name (`sky`, `mint`, …).
  final String tone;
  final TournamentStatus status;
  final DateTime? regOpensAt;
  final DateTime? checkinOpensAt;
  final DateTime startsAt;
  final DateTime? endsAtEstimate;

  /// Rounds configured (fewer are played in a small field).
  final int rounds;

  /// Coins; 0 is free.
  final int entryFee;
  final int prizePool;

  /// The pool paid for the current field: `pool × min(1, players / 32)`.
  final int? effectivePool;
  final int players;
  final int minPlayers;
  final int capacity;

  /// The viewer's entry; null when they never registered.
  final TournamentEntry? me;

  bool get isFree => entryFee == 0;

  bool get isFull => players >= capacity;

  /// Registered and still in.
  bool get entered => me?.entered ?? false;

  bool get checkedIn => entered && (me?.checkedIn ?? false);

  /// Players still missing for the tournament to go ahead ("3 more needed").
  int get needed => (minPlayers - players).clamp(0, minPlayers);

  /// What the prize pool pays right now.
  int get poolNow => effectivePool ?? prizePool;

  /// The pool is smaller than advertised until enough players join.
  bool get poolGrows => poolNow < prizePool;

  DateTime get checkInOpensAt => checkinOpensAt ?? startsAt.subtract(CheckInWindow.opensBefore);

  DateTime get checkInClosesAt => startsAt.subtract(CheckInWindow.closesBefore);

  /// Whether a registered player can check in at [now] (T−15 to T−2 min).
  bool checkInOpen(DateTime now) =>
      (status == TournamentStatus.checkIn || status == TournamentStatus.locked) &&
      !now.isBefore(checkInOpensAt) &&
      now.isBefore(checkInClosesAt);

  Tournament copyWith({
    TournamentStatus? status,
    int? players,
    int? effectivePool,
    DateTime? startsAt,
    TournamentEntry? Function()? me,
  }) => Tournament(
    id: id,
    title: title,
    goal: goal,
    subject: subject,
    tone: tone,
    status: status ?? this.status,
    regOpensAt: regOpensAt,
    checkinOpensAt: startsAt == null ? checkinOpensAt : null,
    startsAt: startsAt ?? this.startsAt,
    endsAtEstimate: startsAt == null ? endsAtEstimate : null,
    rounds: rounds,
    entryFee: entryFee,
    prizePool: prizePool,
    effectivePool: effectivePool ?? this.effectivePool,
    players: players ?? this.players,
    minPlayers: minPlayers,
    capacity: capacity,
    me: me == null ? this.me : me(),
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'goal': goal.wire,
    'subject': subject,
    'tone': tone,
    'status': status.wire,
    'reg_opens_at': regOpensAt?.toUtc().toIso8601String(),
    'checkin_opens_at': checkinOpensAt?.toUtc().toIso8601String(),
    'starts_at': startsAt.toUtc().toIso8601String(),
    'ends_at_estimate': endsAtEstimate?.toUtc().toIso8601String(),
    'rounds': rounds,
    'entry_fee': entryFee,
    'prize_pool': prizePool,
    'effective_pool': effectivePool,
    'players': players,
    'min_players': minPlayers,
    'capacity': capacity,
    'me': me?.toJson(),
  };
}

DateTime? _optTime(JsonReader r, String key) => r.has(key) ? r.dateTime(key) : null;

/// Wins, draws and losses.
@immutable
class TournamentRecord {
  const TournamentRecord({this.wins = 0, this.draws = 0, this.losses = 0});

  factory TournamentRecord.fromJson(Object? json) {
    final r = JsonReader(json, 'record');
    return TournamentRecord(
      wins: r.optInt('wins') ?? 0,
      draws: r.optInt('draws') ?? 0,
      losses: r.optInt('losses') ?? 0,
    );
  }

  static const zero = TournamentRecord();

  final int wins;
  final int draws;
  final int losses;

  int get played => wins + draws + losses;

  /// "2–1–0" (wins, draws, losses), or "2–0" without draws.
  String get display => draws == 0 ? '$wins–$losses' : '$wins–$draws–$losses';

  Map<String, Object?> toJson() => {'wins': wins, 'draws': draws, 'losses': losses};
}

/// "2", "2.5": tournament points, where a draw is worth half.
String formatPoints(num points) {
  final whole = points == points.truncate();
  return whole ? '${points.toInt()}' : points.toStringAsFixed(1);
}

/// The fixed game rules of every tournament round.
@immutable
class TournamentRules {
  const TournamentRules({
    this.questions = 10,
    this.secondsPerQuestion = 15,
    this.rated = true,
    this.readySeconds = 90,
    this.drawPoints = 0.5,
    this.byePoints = 1,
  });

  factory TournamentRules.fromJson(Object? json) {
    final r = JsonReader(json, 'tournament rules');
    return TournamentRules(
      questions: r.optInt('questions') ?? 10,
      secondsPerQuestion: r.optInt('seconds_per_question') ?? 15,
      rated: r.flag('rated', fallback: true),
      readySeconds: r.optInt('ready_s') ?? 90,
      drawPoints: (r['draw_points'] as num?) ?? 0.5,
      byePoints: (r['bye_points'] as num?) ?? 1,
    );
  }

  final int questions;
  final int secondsPerQuestion;
  final bool rated;

  /// How long a player has to join each round's game.
  final int readySeconds;
  final num drawPoints;
  final num byePoints;

  Map<String, Object?> toJson() => {
    'questions': questions,
    'seconds_per_question': secondsPerQuestion,
    'rated': rated,
    'ready_s': readySeconds,
    'draw_points': drawPoints,
    'bye_points': byePoints,
  };
}

/// Where one round is.
enum RoundStatus {
  upcoming('upcoming'),
  pairing('pairing'),
  live('live'),
  done('done');

  const RoundStatus(this.wire);

  final String wire;

  static RoundStatus parse(Object? value) =>
      values.where((s) => s.wire == value).firstOrNull ?? upcoming;
}

/// One round of the schedule.
@immutable
class ScheduledRound {
  const ScheduledRound({required this.round, this.startsAt, this.status = RoundStatus.upcoming});

  factory ScheduledRound.fromJson(Object? json) {
    final r = JsonReader(json, 'round');
    return ScheduledRound(
      round: r.integer('round'),
      startsAt: _optTime(r, 'starts_at'),
      status: RoundStatus.parse(r['status']),
    );
  }

  final int round;

  /// When it starts: exact once paired, an estimate before.
  final DateTime? startsAt;
  final RoundStatus status;

  Map<String, Object?> toJson() => {
    'round': round,
    'starts_at': startsAt?.toUtc().toIso8601String(),
    'status': status.wire,
  };
}

/// A place (or a run of places) and what it pays.
@immutable
class PrizeRow {
  const PrizeRow({required this.from, required this.to, required this.coins});

  factory PrizeRow.fromJson(Object? json) {
    final r = JsonReader(json, 'prize row');
    final from = r.integer('from');
    return PrizeRow(from: from, to: r.optInt('to') ?? from, coins: r.integer('coins'));
  }

  final int from;
  final int to;

  /// Coins for each place in the run.
  final int coins;

  /// "1st", "6th–10th".
  String get places => from == to ? ordinal(from) : '${ordinal(from)}–${ordinal(to)}';

  Map<String, Object?> toJson() => {'from': from, 'to': to, 'coins': coins};
}

/// "1st", "2nd", "23rd", "11th".
String ordinal(int n) {
  final teen = n % 100 >= 11 && n % 100 <= 13;
  final suffix = teen
      ? 'th'
      : switch (n % 10) {
          1 => 'st',
          2 => 'nd',
          3 => 'rd',
          _ => 'th',
        };
  return '$n$suffix';
}

/// Shares of the effective pool by field size (`docs/plan.md` Phase 5, "Prizes"), in percent.
List<({int from, int to, double percent})> prizeShares(int players) {
  if (players < 4) return const [];
  if (players < 8) return const [(from: 1, to: 1, percent: 70), (from: 2, to: 2, percent: 30)];
  if (players < 16) {
    return const [
      (from: 1, to: 1, percent: 50),
      (from: 2, to: 2, percent: 30),
      (from: 3, to: 3, percent: 20),
    ];
  }
  if (players < 32) {
    return const [
      (from: 1, to: 1, percent: 40),
      (from: 2, to: 2, percent: 25),
      (from: 3, to: 3, percent: 15),
      (from: 4, to: 5, percent: 10),
    ];
  }
  if (players < 128) {
    return const [
      (from: 1, to: 1, percent: 30),
      (from: 2, to: 2, percent: 20),
      (from: 3, to: 3, percent: 12),
      (from: 4, to: 4, percent: 8),
      (from: 5, to: 5, percent: 6),
      (from: 6, to: 10, percent: 4.8),
    ];
  }
  return const [
    (from: 1, to: 1, percent: 25),
    (from: 2, to: 2, percent: 15),
    (from: 3, to: 3, percent: 10),
    (from: 4, to: 4, percent: 7),
    (from: 5, to: 5, percent: 5),
    (from: 6, to: 10, percent: 3),
    (from: 11, to: 30, percent: 1.15),
  ];
}

/// `pool × min(1, players / 32)`, floored.
int effectivePoolFor(int pool, int players) => (pool * (players / 32).clamp(0, 1)).floor();

/// The prize table for [players] from a [pool]: amounts floored, the remainder to 1st place.
List<PrizeRow> prizeTableFor(int pool, int players) {
  final effective = effectivePoolFor(pool, players);
  final shares = prizeShares(players);
  if (shares.isEmpty || effective <= 0) return const [];
  final rows = [
    for (final share in shares)
      PrizeRow(from: share.from, to: share.to, coins: (effective * share.percent / 100).floor()),
  ];
  final paid = rows.fold(0, (sum, row) => sum + row.coins * (row.to - row.from + 1));
  final first = rows.first;
  return [PrizeRow(from: 1, to: 1, coins: first.coins + effective - paid), ...rows.skip(1)];
}

/// The number of rounds actually played: min(configured, players − 1, ⌈log₂ players⌉ + 2).
int roundsPlayed(int configured, int players) {
  if (players < 2) return configured;
  var log2 = 0;
  while ((1 << log2) < players) {
    log2++;
  }
  return [configured, players - 1, log2 + 2].reduce((a, b) => a < b ? a : b);
}

/// A game to play (or a bye) in the current round.
@immutable
class Pairing {
  const Pairing({required this.round, this.opponent, this.bye = false, this.matchId, this.readyBy});

  factory Pairing.fromJson(Object? json) {
    final r = JsonReader(json, 'pairing');
    return Pairing(
      round: r.integer('round'),
      opponent: r.optObject('opponent', PlayerCard.fromJson),
      bye: r.flag('bye'),
      matchId: r.optString('match_id'),
      readyBy: _optTime(r, 'ready_by'),
    );
  }

  final int round;
  final PlayerCard? opponent;
  final bool bye;
  final String? matchId;

  /// The game must be joined by then.
  final DateTime? readyBy;

  Map<String, Object?> toJson() => {
    'round': round,
    'opponent': opponent?.toJson(),
    'bye': bye,
    'match_id': matchId,
    'ready_by': readyBy?.toUtc().toIso8601String(),
  };
}

/// The viewer's final result, once the tournament is over.
@immutable
class TournamentFinal {
  const TournamentFinal({
    required this.rank,
    required this.players,
    this.points = 0,
    this.prize = 0,
    this.xp = 0,
  });

  factory TournamentFinal.fromJson(Object? json) {
    final r = JsonReader(json, 'final result');
    return TournamentFinal(
      rank: r.integer('rank'),
      players: r.integer('players'),
      points: (r['points'] as num?) ?? 0,
      prize: r.optInt('prize') ?? 0,
      xp: r.optInt('xp') ?? 0,
    );
  }

  final int rank;
  final int players;
  final num points;

  /// Coins credited.
  final int prize;
  final int xp;

  /// "#3 of 64".
  String get placeLine => '#$rank of $players';

  Map<String, Object?> toJson() => {
    'rank': rank,
    'players': players,
    'points': points,
    'prize': prize,
    'xp': xp,
  };
}

/// The viewer's standing on the detail screen (`me` of `GET /v1/tournaments/{id}`).
@immutable
class TournamentStanding {
  const TournamentStanding({
    this.entry = const TournamentEntry(),
    this.record = TournamentRecord.zero,
    this.points = 0,
    this.rank,
    this.nextPairing,
    this.result,
  });

  factory TournamentStanding.fromJson(Object? json) {
    final r = JsonReader(json, 'tournament me');
    return TournamentStanding(
      entry: TournamentEntry.fromJson(json),
      record: r.optObject('record', TournamentRecord.fromJson) ?? TournamentRecord.zero,
      points: (r['points'] as num?) ?? 0,
      rank: r.optInt('rank'),
      nextPairing: r.optObject('next_pairing', Pairing.fromJson),
      result: r.optObject('final', TournamentFinal.fromJson),
    );
  }

  final TournamentEntry entry;
  final TournamentRecord record;
  final num points;
  final int? rank;
  final Pairing? nextPairing;

  /// Set once the tournament finished.
  final TournamentFinal? result;

  Map<String, Object?> toJson() => {
    ...entry.toJson(),
    'record': record.toJson(),
    'points': points,
    'rank': rank,
    'next_pairing': nextPairing?.toJson(),
    'final': result?.toJson(),
  };
}

/// `GET /v1/tournaments/{id}`: the card plus rules, schedule, prizes and the viewer's standing.
@immutable
class TournamentDetail {
  const TournamentDetail({
    required this.tournament,
    this.description,
    this.rules = const TournamentRules(),
    this.schedule = const [],
    this.prizes = const [],
    this.currentRound,
    this.me,
  });

  factory TournamentDetail.fromJson(Object? json) {
    final r = JsonReader(json, 'tournament detail');
    final card = Tournament.fromJson(json);
    final me = r.optObject('me', TournamentStanding.fromJson);
    return TournamentDetail(
      tournament: card,
      description: r.optString('description'),
      rules: r.optObject('rules', TournamentRules.fromJson) ?? const TournamentRules(),
      schedule: r.optList('schedule', ScheduledRound.fromJson),
      prizes: r.optList('prizes', PrizeRow.fromJson),
      currentRound: r.optInt('current_round'),
      me: me,
    );
  }

  final Tournament tournament;
  final String? description;
  final TournamentRules rules;
  final List<ScheduledRound> schedule;

  /// For the current number of players.
  final List<PrizeRow> prizes;

  /// The round being played (or last played); null before the start.
  final int? currentRound;
  final TournamentStanding? me;

  String get id => tournament.id;

  /// Rounds that will actually be played for the current field.
  int get totalRounds => schedule.isNotEmpty ? schedule.length : tournament.rounds;

  Map<String, Object?> toJson() => {
    ...tournament.toJson(),
    'description': description,
    'rules': rules.toJson(),
    'schedule': [for (final round in schedule) round.toJson()],
    'prizes': [for (final prize in prizes) prize.toJson()],
    'current_round': currentRound,
    'me': me?.toJson(),
  };
}

/// One line of the standings.
@immutable
class StandingRow {
  const StandingRow({
    required this.position,
    required this.user,
    this.points = 0,
    this.wins = 0,
    this.draws = 0,
    this.losses = 0,
    this.buchholzCut1,
    this.buchholz,
    this.sonnebornBerger,
    this.withdrawn = false,
  });

  factory StandingRow.fromJson(Object? json) {
    final r = JsonReader(json, 'standing');
    return StandingRow(
      position: r.integer('position'),
      user: r.object('user', PlayerCard.fromJson),
      points: (r['points'] as num?) ?? 0,
      wins: r.optInt('w') ?? 0,
      draws: r.optInt('d') ?? 0,
      losses: r.optInt('l') ?? 0,
      buchholzCut1: r['bh_c1'] as num?,
      buchholz: r['bh'] as num?,
      sonnebornBerger: r['sb'] as num?,
      withdrawn: r.flag('withdrawn'),
    );
  }

  final int position;
  final PlayerCard user;
  final num points;
  final int wins;
  final int draws;
  final int losses;
  final num? buchholzCut1;
  final num? buchholz;
  final num? sonnebornBerger;
  final bool withdrawn;

  TournamentRecord get record => TournamentRecord(wins: wins, draws: draws, losses: losses);

  Map<String, Object?> toJson() => {
    'position': position,
    'user': user.toJson(),
    'points': points,
    'w': wins,
    'd': draws,
    'l': losses,
    'bh_c1': buchholzCut1,
    'bh': buchholz,
    'sb': sonnebornBerger,
    'withdrawn': withdrawn,
  };
}

/// A page of `GET /v1/tournaments/{id}/standings`, with the viewer's own row.
@immutable
class StandingsPage {
  const StandingsPage({required this.items, this.nextCursor, this.me, this.round});

  factory StandingsPage.fromJson(Object? json) {
    final r = JsonReader(json, 'standings');
    final items = <StandingRow>[];
    for (final raw in r.list('items', (value) => value)) {
      try {
        items.add(StandingRow.fromJson(raw));
      } on FormatException catch (e) {
        debugPrint('Skipping an unreadable standings row: $e');
      }
    }
    return StandingsPage(
      items: List.unmodifiable(items),
      nextCursor: r.optString('next_cursor'),
      me: r.optObject('me', StandingRow.fromJson),
      round: r.optInt('round'),
    );
  }

  final List<StandingRow> items;
  final String? nextCursor;
  final StandingRow? me;

  /// After which round.
  final int? round;
}

/// How one of the viewer's games went.
enum GameResult {
  win('win'),
  draw('draw'),
  loss('loss');

  const GameResult(this.wire);

  final String wire;

  static GameResult? parse(Object? value) => values.where((r) => r.wire == value).firstOrNull;
}

/// One round in "My games".
@immutable
class RoundGame {
  const RoundGame({
    required this.round,
    this.opponent,
    this.bye = false,
    this.result,
    this.points,
    this.matchId,
    this.noShow = false,
  });

  factory RoundGame.fromJson(Object? json) {
    final r = JsonReader(json, 'round game');
    return RoundGame(
      round: r.integer('round'),
      opponent: r.optObject('opponent', PlayerCard.fromJson),
      bye: r.flag('bye'),
      result: GameResult.parse(r['result']),
      points: r['points'] as num?,
      matchId: r.optString('match_id'),
      noShow: r.flag('no_show'),
    );
  }

  final int round;
  final PlayerCard? opponent;
  final bool bye;

  /// Null while the game is on (or not played yet).
  final GameResult? result;

  /// Tournament points earned this round.
  final num? points;
  final String? matchId;

  /// Somebody never joined: a forfeit win, or 0 for a double no-show.
  final bool noShow;

  Map<String, Object?> toJson() => {
    'round': round,
    'opponent': opponent?.toJson(),
    'bye': bye,
    'result': result?.wire,
    'points': points,
    'match_id': matchId,
    'no_show': noShow,
  };
}

/// `GET /v1/tournaments/{id}/me`: the viewer's games by round and the current pairing.
@immutable
class MyGames {
  const MyGames({
    this.rounds = const [],
    this.current,
    this.record = TournamentRecord.zero,
    this.points = 0,
    this.rank,
  });

  factory MyGames.fromJson(Object? json) {
    final r = JsonReader(json, 'my games');
    return MyGames(
      rounds: r.optList('rounds', RoundGame.fromJson),
      current: r.optObject('current', Pairing.fromJson),
      record: r.optObject('record', TournamentRecord.fromJson) ?? TournamentRecord.zero,
      points: (r['points'] as num?) ?? 0,
      rank: r.optInt('rank'),
    );
  }

  final List<RoundGame> rounds;
  final Pairing? current;
  final TournamentRecord record;
  final num points;
  final int? rank;
}

/// A tournament in `GET /v1/me/tournaments`: the card, plus the result once it's over.
@immutable
class MyTournament {
  const MyTournament({required this.tournament, this.finalRank, this.prize, this.xp, this.points});

  factory MyTournament.fromJson(Object? json) {
    final r = JsonReader(json, 'my tournament');
    return MyTournament(
      tournament: Tournament.fromJson(json),
      finalRank: r.optInt('final_rank'),
      prize: r.optInt('prize'),
      xp: r.optInt('xp'),
      points: r['points'] as num?,
    );
  }

  final Tournament tournament;
  final int? finalRank;
  final int? prize;
  final int? xp;
  final num? points;

  /// The final result, when the tournament finished and ranked the viewer.
  TournamentFinal? get result => finalRank == null
      ? null
      : TournamentFinal(
          rank: finalRank!,
          players: tournament.players,
          points: points ?? 0,
          prize: prize ?? 0,
          xp: xp ?? 0,
        );
}

/// `DELETE /v1/tournaments/{id}/register`: what came back.
@immutable
class Withdrawal {
  const Withdrawal({required this.tournament, this.refunded = 0});

  factory Withdrawal.fromJson(Object? json) {
    final r = JsonReader(json, 'withdrawal');
    return Withdrawal(
      tournament: r.object('tournament', Tournament.fromJson),
      refunded: r.optInt('refunded') ?? 0,
    );
  }

  final Tournament tournament;

  /// Coins returned: the whole fee before the start, nothing after.
  final int refunded;
}
