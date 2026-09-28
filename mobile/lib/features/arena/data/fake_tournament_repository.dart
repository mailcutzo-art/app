import 'dart:math';

import 'package:clock/clock.dart';

import '../../../core/auth/user.dart';
import '../../../core/network/app_failure.dart';
import '../../../core/network/paging.dart';
import '../../leaderboards/data/leaderboard_models.dart' show PlayerCard;
import 'tournament_models.dart';
import 'tournament_repository.dart';

/// Calls of [FakeTournamentRepository] that tests can make fail.
enum FakeArenaOp { list, mine, detail, register, withdraw, checkIn, standings, myGames }

/// One player's line in a [FakeTournament]'s standings.
class FakeStanding {
  FakeStanding(
    this.user, {
    this.points = 0,
    this.wins = 0,
    this.draws = 0,
    this.losses = 0,
    this.buchholz = 0,
    this.withdrawn = false,
  });

  final PlayerCard user;
  num points;
  int wins;
  int draws;
  int losses;
  num buchholz;
  bool withdrawn;

  void add(GameResult result, {num drawPoints = 0.5}) {
    switch (result) {
      case GameResult.win:
        wins++;
        points += 1;
      case GameResult.draw:
        draws++;
        points += drawPoints;
      case GameResult.loss:
        losses++;
    }
  }
}

/// One tournament of the fake server: its card, and (once it runs) standings and the viewer's
/// games. The demo's live run changes these as rounds are played.
class FakeTournament {
  FakeTournament({
    required this.card,
    this.description,
    List<FakeStanding>? field,
    List<RoundGame>? myRounds,
    this.current,
    this.currentRound,
    this.result,
    this.roundStatus = RoundStatus.upcoming,
  }) : field = field ?? [],
       myRounds = myRounds ?? [];

  Tournament card;
  final String? description;

  /// Everyone who played (or plays), the viewer included once registered and started.
  final List<FakeStanding> field;
  final List<RoundGame> myRounds;
  Pairing? current;
  int? currentRound;
  RoundStatus roundStatus;
  TournamentFinal? result;

  String get id => card.id;

  /// Rounds for the current field.
  int get totalRounds => card.status.isLive || card.status.isOver
      ? roundsPlayed(card.rounds, max(card.players, 2))
      : card.rounds;

  /// Standings, best first: points, then Buchholz, then name (a stand-in for the later
  /// tie-breaks).
  List<FakeStanding> get ranked {
    final rows = [...field]
      ..sort((a, b) {
        final byPoints = b.points.compareTo(a.points);
        if (byPoints != 0) return byPoints;
        final byBuchholz = b.buchholz.compareTo(a.buchholz);
        if (byBuchholz != 0) return byBuchholz;
        return a.user.displayName.compareTo(b.user.displayName);
      });
    return rows;
  }

  List<StandingRow> standingRows() => [
    for (final (i, s) in ranked.indexed)
      StandingRow(
        position: i + 1,
        user: s.user,
        points: s.points,
        wins: s.wins,
        draws: s.draws,
        losses: s.losses,
        buchholzCut1: s.buchholz,
        buchholz: s.buchholz,
        sonnebornBerger: s.points,
        withdrawn: s.withdrawn,
      ),
  ];
}

/// In-memory stand-in for the tournaments API, for tests and the debug "Demo data" mode. The
/// rules follow the contract: the fee is held at registration (and returned on a withdraw
/// before the start), check-in is only open from 15 to 2 minutes before the start, and every
/// error code the server can answer is reproduced.
class FakeTournamentRepository implements TournamentRepository {
  FakeTournamentRepository({
    required this.me,
    List<FakeTournament> tournaments = const [],
    this.goal = Goal.neet,
    this.coins = 245,
    this.pageSize = 20,
    this.latency = Duration.zero,
    DateTime Function()? now,
  }) : _tournaments = [...tournaments],
       _now = now ?? clock.now;

