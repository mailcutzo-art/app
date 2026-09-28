import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/session.dart';
import '../../core/network/app_failure.dart';
import 'data/social_models.dart';
import 'data/social_repository.dart';

/// Sections show their own retry button, so Riverpod's automatic retry is off.
Duration? _noAutoRetry(int _, Object _) => null;

// ---------------------------------------------------------------- friends

/// The friends loaded so far, in server order, and where the next page starts.
@immutable
class FriendsState {
  const FriendsState({this.friends = const [], this.nextCursor, this.loadingMore = false});

  final List<Friend> friends;
  final String? nextCursor;
  final bool loadingMore;

  bool get hasMore => nextCursor != null;

  /// Online first, then busy (in a battle or tournament), then offline; by name within each.
  List<Friend> get sorted => [...friends]
    ..sort((a, b) {
      final byPresence = a.presence.rank.compareTo(b.presence.rank);
      if (byPresence != 0) return byPresence;
      return a.user.displayName.toLowerCase().compareTo(b.user.displayName.toLowerCase());
    });

  int get onlineCount => friends.where((f) => f.presence != FriendPresence.offline).length;

  FriendsState copyWith({List<Friend>? friends, String? nextCursor, bool? loadingMore}) =>
      FriendsState(
        friends: List.unmodifiable(friends ?? this.friends),
        nextCursor: nextCursor ?? this.nextCursor,
        loadingMore: loadingMore ?? this.loadingMore,
      );
}

final friendsProvider = AsyncNotifierProvider<FriendsController, FriendsState>(
  FriendsController.new,
  retry: _noAutoRetry,
);

class FriendsController extends AsyncNotifier<FriendsState> {
  var _polling = false;

  SocialRepository get _repo => ref.read(socialRepositoryProvider);

  @override
  Future<FriendsState> build() async {
    // Someone else signing in on this phone must not see the last user's friends.
    ref.watch(currentUserIdProvider);
    final page = await ref.watch(socialRepositoryProvider).friends();
    return FriendsState(friends: List.unmodifiable(page.items), nextCursor: page.nextCursor);
  }

  /// Appends the next page. Failures keep the list and are rethrown for a toast.
  Future<void> loadMore() async {
    final current = state.value;
    if (current == null || !current.hasMore || current.loadingMore) return;
    state = AsyncData(current.copyWith(loadingMore: true));
    try {
      final page = await _repo.friends(cursor: current.nextCursor);
      final latest = state.value ?? current;
      final known = {for (final f in latest.friends) f.user.id};
      state = AsyncData(
        FriendsState(
          friends: List.unmodifiable([
            ...latest.friends,
            ...page.items.where((f) => !known.contains(f.user.id)),
          ]),
          nextCursor: page.nextCursor,
        ),
      );
    } on AppFailure {
      state = AsyncData((state.value ?? current).copyWith(loadingMore: false));
      rethrow;
    }
  }

  /// Reloads the pages loaded so far without a loading state, for the 30 s
  /// presence poll. A failed poll keeps what is on screen.
  Future<void> poll() async {
    final current = state.value;
    if (current == null || _polling) return;
    _polling = true;
    try {
      final friends = <Friend>[];
      String? cursor;
      do {
        final page = await _repo.friends(cursor: cursor);
        friends.addAll(page.items);
        cursor = page.nextCursor;
      } while (cursor != null && friends.length < current.friends.length);
      final latest = state.value;
      if (latest == null || latest.loadingMore) return;
      state = AsyncData(FriendsState(friends: List.unmodifiable(friends), nextCursor: cursor));
    } on AppFailure catch (failure) {
      debugPrint('Presence poll failed: $failure');
    } finally {
      _polling = false;
    }
  }

  /// Takes a friend off the list (optimistically) and returns how to put
  /// them back; null when they weren't listed.
  VoidCallback? removeLocal(String userId) {
    final current = state.value;
    if (current == null) return null;
    final index = current.friends.indexWhere((f) => f.user.id == userId);
    if (index < 0) return null;
    final removed = current.friends[index];
    state = AsyncData(current.copyWith(friends: [...current.friends]..removeAt(index)));
    return () {
      final latest = state.value;
      if (latest == null || latest.friends.any((f) => f.user.id == userId)) return;
      final at = index.clamp(0, latest.friends.length);
      state = AsyncData(latest.copyWith(friends: [...latest.friends]..insert(at, removed)));
    };
  }

  /// Adds a new friend (after accepting a request) and returns how to undo it.
  VoidCallback? addLocal(UserCard user) {
    final current = state.value;
    if (current == null || current.friends.any((f) => f.user.id == user.id)) return null;
    state = AsyncData(
      current.copyWith(
        friends: [
          Friend(user: user),
          ...current.friends,
        ],
      ),
    );
    return () => removeLocal(user.id);
  }
}

