import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_app/features/arena/data/fake_tournament_repository.dart';
import 'package:quiz_app/features/arena/data/tournament_models.dart';
import 'package:quiz_app/features/arena/demo/demo_arena.dart';
import 'package:quiz_app/features/battle/demo/demo_server.dart';
import 'package:quiz_app/features/battle/demo/demo_world.dart';
import 'package:quiz_app/features/leaderboards/data/leaderboard_models.dart';
import 'package:quiz_app/features/wallet/data/wallet_repository.dart';

void main() {
  test('checking in to the demo blitz plays a whole tournament', () {
    fakeAsync((async) {
      final server = DemoRealtimeServer(
        me: const DemoPlayer(uid: 'u1', name: 'Aarav'),
      )..latency = Duration.zero;
      final wallet = FakeWalletRepository(balance: 245);
      final arena = DemoArena(
        repository: FakeTournamentRepository.seeded(
          me: const PlayerCard(id: 'u1', displayName: 'Aarav'),
        ),
        server: server,
        wallet: wallet,
      );
      final frames = <Map<String, Object?>>[];
      late final socket = server.connect();
      socket.then((s) {
        s.frames.listen((f) => frames.add(jsonDecode(f! as String) as Map<String, Object?>));
        s.send(jsonEncode({'v': 1, 't': 'hello', 'id': 'c0', 'd': <String, Object?>{}}));
        s.send(
          jsonEncode({
            'v': 1,
            't': 'sub',
            'id': 'c1',
            'd': {'ch': 't:${SeededTournaments.checkIn}'},
          }),
        );
      });
      async.elapse(const Duration(milliseconds: 100));
      List<Map<String, Object?>> ofType(String type) => [
        for (final f in frames)
          if (f['t'] == type) f,
      ];
      expect(ofType('t.standings'), hasLength(1), reason: 'the reply to sub');

      arena.repository.checkIn(SeededTournaments.checkIn);
      async.elapse(const Duration(seconds: 16));
      final pairing = ofType('t.pairing').single['d']! as Map<String, Object?>;
      expect(pairing['round'], 1);
      expect(arena.active.single['id'], SeededTournaments.checkIn);
      expect(wallet.balance, 235, reason: 'the fee is taken at the start');

      // Nobody gets ready: a forfeit after 90 s, then a bye, then round 3.
      async.elapse(const Duration(minutes: 20));
      expect(ofType('t.bye'), hasLength(1));
      expect(ofType('t.pairing'), hasLength(2));
      final finished = ofType('t.finished').single['d']! as Map<String, Object?>;
      expect(finished['players'], 9);
      final t = arena.repository.find(SeededTournaments.checkIn)!;
      expect(t.card.status, TournamentStatus.finished);
      expect(t.result!.rank, finished['rank']);
      expect(t.myRounds.map((g) => g.bye), [false, true, false]);
      expect(ofType('t.standings').length, greaterThan(1));
      arena.dispose();
      server.dispose();
    });
  });
}