  /// A schedule with a tournament in every state around [now], for a NEET player.
  factory FakeTournamentRepository.seeded({
    PlayerCard? me,
    Duration latency = Duration.zero,
    DateTime Function()? now,
  }) {
    final clockNow = now ?? clock.now;
    final viewer = me ?? const PlayerCard(id: 'me', displayName: 'You', handle: 'you');
    return FakeTournamentRepository(
      me: viewer,
      latency: latency,
      now: clockNow,
      tournaments: seededTournaments(viewer, clockNow()),
    );
  }

  /// The viewer as standings show them.
  final PlayerCard me;

  /// The viewer's exam.
  Goal goal;

  /// Coins available for entry fees (the balance minus what's held).
  int coins;

  /// Paid registration is blocked (3 no-shows in 30 days).
  bool noShowBlock = false;

  final int pageSize;

  /// Delay before every response, to see loading states.
  Duration latency;
  final DateTime Function() _now;
  final List<FakeTournament> _tournaments;

  /// Calls that fail until removed from the map.
  final Map<FakeArenaOp, AppFailure> failures = {};

  /// Idempotency keys seen by `register`, in order.
  final List<String> registerKeys = [];

  /// Filters asked for by `list`, in order.
  final List<ArenaFilter> listCalls = [];

  /// Coins moved by registrations, withdrawals and prizes (positive = to the player). The demo
  /// mirrors these into its wallet.
  void Function(int delta, String title, String tournamentId)? onCoins;

  /// Called after every successful check-in (the demo starts its live run from it).
  void Function(FakeTournament tournament)? onCheckedIn;

  DateTime get now => _now();

  List<FakeTournament> get tournaments => List.unmodifiable(_tournaments);

  FakeTournament? find(String id) => _tournaments.where((t) => t.id == id).firstOrNull;

  void add(FakeTournament tournament) => _tournaments.add(tournament);

  FakeTournament _get(String id) =>
      find(id) ?? (throw const NotFoundFailure('That tournament doesn\'t exist.'));

  // ------------------------------------------------------------------------------------------

  @override
  Future<CursorPage<Tournament>> list(ArenaFilter filter, {Goal? goal, String? cursor}) async {
    listCalls.add(filter);
    await _wait(FakeArenaOp.list);
    final matching =
        _tournaments
            .where((t) => t.card.status.filter == filter)
            .where((t) => goal == null || t.card.goal.admits(goal))
            .map((t) => t.card)
            .toList()
          ..sort(
            (a, b) => filter == ArenaFilter.finished
                ? b.startsAt.compareTo(a.startsAt)
                : a.startsAt.compareTo(b.startsAt),
          );
    return _page(matching, cursor);
  }

  @override
  Future<CursorPage<MyTournament>> mine({String? cursor}) async {
    await _wait(FakeArenaOp.mine);
    final entered = _tournaments.where((t) => t.card.me?.registered ?? false).toList();
    final active = entered.where((t) => !t.card.status.isOver).toList()
      ..sort((a, b) => a.card.startsAt.compareTo(b.card.startsAt));
    final past = entered.where((t) => t.card.status.isOver).toList()
      ..sort((a, b) => b.card.startsAt.compareTo(a.card.startsAt));
    return _page([
      for (final t in [...active, ...past])
        MyTournament(
          tournament: t.card,
          finalRank: t.result?.rank,
          prize: t.result?.prize,
          xp: t.result?.xp,
          points: t.result?.points,
        ),
    ], cursor);
  }

  @override
  Future<TournamentDetail> detail(String id) async {
    await _wait(FakeArenaOp.detail);
    return detailOf(_get(id));
  }

