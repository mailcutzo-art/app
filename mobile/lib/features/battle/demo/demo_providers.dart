import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/session.dart';
import '../../../core/network/app_failure.dart';
import '../../learn/data/learn_repository.dart' show demoLearnRepositoryProvider;
import '../data/battle_repository.dart';
import '../data/fake_battle_repository.dart';
import '../data/match_models.dart';
import 'demo_server.dart';
import 'demo_world.dart';

/// The in-app realtime server behind the debug "Demo data" switch. Debug builds only: every
/// reference to it sits behind a `kReleaseMode` check.
final demoRealtimeServerProvider = Provider<DemoRealtimeServer>((ref) {
  ref.watch(currentUserIdProvider);
  final user = switch (ref.read(sessionProvider).value) {
    SignedIn(:final user) => user,
    _ => null,
  };
  final server = DemoRealtimeServer(me: DemoPlayer.fromMe(user));
  ref.onDispose(server.dispose);
  return server;
});

/// The Battle tab's data in the demo, which follows the demo's coins and ratings.
final demoBattleRepositoryProvider = Provider<BattleRepository>((ref) {
  final server = ref.watch(demoRealtimeServerProvider);
  return FakeBattleRepository(
    setup: server.world.setup,
    latency: const Duration(milliseconds: 300),
  );
});

/// Match results and reviews in the demo, read from the demo server.
final demoMatchRepositoryProvider = Provider<MatchRepository>(
  (ref) => DemoMatchRepository(
    ref.watch(demoRealtimeServerProvider),
    bookmarks: () => ref.read(demoLearnRepositoryProvider).bookmarks,
  ),
);

/// `GET /v1/matches/{id}` and its review, answered by the demo server.
class DemoMatchRepository implements MatchRepository {
  DemoMatchRepository(
    this._server, {
    Set<String> Function()? bookmarks,
    this.latency = const Duration(milliseconds: 300),
  }) : _bookmarks = bookmarks ?? (() => const {});

  final DemoRealtimeServer _server;
  final Set<String> Function() _bookmarks;
  Duration latency;

  /// When set, every call throws it until cleared.
  AppFailure? failure;

  /// Match ids asked for, in order.
  final List<String> calls = [];

  @override
  Future<MatchSummary> match(String matchId) async {
    calls.add(matchId);
    await _wait();
    final json = _server.summaryJson(matchId);
    if (json == null) throw const NotFoundFailure('That game isn\'t on record.');
    return MatchSummary.fromJson(json);
  }

  @override
  Future<MatchReview> review(String matchId) async {
    await _wait();
    final json = _server.reviewJson(matchId, bookmarks: _bookmarks());
    if (json == null) throw const NotFoundFailure('The review opens once the game is over.');
    return MatchReview.fromJson(json);
  }

  Future<void> _wait() async {
    if (latency > Duration.zero) await Future<void>.delayed(latency);
    if (failure case final failure?) throw failure;
  }
}