// ---------------------------------------------------------------- requests

final friendRequestsProvider = AsyncNotifierProvider<FriendRequestsController, FriendRequests>(
  FriendRequestsController.new,
  retry: _noAutoRetry,
);

class FriendRequestsController extends AsyncNotifier<FriendRequests> {
  @override
  Future<FriendRequests> build() {
    ref.watch(currentUserIdProvider);
    return ref.watch(socialRepositoryProvider).requests();
  }

  /// Reloads without a loading state; a failure keeps what is on screen.
  Future<void> poll() async {
    if (state.value == null) return;
    try {
      final latest = await ref.read(socialRepositoryProvider).requests();
      state = AsyncData(latest);
    } on AppFailure catch (failure) {
      debugPrint('Friend requests poll failed: $failure');
    }
  }

  /// Removes every request with [userId], both directions, and returns how
  /// to put them back.
  VoidCallback? removeLocal(String userId) {
    final current = state.value;
    if (current == null) return null;
    final next = current.copyWith(
      incoming: current.incoming.where((r) => r.user.id != userId).toList(),
      outgoing: current.outgoing.where((r) => r.user.id != userId).toList(),
    );
    if (next.incoming.length == current.incoming.length &&
        next.outgoing.length == current.outgoing.length) {
      return null;
    }
    state = AsyncData(next);
    return () => state = AsyncData(current);
  }

  /// Adds the user's own new request and returns how to undo it.
  VoidCallback? addOutgoing(FriendRequest request) {
    final current = state.value;
    if (current == null || current.outgoingTo(request.user.id) != null) return null;
    state = AsyncData(current.copyWith(outgoing: [request, ...current.outgoing]));
    return () => removeLocal(request.user.id);
  }
}

// ---------------------------------------------------------------- relationships

/// How the user stands with other players after actions taken on this phone
/// (optimistically, then confirmed). Screens read it over what the server
/// last said, so search, opponents and profiles agree right away. Cleared
/// when the Social tab reloads from the server.
final relationshipOverridesProvider =
    NotifierProvider<RelationshipOverrides, Map<String, Relationship>>(RelationshipOverrides.new);

class RelationshipOverrides extends Notifier<Map<String, Relationship>> {
  @override
  Map<String, Relationship> build() {
    ref.watch(currentUserIdProvider);
    return const {};
  }

  /// Sets [userId]'s relationship and returns how to restore the previous one.
  VoidCallback set(String userId, Relationship relationship) {
    final had = state.containsKey(userId);
    final previous = state[userId];
    state = {...state, userId: relationship};
    return () {
      final next = {...state};
      if (had) {
        next[userId] = previous!;
      } else {
        next.remove(userId);
      }
      state = next;
    };
  }

  void clear() => state = const {};
}

/// The relationship to show for [userId], given what the server said.
Relationship effectiveRelationship(
  Map<String, Relationship> overrides,
  String userId,
  Relationship fromServer,
) => overrides[userId] ?? fromServer;

// ---------------------------------------------------------------- rivals, opponents, activity

final rivalsProvider = FutureProvider<List<Opponent>>((ref) {
  ref.watch(currentUserIdProvider);
  return ref.watch(socialRepositoryProvider).rivals();
}, retry: _noAutoRetry);

final recentOpponentsProvider = FutureProvider<List<Opponent>>((ref) {
  ref.watch(currentUserIdProvider);
  return ref.watch(socialRepositoryProvider).opponents();
}, retry: _noAutoRetry);

@immutable
class ActivityState {
  const ActivityState({this.items = const [], this.nextCursor, this.loadingMore = false});

  final List<ActivityItem> items;
  final String? nextCursor;
  final bool loadingMore;

  bool get hasMore => nextCursor != null;
}

final activityProvider = AsyncNotifierProvider<ActivityController, ActivityState>(
  ActivityController.new,
  retry: _noAutoRetry,
);

class ActivityController extends AsyncNotifier<ActivityState> {
  @override
  Future<ActivityState> build() async {
    ref.watch(currentUserIdProvider);
    final page = await ref.watch(socialRepositoryProvider).activity();
    return ActivityState(items: List.unmodifiable(page.items), nextCursor: page.nextCursor);
  }

  Future<void> loadMore() async {
    final current = state.value;
    if (current == null || !current.hasMore || current.loadingMore) return;
    state = AsyncData(
      ActivityState(items: current.items, nextCursor: current.nextCursor, loadingMore: true),
    );
    try {
      final page = await ref.read(socialRepositoryProvider).activity(cursor: current.nextCursor);
      state = AsyncData(
        ActivityState(
          items: List.unmodifiable([...current.items, ...page.items]),
          nextCursor: page.nextCursor,
        ),
      );
    } on AppFailure {
      state = AsyncData(current);
      rethrow;
    }
  }
}

