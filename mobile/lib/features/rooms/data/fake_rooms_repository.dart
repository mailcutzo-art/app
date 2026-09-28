import 'package:realtime_client/realtime_client.dart' show RoomSettings;

import '../../../core/network/app_failure.dart';
import '../../social/data/social_models.dart' show UserCard;
import 'room_models.dart';
import 'rooms_repository.dart';

/// In-memory stand-in for the rooms and invites endpoints, for tests.
class FakeRoomsRepository implements RoomsRepository {
  FakeRoomsRepository({this.latency = Duration.zero});

  /// Delay before every response, to see loading states.
  Duration latency;

  /// When set, every call throws it until cleared.
  AppFailure? failure;

  /// Previews by code. Unknown codes are `404 ROOM_NOT_FOUND`.
  final Map<String, RoomPreview> previews = {};

  /// The answer to `POST /v1/invites` by friend id: a failure to throw (e.g. `BUSY`).
  final Map<String, AppFailure> inviteFailures = {};

  /// The answer to `POST /v1/invites/{id}/accept` by invite id: a failure to throw.
  final Map<String, AppFailure> acceptFailures = {};

  /// Pending invites for `GET /v1/me/invites`.
  InviteList pending = const InviteList();

  /// Rooms of accepted invites, by invite id.
  final Map<String, AcceptedInvite> accepted = {};

  // Calls, in order.
  final List<({RoomKind kind, RoomSettings settings, String key})> created = [];
  final List<String> previewed = [];
  final List<({String to, String roomId})> invited = [];
  final List<String> acceptedIds = [];
  final List<String> declined = [];
  final List<String> cancelled = [];
  int inviteListCalls = 0;

  int _rooms = 0;
  int _invites = 0;

  @override
  Future<CreatedRoom> create({
    required RoomKind kind,
    required RoomSettings settings,
    required String idempotencyKey,
  }) async {
    await _wait();
    created.add((kind: kind, settings: settings, key: idempotencyKey));
    final n = ++_rooms;
    final code = 'ABC${n.toString().padLeft(3, '0')}';
    return CreatedRoom(roomId: 'R$n', code: code, link: 'https://quiz.test/j/$code');
  }

  @override
  Future<RoomPreview> preview(String code) async {
    await _wait();
    previewed.add(code);
    final preview = previews[code];
    if (preview == null) {
      throw const NotFoundFailure('That code isn\'t active.', code: 'ROOM_NOT_FOUND');
    }
    return preview;
  }

  @override
  Future<SentInvite> invite({required String toUserId, required String roomId}) async {
    await _wait();
    invited.add((to: toUserId, roomId: roomId));
    if (inviteFailures[toUserId] case final failure?) throw failure;
    return SentInvite(inviteId: 'I${++_invites}');
  }

  @override
  Future<InviteList> invites() async {
    await _wait();
    inviteListCalls++;
    return pending;
  }

  @override
  Future<AcceptedInvite> accept(String inviteId) async {
    await _wait();
    acceptedIds.add(inviteId);
    if (acceptFailures[inviteId] case final failure?) throw failure;
    return accepted[inviteId] ?? const AcceptedInvite(roomId: 'R9', code: 'K7M2QX');
  }

  @override
  Future<void> decline(String inviteId) async {
    await _wait();
    declined.add(inviteId);
  }

  @override
  Future<void> cancel(String inviteId) async {
    await _wait();
    cancelled.add(inviteId);
  }

  Future<void> _wait() async {
    if (latency > Duration.zero) await Future<void>.delayed(latency);
    if (failure case final failure?) throw failure;
  }
}

/// A preview of a joinable group room hosted by Riya, for tests.
RoomPreview samplePreview({
  String roomId = 'R9',
  RoomKind kind = RoomKind.group,
  bool joinable = true,
  JoinBlock? reason,
}) => RoomPreview(
  roomId: roomId,
  kind: kind,
  host: const UserCard(id: 'u2', handle: 'riya_s', displayName: 'Riya'),
  subject: 'Physics',
  questions: 10,
  seconds: 15,
  members: 3,
  capacity: kind == RoomKind.group ? 8 : 2,
  joinable: joinable,
  reason: reason,
);