  /// What `GET /v1/tournaments/{id}` answers for [t].
  TournamentDetail detailOf(FakeTournament t) {
    final card = t.card;
    final total = t.totalRounds;
    final current = t.currentRound;
    final mine = t.field.where((s) => s.user.id == me.id).firstOrNull;
    final rank = mine == null ? null : t.ranked.indexOf(mine) + 1;
    const roundLength = Duration(minutes: 5);
    return TournamentDetail(
      tournament: card,
      description: t.description,
      schedule: [
        for (var r = 1; r <= total; r++)
          ScheduledRound(
            round: r,
            startsAt: card.startsAt.add(roundLength * (r - 1)),
            status: switch (current) {
              null => card.status.isOver ? RoundStatus.done : RoundStatus.upcoming,
              _ when card.status.isOver => RoundStatus.done,
              final c when r < c => RoundStatus.done,
              final c when r == c => t.roundStatus,
              _ => RoundStatus.upcoming,
            },
          ),
      ],
      prizes: prizeTableFor(card.prizePool, card.players),
      currentRound: current,
      me: card.me == null
          ? null
          : TournamentStanding(
              entry: card.me!,
              record: mine == null
                  ? TournamentRecord.zero
                  : TournamentRecord(wins: mine.wins, draws: mine.draws, losses: mine.losses),
              points: mine?.points ?? 0,
              rank: rank,
              nextPairing: t.current,
              result: t.result,
            ),
    );
  }

  @override
  Future<Tournament> register(String id, {required String idempotencyKey}) async {
    registerKeys.add(idempotencyKey);
    await _wait(FakeArenaOp.register);
    final t = _get(id);
    final card = t.card;
    if (card.entered) return card;
    if (!card.status.takesEntries) {
      throw const ConflictFailure('Registration has closed.', code: ArenaErrors.registrationClosed);
    }
    if (!card.goal.admits(goal)) {
      throw const ForbiddenFailure(
        'This tournament is for the other exam.',
        code: ArenaErrors.notAllowed,
        details: {'reason': 'exam'},
      );
    }
    if (card.isFull) {
      throw const ConflictFailure('This tournament is full.', code: ArenaErrors.full);
    }
    if (noShowBlock && !card.isFree) {
      throw const ForbiddenFailure(
        'Paid registration is paused.',
        code: ArenaErrors.notAllowed,
        details: {'reason': 'no_shows'},
      );
    }
    final clash = _tournaments
        .where((o) => o.id != id && o.card.entered && !o.card.status.isOver)
        .where((o) => _overlaps(o.card, card))
        .firstOrNull;
    if (clash != null) {
      throw ConflictFailure(
        'It overlaps another tournament you entered.',
        code: ArenaErrors.scheduleConflict,
        details: {'id': clash.id, 'title': clash.card.title},
      );
    }
    if (coins < card.entryFee) {
      throw ConflictFailure(
        'You need ${card.entryFee} coins.',
        code: ArenaErrors.insufficientCoins,
        details: {'needed': card.entryFee},
      );
    }
    coins -= card.entryFee;
    if (card.entryFee > 0) onCoins?.call(-card.entryFee, 'Tournament entry: ${card.title}', id);
    final players = card.players + 1;
    t.card = card.copyWith(
      players: players,
      effectivePool: effectivePoolFor(card.prizePool, players),
      me: () => const TournamentEntry(registered: true),
    );
    return t.card;
  }

  /// Two tournaments overlap when one starts before the other's estimated end.
  static bool _overlaps(Tournament a, Tournament b) {
    DateTime end(Tournament t) =>
        t.endsAtEstimate ?? t.startsAt.add(Duration(minutes: 5 * t.rounds + 5));
    return a.startsAt.isBefore(end(b)) && b.startsAt.isBefore(end(a));
  }

  @override
  Future<Withdrawal> withdraw(String id) async {
    await _wait(FakeArenaOp.withdraw);
    final t = _get(id);
    final card = t.card;
    if (!card.entered) {
      throw const ConflictFailure('You\'re not registered.', code: ArenaErrors.notRegistered);
    }
    final started = card.status.isLive || card.status.isOver;
    final refund = started ? 0 : card.entryFee;
    coins += refund;
    if (refund > 0) onCoins?.call(refund, 'Refund: withdrew from ${card.title}', id);
    if (started) {
      // Stays in the standings for the tie-breaks, without a prize.
      for (final s in t.field.where((s) => s.user.id == me.id)) {
        s.withdrawn = true;
      }
      t.current = null;
      t.card = card.copyWith(
        me: () => const TournamentEntry(registered: true, checkedIn: true, withdrawn: true),
      );
    } else {
      final players = max(0, card.players - 1);
      t.card = card.copyWith(
        players: players,
        effectivePool: effectivePoolFor(card.prizePool, players),
        me: () => null,
      );
    }
    return Withdrawal(tournament: t.card, refunded: refund);
  }