// ---------------------------------------------------------------- blocks

final blockedUsersProvider = AsyncNotifierProvider<BlockedUsersController, List<UserCard>>(
  BlockedUsersController.new,
  retry: _noAutoRetry,
);

class BlockedUsersController extends AsyncNotifier<List<UserCard>> {
  @override
  Future<List<UserCard>> build() {
    ref.watch(currentUserIdProvider);
    return ref.watch(socialRepositoryProvider).blocks();
  }

  VoidCallback? removeLocal(String userId) {
    final current = state.value;
    if (current == null || !current.any((u) => u.id == userId)) return null;
    state = AsyncData(List.unmodifiable(current.where((u) => u.id != userId)));
    return () => state = AsyncData(current);
  }

  VoidCallback? addLocal(UserCard user) {
    final current = state.value;
    if (current == null || current.any((u) => u.id == user.id)) return null;
    state = AsyncData(List.unmodifiable([user, ...current]));
    return () => removeLocal(user.id);
  }
}

// ---------------------------------------------------------------- profiles

/// A player's public profile by handle (`/u/:handle`).
final publicProfileProvider = FutureProvider.autoDispose.family<PublicProfile, String>((
  ref,
  handle,
) {
  ref.watch(currentUserIdProvider);
  return ref.watch(socialRepositoryProvider).profile(handle);
}, retry: _noAutoRetry);

// ---------------------------------------------------------------- actions

/// Every social action, applied optimistically to each list that shows the
/// player and rolled back if the server says no. Each method rethrows the
/// [AppFailure] so the screen can say what went wrong.
class SocialActions {
  SocialActions(this._ref);

  final Ref _ref;

  SocialRepository get _repo => _ref.read(socialRepositoryProvider);
  RelationshipOverrides get _relationships => _ref.read(relationshipOverridesProvider.notifier);

  // Lists that haven't loaded aren't touched (and so not fetched): they load
  // the new state from the server when they're first shown.
  FriendsController? get _friends =>
      _ref.exists(friendsProvider) ? _ref.read(friendsProvider.notifier) : null;
  FriendRequestsController? get _requests =>
      _ref.exists(friendRequestsProvider) ? _ref.read(friendRequestsProvider.notifier) : null;
  BlockedUsersController? get _blocks =>
      _ref.exists(blockedUsersProvider) ? _ref.read(blockedUsersProvider.notifier) : null;

  /// Sends a friend request. When they had already asked, the two meet and
  /// the result says [SentRequest.becameFriends].
  Future<SentRequest> addFriend(UserCard user) async {
    final undo = _relationships.set(user.id, Relationship.requested);
    try {
      final sent = await _repo.sendRequest(user.id);
      if (sent.becameFriends) {
        _relationships.set(user.id, Relationship.friend);
        _requests?.removeLocal(user.id);
        _friends?.addLocal(user);
      } else {
        _requests?.addOutgoing(
          FriendRequest(id: sent.requestId ?? 'pending:${user.id}', user: user),
        );
        // Without an id the list must come from the server to be cancellable.
        if (sent.requestId == null) _ref.invalidate(friendRequestsProvider);
      }
      return sent;
    } on AppFailure {
      undo();
      rethrow;
    }
  }

  /// Cancels the user's own pending request to [user].
  Future<void> cancelRequest(UserCard user) async {
    var request = _ref.read(friendRequestsProvider).value?.outgoingTo(user.id);
    if (request == null || request.id.startsWith('pending:')) {
      _ref.invalidate(friendRequestsProvider);
      request = (await _ref.read(friendRequestsProvider.future)).outgoingTo(user.id);
    }
    if (request == null) {
      // Nothing pending any more (accepted, declined or cancelled elsewhere).
      _relationships.set(user.id, Relationship.none);
      _ref.invalidate(friendsProvider);
      return;
    }
    final undoRelationship = _relationships.set(user.id, Relationship.none);
    final undoRequest = _requests?.removeLocal(user.id);
    try {
      await _repo.cancelRequest(request.id);
    } on AppFailure {
      undoRequest?.call();
      undoRelationship();
      rethrow;
    }
  }

  Future<void> accept(FriendRequest request) async {
    final undoRequest = _requests?.removeLocal(request.user.id);
    final undoFriend = _friends?.addLocal(request.user);
    final undoRelationship = _relationships.set(request.user.id, Relationship.friend);
    try {
      await _repo.acceptRequest(request.id);
      _ref.invalidate(activityProvider);
    } on AppFailure {
      undoRelationship();
      undoFriend?.call();
      undoRequest?.call();
      rethrow;
    }
  }

