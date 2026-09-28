import 'dart:async';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/session.dart';
import '../../../core/auth/user.dart';
import '../../battle/demo/demo_providers.dart';
import '../../battle/demo/demo_server.dart';
import '../../battle/demo/demo_world.dart';
import '../../leaderboards/data/leaderboard_models.dart' show PlayerCard;
import '../../wallet/data/wallet_models.dart';
import '../../wallet/data/wallet_repository.dart';
import '../data/fake_tournament_repository.dart';
import '../data/tournament_models.dart';

/// The Arena in the debug "Demo data" mode: the seeded schedule, plus a live run on the demo
/// realtime server. Checking in to the seeded blitz starts it (in a few seconds, to keep the
/// demo short): round games against demo players, a bye in round 2, live standings on `t:`,
/// and `t.finished` with a prize credited to the demo wallet.
class DemoArena implements DemoServerExtension {
  DemoArena({required this.repository, this.server, this.wallet}) {
    repository
      ..onCoins = _onCoins
      ..onCheckedIn = _onCheckedIn;
    if (wallet case final wallet?) repository.coins = wallet.balance - wallet.held;
    server?.extensions.add(this);
  }

  final FakeTournamentRepository repository;
  final DemoRealtimeServer? server;
  final FakeWalletRepository? wallet;

  /// How long after check-in the demo run starts.
  Duration startAfter = const Duration(seconds: 15);

  /// The break between a round's end and the next pairing.
  Duration pairingGap = const Duration(seconds: 12);

  /// How long the other boards take when the viewer has a bye.
  Duration byeRoundFor = const Duration(seconds: 20);

  final Set<String> _subscribed = {};
  final Random _random = Random(11);
  final List<Timer> _timers = [];
  String? _running;
  bool _disposed = false;

  PlayerCard get _me => repository.me;

  void dispose() {
    _disposed = true;
    for (final timer in _timers) {
      timer.cancel();
    }
    server?.extensions.remove(this);
  }

  void _after(Duration delay, void Function() callback) {
    final server = this.server;
    if (server == null) return;
    _timers.add(
      server.after(delay, () {
        if (!_disposed) callback();
      }),
    );
  }

  // ------------------------------------------------------------------------------------------
  // The socket side

  @override
  bool handle(String type, String? ref, Map<String, Object?> data) {
    if (type != 'sub' && type != 'unsub') return false;
    final channel = data['ch'];
    final id = channel is String && channel.startsWith('t:') ? channel.substring(2) : null;
    final tournament = id == null ? null : repository.find(id);
    if (tournament == null) {
      server?.refuse(ref, 'NOT_FOUND', 'That tournament doesn\'t exist.');
      return true;
    }
    if (type == 'sub') {
      _subscribed.add(tournament.id);
      // The natural reply to `sub` is the current standings.
      _standings(tournament);
    } else {
      _subscribed.remove(tournament.id);
      server?.ack(ref);
    }
    return true;
  }

  @override
  List<Map<String, Object?>> get active => [
    if (_running case final id?)
      if (repository.find(id) case final t?)
        {'kind': 'tournament', 'id': id, 'title': t.card.title},
  ];

  Map<String, Object?> _row(int rank, FakeStanding s) => {
    'rank': rank,
    'uid': s.user.id,
    'name': s.user.displayName,
    'avatar': s.user.avatar.toJson(),
    'points': s.points,
    'w': s.wins,
    'd': s.draws,
    'l': s.losses,
    'bh_c1': s.buchholz,
  };

  void _standings(FakeTournament t) {
    final ranked = t.ranked;
    final mine = ranked.where((s) => s.user.id == _me.id).firstOrNull;
    server?.sendOn('t:${t.id}', 't.standings', {
      'round': t.currentRound ?? 0,
      'rows': [for (final (i, s) in ranked.take(20).indexed) _row(i + 1, s)],
      'me': mine == null ? null : _row(ranked.indexOf(mine) + 1, mine),
    });
  }

  void _publish(FakeTournament t) {
    if (_subscribed.contains(t.id)) _standings(t);
  }