  @override
  Future<Tournament> checkIn(String id) async {
    await _wait(FakeArenaOp.checkIn);
    final t = _get(id);
    final card = t.card;
    if (!card.entered) {
      throw const ConflictFailure('You\'re not registered.', code: ArenaErrors.notRegistered);
    }
    if (!card.checkInOpen(now)) {
      throw const ConflictFailure('Check-in is closed.', code: ArenaErrors.checkInClosed);
    }
    t.card = card.copyWith(me: () => const TournamentEntry(registered: true, checkedIn: true));
    onCheckedIn?.call(t);
    return t.card;
  }

  @override
  Future<StandingsPage> standings(String id, {String? cursor}) async {
    await _wait(FakeArenaOp.standings);
    final t = _get(id);
    final rows = t.standingRows();
    final page = _page(rows, cursor);
    return StandingsPage(
      items: page.items,
      nextCursor: page.nextCursor,
      me: rows.where((row) => row.user.id == me.id).firstOrNull,
      round: t.currentRound,
    );
  }

  @override
  Future<MyGames> myGames(String id) async {
    await _wait(FakeArenaOp.myGames);
    final t = _get(id);
    final mine = t.field.where((s) => s.user.id == me.id).firstOrNull;
    return MyGames(
      rounds: List.unmodifiable(t.myRounds),
      current: t.current,
      record: mine == null
          ? TournamentRecord.zero
          : TournamentRecord(wins: mine.wins, draws: mine.draws, losses: mine.losses),
      points: mine?.points ?? 0,
      rank: mine == null ? null : t.ranked.indexOf(mine) + 1,
    );
  }

  // ------------------------------------------------------------------------------------------

  CursorPage<T> _page<T>(List<T> items, String? cursor) {
    final start = cursor == null ? 0 : int.parse(cursor);
    final end = (start + pageSize).clamp(0, items.length);
    return CursorPage(
      List.unmodifiable(items.sublist(start.clamp(0, items.length), end)),
      nextCursor: end < items.length ? '$end' : null,
    );
  }

  Future<void> _wait(FakeArenaOp op) async {
    if (latency > Duration.zero) await Future<void>.delayed(latency);
    if (failures[op] case final failure?) throw failure;
  }
}

const _names = [
  'Riya',
  'Aman',
  'Kabir',
  'Ishita',
  'Neha',
  'Arjun',
  'Meera',
  'Rohan',
  'Sana',
  'Vikram',
  'Tara',
  'Dev',
  'Anaya',
  'Kunal',
  'Pooja',
  'Yash',
];

/// A made-up player for the fake field.
PlayerCard fakePlayer(int i) {
  final name = _names[i % _names.length];
  return PlayerCard(
    id: 'fp$i',
    handle: '${name.toLowerCase()}_${20 + i}',
    displayName: name,
    avatar: Avatar(
      tone: Avatar.tones[i % Avatar.tones.length],
      symbol: Avatar.symbols.keys.elementAt(i % Avatar.symbols.length),
    ),
    level: 3 + i % 9,
  );
}

/// A field of [size] players with results after [rounds] rounds, the viewer ([me]) included when
/// given, with [myPoints].
List<FakeStanding> fakeField(int size, int rounds, {PlayerCard? me, List<GameResult>? mine}) {
  final random = Random(size * 31 + rounds);
  final field = <FakeStanding>[];
  final others = me == null ? size : size - 1;
  for (var i = 0; i < others; i++) {
    final standing = FakeStanding(fakePlayer(i));
    for (var r = 0; r < rounds; r++) {
      final roll = random.nextInt(10);
      standing.add(
        roll < 5
            ? GameResult.win
            : roll < 6
            ? GameResult.draw
            : GameResult.loss,
      );
    }
    standing.buchholz = random.nextInt(rounds * 2 + 1) + (rounds > 0 ? 1 : 0);
    field.add(standing);
  }
  if (me != null) {
    final standing = FakeStanding(me);
    for (final result in mine ?? const <GameResult>[]) {
      standing.add(result);
    }
    standing.buchholz = rounds + 1;
    field.add(standing);
  }
  return field;
}