  Future<void> decline(FriendRequest request) async {
    final undo = _requests?.removeLocal(request.user.id);
    try {
      await _repo.declineRequest(request.id);
    } on AppFailure {
      undo?.call();
      rethrow;
    }
  }

  Future<void> removeFriend(UserCard user) async {
    final undoFriend = _friends?.removeLocal(user.id);
    final undoRelationship = _relationships.set(user.id, Relationship.none);
    try {
      await _repo.removeFriend(user.id);
    } on AppFailure {
      undoRelationship();
      undoFriend?.call();
      rethrow;
    }
  }

  /// Blocks [user]: they leave the friends list and requests, and every list
  /// hides them.
  Future<void> block(UserCard user) async {
    final undos = [
      _relationships.set(user.id, Relationship.blocked),
      ?_friends?.removeLocal(user.id),
      ?_requests?.removeLocal(user.id),
      ?_blocks?.addLocal(user),
    ];
    try {
      await _repo.block(user.id);
    } on AppFailure {
      for (final undo in undos.reversed) {
        undo();
      }
      rethrow;
    }
  }

  Future<void> unblock(UserCard user) async {
    final undoBlock = _blocks?.removeLocal(user.id);
    final undoRelationship = _relationships.set(user.id, Relationship.none);
    try {
      await _repo.unblock(user.id);
    } on AppFailure {
      undoRelationship();
      undoBlock?.call();
      rethrow;
    }
  }

  Future<void> report(
    UserCard user, {
    required ReportReason reason,
    String? note,
    String? matchId,
  }) => _repo.report(userId: user.id, reason: reason, note: note, matchId: matchId);
}

final socialActionsProvider = Provider<SocialActions>(SocialActions.new);

// ---------------------------------------------------------------- search

enum SearchStatus { idle, tooShort, loading, done, failed }

@immutable
class UserSearchState {
  const UserSearchState({
    this.query = '',
    this.status = SearchStatus.idle,
    this.results = const [],
    this.error,
  });

  /// The normalized query: lower case, without a leading `@`.
  final String query;
  final SearchStatus status;
  final List<SearchResult> results;
  final AppFailure? error;

  bool get active => query.isNotEmpty;
}

/// Handle search for the Social tab: at least [minLength] characters,
/// debounced, and a newer query cancels the one in flight.
final userSearchProvider = NotifierProvider<UserSearchController, UserSearchState>(
  UserSearchController.new,
);

class UserSearchController extends Notifier<UserSearchState> {
  static const minLength = 3;
  static const debounce = Duration(milliseconds: 350);

  Timer? _timer;
  CancelToken? _inFlight;
  var _generation = 0;

  @override
  UserSearchState build() {
    ref
      ..watch(currentUserIdProvider)
      ..onDispose(_stop);
    return const UserSearchState();
  }

  static String normalize(String raw) {
    var q = raw.trim().toLowerCase();
    if (q.startsWith('@')) q = q.substring(1);
    return q;
  }

  void setQuery(String raw) {
    final query = normalize(raw);
    if (query == state.query && state.status != SearchStatus.failed) return;
    _stop();
    if (query.isEmpty) {
      state = const UserSearchState();
    } else if (query.length < minLength) {
      state = UserSearchState(query: query, status: SearchStatus.tooShort);
    } else {
      state = UserSearchState(query: query, status: SearchStatus.loading, results: state.results);
      _timer = Timer(debounce, () => unawaited(_run(query)));
    }
  }

  /// Runs the current query again right away (after an error).
  Future<void> retry() async {
    if (state.query.length < minLength) return;
    _stop();
    state = UserSearchState(query: state.query, status: SearchStatus.loading);
    await _run(state.query);
  }

  void clear() {
    _stop();
    state = const UserSearchState();
  }

  Future<void> _run(String query) async {
    final generation = ++_generation;
    final token = _inFlight = CancelToken();
    try {
      final results = await ref.read(socialRepositoryProvider).search(query, cancelToken: token);
      if (generation != _generation) return;
      state = UserSearchState(query: query, status: SearchStatus.done, results: results);
    } on CancelledFailure {
      // A newer query took over.
    } on AppFailure catch (failure) {
      if (generation != _generation) return;
      state = UserSearchState(query: query, status: SearchStatus.failed, error: failure);
    } finally {
      if (identical(_inFlight, token)) _inFlight = null;
    }
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
    _generation++;
    _inFlight?.cancel();
    _inFlight = null;
  }
}
