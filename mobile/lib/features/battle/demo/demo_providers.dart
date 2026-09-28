import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:realtime_client/realtime_client.dart' show RoomSettings;

import '../../../core/auth/session.dart';
import '../../../core/network/app_failure.dart';
import '../../learn/data/learn_repository.dart' show demoLearnRepositoryProvider;
import '../../rooms/data/room_models.dart';
import '../../rooms/data/rooms_repository.dart';
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
  // A friend's invite comes in a little while after starting, so the banner can be tried.
  final server = DemoRealtimeServer(me: DemoPlayer.fromMe(user))
    ..inviteAfterWelcome = const Duration(seconds: 90);
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

/// Rooms and invites in the demo, answered by the demo server.
final demoRoomsRepositoryProvider = Provider<RoomsRepository>(
  (ref) => DemoRoomsRepository(ref.watch(demoRealtimeServerProvider)),
);

/// The rooms and invites endpoints, answered by the demo server, with the real API's failures.
class DemoRoomsRepository implements RoomsRepository {
  DemoRoomsRepository(this._server, {this.latency = const Duration(milliseconds: 300)});

  final DemoRealtimeServer _server;
  Duration latency;

  Future<T> _call<T>(T Function() answer) async {
    if (latency > Duration.zero) await Future<void>.delayed(latency);
    try {
      return answer();
    } on DemoRoomError catch (error) {
      throw switch (error.status) {
        404 || 410 => NotFoundFailure(error.message, code: error.code),
        403 => ForbiddenFailure(error.message, code: error.code, details: error.details),
        409 => ConflictFailure(error.message, code: error.code, details: error.details),
        _ => const UnexpectedFailure(),
      };
    }
  }

  @override
  Future<CreatedRoom> create({
    required RoomKind kind,
    required RoomSettings settings,
    required String idempotencyKey,
  }) => _call(() => CreatedRoom.fromJson(_server.createRoomJson(kind.wire, settings.toJson())));

  @override
  Future<RoomPreview> preview(String code) =>
      _call(() => RoomPreview.fromJson(_server.previewJson(code)));

  @override
  Future<SentInvite> invite({required String toUserId, required String roomId}) =>
      _call(() => SentInvite.fromJson(_server.inviteJson(toUserId, roomId)));

  @override
  Future<InviteList> invites() => _call(() => InviteList.fromJson(_server.invitesJson()));

  @override
  Future<AcceptedInvite> accept(String inviteId) =>
      _call(() => AcceptedInvite.fromJson(_server.acceptInviteJson(inviteId)));

  @override
  Future<void> decline(String inviteId) => _call(() => _server.declineInvite(inviteId));

  @override
  Future<void> cancel(String inviteId) => _call(() => _server.cancelInvite(inviteId));
}

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