  void _round(FakeTournament t, RoundStatus status, {DateTime? startsAt}) {
    t.roundStatus = status;
    server?.sendOn('t:${t.id}', 't.round', {
      'round': t.currentRound,
      'status': status.wire,
      'starts_at': startsAt?.millisecondsSinceEpoch,
      'ends_at': null,
    });
  }

  // ------------------------------------------------------------------------------------------
  // Coins

  void _onCoins(int delta, String title, String tournamentId) {
    final wallet = this.wallet;
    if (wallet == null) return;
    // Entry fees are held at registration and returned on a withdraw before the start.
    wallet.held = max(0, wallet.held - delta);
  }

  void _post(int delta, String title, String tournamentId, String reason) {
    final wallet = this.wallet;
    if (wallet == null) return;
    wallet.post(
      WalletTx(
        id: 'demo-tx-${DateTime.now().microsecondsSinceEpoch}',
        delta: delta,
        balanceAfter: wallet.balance + delta,
        reason: reason,
        title: title,
        ref: TxRef(kind: TxKind.tournament, id: tournamentId),
        createdAt: DateTime.now(),
      ),
    );
  }

  // ------------------------------------------------------------------------------------------
  // The live run

  void _onCheckedIn(FakeTournament t) {
    if (server == null || _running != null || t.card.status.isLive) return;
    // Demo time: the blitz starts shortly after check-in instead of at its real time.
    final startsAt = repository.now.add(startAfter);
    t.card = t.card.copyWith(status: TournamentStatus.locked, startsAt: startsAt);
    _after(startAfter, () => _start(t));
  }

  void _start(FakeTournament t) {
    final card = t.card;
    // The field: the other registrants and the viewer. An odd count gives out byes.
    final others = max(card.players - 1, 4);
    t.field
      ..clear()
      ..addAll(fakeField(others + 1, 0, me: _me));
    t.card = card.copyWith(
      status: TournamentStatus.running,
      players: others + 1,
      effectivePool: effectivePoolFor(card.prizePool, others + 1),
    );
    if (card.entryFee > 0) {
      wallet?.held = max(0, (wallet?.held ?? 0) - card.entryFee);
      _post(-card.entryFee, 'Tournament entry: ${card.title}', card.id, 'tournament_entry');
    }
    _running = t.id;
    _playRound(t, 1);
  }

  PlayerCard _opponentFor(FakeTournament t, int round) {
    final others = t.field.where((s) => s.user.id != _me.id).toList();
    return others[(round - 1) * 2 % others.length].user;
  }

  void _playRound(FakeTournament t, int round) {
    t
      ..currentRound = round
      ..current = null;
    // Round 2 is the viewer's bye, so every demo shows one.
    if (round == 2 && t.field.length.isOdd) {
      t.current = Pairing(round: round, bye: true);
      _round(t, RoundStatus.live);
      server?.sendUser('t.bye', {'tournament_id': t.id, 'round': round, 'points': 1});
      t.myRounds.add(RoundGame(round: round, bye: true, points: 1));
      _after(byeRoundFor, () {
        final mine = t.field.firstWhere((s) => s.user.id == _me.id);
        mine.points += 1;
        _endRound(t, round, skip: mine);
      });
      return;
    }
    final opponent = _opponentFor(t, round);
    final match = server!.startTournamentMatch(
      tournamentId: t.id,
      opponent: DemoPlayer(
        uid: opponent.id,
        name: opponent.displayName,
        handle: opponent.handle,
        tone: opponent.avatar.tone,
        symbol: opponent.avatar.symbol,
        level: opponent.level ?? 5,
        rating: '${1480 + round * 17}',
      ),
      subject: t.card.subject ?? 'physics',
      onEnd: (match, result) => _onGameOver(t, round, opponent, match.id, result),
    );
    final readyBy = repository.now.add(server!.tournamentReadyWait);
    t
      ..current = Pairing(round: round, opponent: opponent, matchId: match.id, readyBy: readyBy)
      ..myRounds.add(RoundGame(round: round, opponent: opponent, matchId: match.id));
    _round(t, RoundStatus.live);
    server!.sendUser('t.pairing', {
      'tournament_id': t.id,
      'round': round,
      'match_id': match.id,
      'ch': match.channel,
      'opponent': {...opponent.toJson(), 'uid': opponent.id, 'is_bot': false},
      'ready_by': readyBy.millisecondsSinceEpoch,
    });
  }

