import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:realtime_client/realtime_client.dart' show RoomSettings;

import '../../../core/network/api_client.dart';
import '../../battle/data/battle_repository.dart' show parseResponse;
import '../../battle/demo/demo_providers.dart';
import '../../learn/data/learn_repository.dart' show demoDataProvider;
import 'room_models.dart';

/// Rooms and invites over REST (`docs/api-play.md`, "Rooms and invites"). Everything after
/// creating or accepting is live (`room.*` on the socket).
abstract interface class RoomsRepository {
  /// `POST /v1/rooms` with an `Idempotency-Key`: a repeat with the same key returns the same room.
  Future<CreatedRoom> create({
    required RoomKind kind,
    required RoomSettings settings,
    required String idempotencyKey,
  });

  /// `GET /v1/rooms/code/{code}`. Throws `NotFoundFailure` (`ROOM_NOT_FOUND`) for a code that
  /// isn't active, and `RateLimitedFailure` after too many wrong guesses.
  Future<RoomPreview> preview(String code);

  /// `POST /v1/invites`. Throws `ConflictFailure` `BUSY` when the friend is busy and
  /// `ForbiddenFailure` `NOT_ALLOWED` for their privacy settings or a block.
  Future<SentInvite> invite({required String toUserId, required String roomId});

  /// `GET /v1/me/invites`: pending invites, incoming and outgoing.
  Future<InviteList> invites();

  /// `POST /v1/invites/{id}/accept`. Throws `NotFoundFailure` `INVITE_EXPIRED` (410) once it
  /// lapsed, and `ConflictFailure` `BUSY`.
  Future<AcceptedInvite> accept(String inviteId);

  /// `POST /v1/invites/{id}/decline`.
  Future<void> decline(String inviteId);

  /// `DELETE /v1/invites/{id}`: the sender takes it back.
  Future<void> cancel(String inviteId);
}

class ApiRoomsRepository implements RoomsRepository {
  ApiRoomsRepository(this._api);

  final ApiClient _api;

  @override
  Future<CreatedRoom> create({
    required RoomKind kind,
    required RoomSettings settings,
    required String idempotencyKey,
  }) async {
    final data = await _api.post(
      '/v1/rooms',
      body: {'kind': kind.wire, 'settings': settings.toJson()},
      idempotencyKey: idempotencyKey,
    );
    return parseResponse(() => CreatedRoom.fromJson(data));
  }

  @override
  Future<RoomPreview> preview(String code) async {
    final data = await _api.get('/v1/rooms/code/${Uri.encodeComponent(code)}');
    return parseResponse(() => RoomPreview.fromJson(data));
  }

  @override
  Future<SentInvite> invite({required String toUserId, required String roomId}) async {
    final data = await _api.post('/v1/invites', body: {'to_user_id': toUserId, 'room_id': roomId});
    return parseResponse(() => SentInvite.fromJson(data));
  }

  @override
  Future<InviteList> invites() async {
    final data = await _api.get('/v1/me/invites');
    return parseResponse(() => InviteList.fromJson(data));
  }

  @override
  Future<AcceptedInvite> accept(String inviteId) async {
    final data = await _api.post('/v1/invites/${Uri.encodeComponent(inviteId)}/accept');
    return parseResponse(() => AcceptedInvite.fromJson(data));
  }

  @override
  Future<void> decline(String inviteId) =>
      _api.post('/v1/invites/${Uri.encodeComponent(inviteId)}/decline');

  @override
  Future<void> cancel(String inviteId) =>
      _api.delete('/v1/invites/${Uri.encodeComponent(inviteId)}');
}

final roomsRepositoryProvider = Provider<RoomsRepository>((ref) {
  // The constant keeps the demo out of release builds entirely.
  if (!kReleaseMode && ref.watch(demoDataProvider)) return ref.watch(demoRoomsRepositoryProvider);
  return ApiRoomsRepository(ref.watch(apiClientProvider));
});