/// Ids of the seeded tournaments, for tests and the demo.
abstract final class SeededTournaments {
  static const scheduled = 'demo-scheduled';
  static const open = 'demo-open';
  static const openFree = 'demo-open-free';
  static const full = 'demo-full';
  static const otherExam = 'demo-jee';
  static const checkIn = 'demo-check-in';
  static const locked = 'demo-locked';
  static const live = 'demo-live';

  /// The Wallet's sample prize comes from this one.
  static const finished = 'demo-t1';
  static const cancelled = 'demo-cancelled';
}

/// A tournament in every state around [now]:
/// - scheduled (registration opens tomorrow);
/// - open: a paid Physics cup that needs players ("5 of 8 needed", the pool still growing), a
///   free Biology run, a full one, and a JEE one a NEET player can't join;
/// - check-in open for a registered blitz, and a locked sprint the viewer checked in to;
/// - live, round 2 of 3, with the viewer 1–0 and waiting for the next pairing;
/// - finished (#3 of 24, 120 coins) and cancelled for too few players.
List<FakeTournament> seededTournaments(PlayerCard me, DateTime now) {
  Tournament card(
    String id,
    String title, {
    required TournamentStatus status,
    required Duration startsIn,
    String? subject,
    String tone = 'lemon',
    TournamentGoal goal = TournamentGoal.neet,
    int rounds = 5,
    int fee = 0,
    int pool = 0,
    int players = 0,
    int minPlayers = 8,
    int capacity = 64,
    TournamentEntry? entry,
  }) {
    final startsAt = now.add(startsIn);
    return Tournament(
      id: id,
      title: title,
      goal: goal,
      subject: subject,
      tone: tone,
      status: status,
      regOpensAt: startsAt.subtract(const Duration(days: 2)),
      checkinOpensAt: startsAt.subtract(CheckInWindow.opensBefore),
      startsAt: startsAt,
      endsAtEstimate: startsAt.add(Duration(minutes: 5 * rounds + 5)),
      rounds: rounds,
      entryFee: fee,
      prizePool: pool,
      effectivePool: effectivePoolFor(pool, players),
      players: players,
      minPlayers: minPlayers,
      capacity: capacity,
      me: entry,
    );
  }

  const registered = TournamentEntry(registered: true);
  const checkedIn = TournamentEntry(registered: true, checkedIn: true);
  const liveResults = [GameResult.win];
  return [
    FakeTournament(
      card: card(
        SeededTournaments.scheduled,
        'Chemistry Weekend Cup',
        status: TournamentStatus.scheduled,
        startsIn: const Duration(days: 3, hours: 2),
        subject: 'chemistry',
        tone: 'lavender',
        goal: TournamentGoal.any,
        fee: 15,
        pool: 1500,
        capacity: 128,
      ),
      description: 'Five Swiss rounds of Chemistry for NEET and JEE players.',
    ),
    FakeTournament(
      card: card(
        SeededTournaments.open,
        'Physics Sunday Cup',
        status: TournamentStatus.regOpen,
        startsIn: const Duration(hours: 3),
        subject: 'physics',
        tone: 'sky',
        fee: 25,
        pool: 2500,
        players: 5,
      ),
      description: 'Five rated rounds of Physics. The prize pool grows as players join.',
    ),
    FakeTournament(
      card: card(
        SeededTournaments.openFree,
        'Biology Speed Run',
        status: TournamentStatus.regOpen,
        startsIn: const Duration(hours: 6),
        subject: 'biology',
        tone: 'mint',
        rounds: 4,
        pool: 400,
        players: 40,
      ),
      description: 'Free entry. Four quick rounds of Biology.',
    ),
    FakeTournament(
      card: card(
        SeededTournaments.full,
        'All-India Arena Finals',
        status: TournamentStatus.regOpen,
        startsIn: const Duration(hours: 26),
        tone: 'peach',
        rounds: 6,
        fee: 50,
        pool: 5000,
        players: 16,
        capacity: 16,
      ),
      description: 'Six Swiss rounds across every NEET subject.',
    ),
    FakeTournament(
      card: card(
        SeededTournaments.otherExam,
        'JEE Maths Night',
        status: TournamentStatus.regOpen,
        startsIn: const Duration(hours: 8),
        subject: 'maths',
        tone: 'peach',
        goal: TournamentGoal.jee,
        fee: 10,
        pool: 800,
        players: 12,
      ),
      description: 'Maths for JEE aspirants.',
    ),
    FakeTournament(
      card: card(
        SeededTournaments.checkIn,
        'Physics Blitz',
        status: TournamentStatus.checkIn,
        startsIn: const Duration(minutes: 10),
        subject: 'physics',
        tone: 'sky',
        rounds: 3,
        fee: 10,
        pool: 600,
        players: 9,
        capacity: 32,
        entry: registered,
      ),
      description: 'Three fast rounds of Physics.',
    ),
    FakeTournament(
      card: card(
        SeededTournaments.locked,
        'Chemistry Sprint',
        status: TournamentStatus.locked,
        startsIn: const Duration(minutes: 4),
        subject: 'chemistry',
        tone: 'lavender',
        goal: TournamentGoal.any,
        rounds: 3,
        pool: 300,
        players: 11,
        capacity: 32,
      ),
      description: 'Registration is closed; check-in ends 2 minutes before the start.',
    ),
    FakeTournament(
      card: card(
        SeededTournaments.live,
        'Biology Night Arena',
        status: TournamentStatus.running,
        startsIn: const Duration(minutes: -7),
        subject: 'biology',
        tone: 'mint',
        rounds: 3,
        fee: 15,
        pool: 1000,
        players: 12,
        entry: checkedIn,
      ),
      description: 'Three rounds of Biology. Standings update live.',
      field: fakeField(12, 1, me: me, mine: liveResults),
      myRounds: [
        RoundGame(
          round: 1,
          opponent: fakePlayer(4),
          result: GameResult.win,
          points: 1,
          matchId: 'demo-live-r1',
        ),
      ],
      currentRound: 2,
      roundStatus: RoundStatus.pairing,
    ),
    FakeTournament(
      card: card(
        SeededTournaments.finished,
        'Physics Sunday Cup',
        status: TournamentStatus.finished,
        startsIn: const Duration(days: -4),
        subject: 'physics',
        tone: 'sky',
        fee: 25,
        pool: 1200,
        players: 24,
        entry: checkedIn,
      ),
      description: 'Last week\'s cup.',
      field: fakeField(
        24,
        5,
        me: me,
        mine: const [
          GameResult.win,
          GameResult.win,
          GameResult.loss,
          GameResult.win,
          GameResult.draw,
        ],
      ),
      myRounds: [
        for (final (i, result) in const [
          GameResult.win,
          GameResult.win,
          GameResult.loss,
          GameResult.win,
          GameResult.draw,
        ].indexed)
          RoundGame(
            round: i + 1,
            opponent: fakePlayer(i + 2),
            result: result,
            points: switch (result) {
              GameResult.win => 1,
              GameResult.draw => 0.5,
              GameResult.loss => 0,
            },
            matchId: 'demo-t1-r${i + 1}',
          ),
      ],
      currentRound: 5,
      roundStatus: RoundStatus.done,
      result: const TournamentFinal(rank: 3, players: 24, points: 3.5, prize: 120, xp: 50),
    ),
    FakeTournament(
      card: card(
        SeededTournaments.cancelled,
        'Chemistry Morning Cup',
        status: TournamentStatus.cancelled,
        startsIn: const Duration(days: -1),
        subject: 'chemistry',
        tone: 'lavender',
        goal: TournamentGoal.any,
        fee: 10,
        pool: 500,
        players: 3,
      ),
      description: 'Cancelled: not enough players. Every entry fee was returned.',
    ),
  ];
}