  void _onGameOver(FakeTournament t, int round, PlayerCard opponent, String matchId, String wire) {
    final result = GameResult.parse(wire) ?? GameResult.loss;
    final mine = t.field.firstWhere((s) => s.user.id == _me.id);
    final theirs = t.field.firstWhere((s) => s.user.id == opponent.id);
    mine.add(result);
    theirs.add(switch (result) {
      GameResult.win => GameResult.loss,
      GameResult.loss => GameResult.win,
      GameResult.draw => GameResult.draw,
    });
    final index = t.myRounds.indexWhere((g) => g.round == round);
    if (index >= 0) {
      t.myRounds[index] = RoundGame(
        round: round,
        opponent: opponent,
        matchId: matchId,
        result: result,
        points: switch (result) {
          GameResult.win => 1,
          GameResult.draw => 0.5,
          GameResult.loss => 0,
        },
      );
    }
    t.current = null;
    _endRound(t, round, skip: mine, alsoSkip: theirs);
  }

  /// The other boards finish, the standings move, and the next round is paired (or the
  /// tournament ends).
  void _endRound(FakeTournament t, int round, {FakeStanding? skip, FakeStanding? alsoSkip}) {
    for (final s in t.field) {
      if (identical(s, skip) || identical(s, alsoSkip)) continue;
      final roll = _random.nextInt(10);
      s
        ..add(
          roll < 4
              ? GameResult.win
              : roll < 5
              ? GameResult.draw
              : GameResult.loss,
        )
        ..buchholz += _random.nextInt(3);
    }
    _round(t, RoundStatus.done);
    _publish(t);
    if (round >= t.totalRounds) {
      _after(const Duration(seconds: 3), () => _finish(t));
      return;
    }
    final next = repository.now.add(pairingGap);
    t.currentRound = round + 1;
    _round(t, RoundStatus.pairing, startsAt: next);
    _after(pairingGap, () => _playRound(t, round + 1));
  }

  void _finish(FakeTournament t) {
    final ranked = t.ranked;
    final mine = ranked.firstWhere((s) => s.user.id == _me.id);
    final rank = ranked.indexOf(mine) + 1;
    final prizes = prizeTableFor(t.card.prizePool, ranked.length);
    final prize = prizes.where((p) => rank >= p.from && rank <= p.to).firstOrNull?.coins ?? 0;
    final games = t.myRounds.where((g) => !g.bye).length;
    final result = TournamentFinal(
      rank: rank,
      players: ranked.length,
      points: mine.points,
      prize: prize,
      xp: 10 * games,
    );
    t
      ..result = result
      ..current = null
      ..roundStatus = RoundStatus.done
      ..card = t.card.copyWith(status: TournamentStatus.finished);
    _running = null;
    if (prize > 0) {
      _post(prize, 'Tournament prize: #$rank in ${t.card.title}', t.id, 'tournament_prize');
    }
    _publish(t);
    server?.sendUser('t.finished', {
      'tournament_id': t.id,
      'rank': rank,
      'players': ranked.length,
      'points': mine.points,
      'prize': prize,
      'xp': result.xp,
    });
  }
}

/// The demo Arena, sharing the demo's realtime server and wallet.
final demoArenaProvider = Provider<DemoArena>((ref) {
  ref.watch(currentUserIdProvider);
  final user = switch (ref.read(sessionProvider).value) {
    SignedIn(:final user) => user,
    _ => null,
  };
  final me = PlayerCard(
    id: user?.id ?? 'me',
    handle: user?.handle,
    displayName: user?.displayName.split(' ').first ?? 'You',
    avatar: user?.avatar ?? Avatar.fallback,
    level: 4,
  );
  final arena = DemoArena(
    repository: FakeTournamentRepository.seeded(me: me, latency: const Duration(milliseconds: 300))
      ..goal = user?.goal ?? Goal.neet,
    server: ref.watch(demoRealtimeServerProvider),
    wallet: ref.watch(demoWalletRepositoryProvider),
  );
  ref.onDispose(arena.dispose);
  return arena;
});
