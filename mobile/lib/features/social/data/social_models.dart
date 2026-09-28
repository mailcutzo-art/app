import 'package:flutter/foundation.dart';

import '../../../core/auth/user.dart';
import '../../../core/network/json.dart';
import '../../battle/data/battle_models.dart' show RatingInfo;

/// Another player, as every social list shows them (the "user card" shape in
/// `docs/api-play.md`).
@immutable
class UserCard {
  const UserCard({
    required this.id,
    required this.handle,
    required this.displayName,
    this.avatar = Avatar.fallback,
    this.level,
  });

  /// Throws [FormatException] without an id, handle or name.
  factory UserCard.fromJson(Object? json) {
    final r = JsonReader(json, 'user card');
    return UserCard(
      id: r.string('id'),
      handle: r.string('handle'),
      displayName: r.string('display_name'),
      avatar: Avatar.parse(r['avatar']),
      level: _int(r['level']),
    );
  }

  /// Reads the card of a list item that either is a card or nests one under
  /// `user`, so `{"user": {...}, "presence": "online"}` and a flat card with
  /// `presence` read the same.
  factory UserCard.fromItem(Object? json) => switch (json) {
    {'user': final Map<Object?, Object?> user} => UserCard.fromJson(user),
    _ => UserCard.fromJson(json),
  };

  final String id;
  final String handle;
  final String displayName;
  final Avatar avatar;
  final int? level;

  String get at => '@$handle';

  Map<String, Object?> toJson() => {
    'id': id,
    'handle': handle,
    'display_name': displayName,
    'avatar': avatar.toJson(),
    'level': ?level,
  };

  @override
  bool operator ==(Object other) =>
      other is UserCard &&
      other.id == id &&
      other.handle == handle &&
      other.displayName == displayName &&
      other.avatar == avatar &&
      other.level == level;

  @override
  int get hashCode => Object.hash(id, handle, displayName, avatar, level);
}

/// Where a friend is right now. Friends only; polled while the Social tab shows.
enum FriendPresence {
  online('online', 'Online'),
  inBattle('in_battle', 'In a battle'),
  inTournament('in_tournament', 'In a tournament'),
  offline('offline', 'Offline');

  const FriendPresence(this.wire, this.label);

  final String wire;
  final String label;

  /// Unknown or missing values read as [offline].
  static FriendPresence parse(Object? value) =>
      values.where((p) => p.wire == value).firstOrNull ?? offline;

  /// Sort order: online first, then busy, then offline.
  int get rank => switch (this) {
    online => 0,
    inBattle || inTournament => 1,
    offline => 2,
  };

  bool get isBusy => this == inBattle || this == inTournament;
}

/// How the signed-in user stands with another player.
enum Relationship {
  none('none'),
  friend('friend'),

  /// The user has sent them a friend request that is still pending.
  requested('requested'),
  blocked('blocked');

  const Relationship(this.wire);

  final String wire;

  /// Unknown or missing values read as [none].
  static Relationship parse(Object? value) =>
      values.where((r) => r.wire == value).firstOrNull ?? none;
}

/// A head-to-head record against one player.
@immutable
class HeadToHead {
  const HeadToHead({this.wins = 0, this.losses = 0, this.draws = 0});

  /// Null when [json] isn't a record.
  static HeadToHead? tryParse(Object? json) {
    if (json is! Map) return null;
    return HeadToHead(
      wins: _int(json['wins']) ?? 0,
      losses: _int(json['losses']) ?? 0,
      draws: _int(json['draws']) ?? 0,
    );
  }

  final int wins;
  final int losses;
  final int draws;

  int get played => wins + losses + draws;

  /// "3W · 1L · 0D".
  String get short => '${wins}W · ${losses}L · ${draws}D';

  /// "You lead 3–1", "They lead 2–1" or "Level at 2–2".
  String get summary {
    if (played == 0) return 'No games yet';
    if (wins > losses) return 'You lead $wins–$losses';
    if (losses > wins) return 'They lead $losses–$wins';
    return 'Level at $wins–$losses';
  }

  Map<String, int> toJson() => {'wins': wins, 'losses': losses, 'draws': draws};

  @override
  bool operator ==(Object other) =>
      other is HeadToHead && other.wins == wins && other.losses == losses && other.draws == draws;

  @override
  int get hashCode => Object.hash(wins, losses, draws);
}

/// A friend with where they are right now.
@immutable
class Friend {
  const Friend({required this.user, this.presence = FriendPresence.offline});

  factory Friend.fromJson(Object? json) {
    final r = JsonReader(json, 'friend');
    return Friend(user: UserCard.fromItem(json), presence: FriendPresence.parse(r['presence']));
  }

  final UserCard user;
  final FriendPresence presence;

  Friend withPresence(FriendPresence presence) => Friend(user: user, presence: presence);
}

/// A pending friend request, incoming or outgoing.
@immutable
class FriendRequest {
  const FriendRequest({required this.id, required this.user, this.createdAt});

  factory FriendRequest.fromJson(Object? json) {
    final r = JsonReader(json, 'friend request');
    // The other person: `user`, or `from`/`to` depending on the direction.
    final other = r['user'] ?? r['from'] ?? r['to'];
    return FriendRequest(
      id: r.string('id'),
      user: UserCard.fromJson(other),
      createdAt: DateTime.tryParse(r['created_at'] is String ? r['created_at']! as String : ''),
    );
  }

  final String id;
  final UserCard user;
  final DateTime? createdAt;
}

/// `GET /v1/me/friend-requests`.
@immutable
class FriendRequests {
  const FriendRequests({this.incoming = const [], this.outgoing = const []});

  factory FriendRequests.fromJson(Object? json) {
    final r = JsonReader(json, 'friend requests');
    return FriendRequests(
      incoming: _lenientList(r['incoming'], FriendRequest.fromJson),
      outgoing: _lenientList(r['outgoing'], FriendRequest.fromJson),
    );
  }

  final List<FriendRequest> incoming;
  final List<FriendRequest> outgoing;

  bool get isEmpty => incoming.isEmpty && outgoing.isEmpty;

  FriendRequest? incomingFrom(String userId) =>
      incoming.where((r) => r.user.id == userId).firstOrNull;

  FriendRequest? outgoingTo(String userId) =>
      outgoing.where((r) => r.user.id == userId).firstOrNull;

  FriendRequests copyWith({List<FriendRequest>? incoming, List<FriendRequest>? outgoing}) =>
      FriendRequests(
        incoming: List.unmodifiable(incoming ?? this.incoming),
        outgoing: List.unmodifiable(outgoing ?? this.outgoing),
      );
}

/// What `POST /v1/friend-requests` did. The body may carry the new request's
/// `id`, and `status: "accepted"` when the other player had already asked
/// (the two requests meet and become a friendship).
@immutable
class SentRequest {
  const SentRequest({this.requestId, this.becameFriends = false});

  factory SentRequest.fromJson(Object? json) {
    if (json is! Map) return const SentRequest();
    return SentRequest(
      requestId: json['id'] is String ? json['id']! as String : null,
      becameFriends: json['status'] == 'accepted' || json['relationship'] == 'friend',
    );
  }

  final String? requestId;
  final bool becameFriends;
}

/// A player the user keeps meeting, or met recently, with the record between them.
@immutable
class Opponent {
  const Opponent({
    required this.user,
    this.h2h = const HeadToHead(),
    this.relationship = Relationship.none,
    this.lastPlayedAt,
  });

  factory Opponent.fromJson(Object? json) {
    final r = JsonReader(json, 'opponent');
    final last = r['last_played_at'];
    return Opponent(
      user: UserCard.fromItem(json),
      h2h: HeadToHead.tryParse(r['h2h']) ?? const HeadToHead(),
      relationship: Relationship.parse(r['relationship']),
      lastPlayedAt: last is String ? DateTime.tryParse(last) : null,
    );
  }

  final UserCard user;
  final HeadToHead h2h;
  final Relationship relationship;
  final DateTime? lastPlayedAt;
}

/// A player found by handle, with how the user stands with them.
@immutable
class SearchResult {
  const SearchResult({required this.user, this.relationship = Relationship.none});

  factory SearchResult.fromJson(Object? json) {
    final r = JsonReader(json, 'search result');
    return SearchResult(
      user: UserCard.fromItem(json),
      relationship: Relationship.parse(r['relationship']),
    );
  }

  final UserCard user;
  final Relationship relationship;
}

/// What a friend did that the feed shows.
enum ActivityKind {
  achievement('achievement'),
  podium('podium'),
  levelUp('level_up'),
  streak('streak'),
  win('win'),
  other('other');

  const ActivityKind(this.wire);

  final String wire;

  static ActivityKind parse(Object? value) =>
      values.where((k) => k.wire == value).firstOrNull ?? other;
}

/// One entry of the friends' activity feed (`GET /v1/me/activity`).
@immutable
class ActivityItem {
  const ActivityItem({
    required this.id,
    required this.user,
    required this.kind,
    required this.text,
    required this.createdAt,
  });

  /// The server may send the sentence (`title`); otherwise it is written from
  /// the kind and its `data` (`level`, `days`, `position`, `name`).
  factory ActivityItem.fromJson(Object? json) {
    final r = JsonReader(json, 'activity item');
    final kind = ActivityKind.parse(r['kind']);
    final data = r['data'] is Map ? r['data']! as Map : const <String, Object?>{};
    final title = r['title'] ?? r['text'];
    return ActivityItem(
      id: r.string('id'),
      user: UserCard.fromJson(r['user']),
      kind: kind,
      text: title is String && title.isNotEmpty ? title : _describe(kind, data),
      createdAt: r.dateTime('created_at'),
    );
  }

  final String id;
  final UserCard user;
  final ActivityKind kind;

  /// What happened, without the player's name: "reached level 8".
  final String text;
  final DateTime createdAt;

  static String _describe(ActivityKind kind, Map<dynamic, dynamic> data) {
    final name = data['name'] is String ? data['name'] as String : null;
    return switch (kind) {
      ActivityKind.levelUp when _int(data['level']) != null =>
        'reached level ${_int(data['level'])}',
      ActivityKind.levelUp => 'levelled up',
      ActivityKind.streak when _int(data['days']) != null =>
        'is on a ${_int(data['days'])}-day streak',
      ActivityKind.streak => 'is on a streak',
      ActivityKind.podium when _int(data['position']) != null && name != null =>
        'finished #${_int(data['position'])} in $name',
      ActivityKind.podium => 'finished on the podium',
      ActivityKind.achievement when name != null => 'earned “$name”',
      ActivityKind.achievement => 'earned an achievement',
      ActivityKind.win when name != null => 'won $name',
      ActivityKind.win => 'won a battle',
      ActivityKind.other => 'did something great',
    };
  }
}

/// A rating in one scope on a public profile.
@immutable
class ScopedRating {
  const ScopedRating({required this.scope, required this.rating, this.position});

  factory ScopedRating.fromJson(Object? json) {
    final r = JsonReader(json, 'profile rating');
    return ScopedRating(
      scope: r.string('scope'),
      rating: RatingInfo.fromJson(r['rating']),
      position: _int(r['position']),
    );
  }

  /// A subject slug (`physics`) or `goal:subject` (`neet:physics`).
  final String scope;
  final RatingInfo rating;
  final int? position;

  /// "Physics" for `physics` or `neet:physics`, "Overall" for `overall`.
  String get label {
    final last = scope.split(':').last.replaceAll('_', ' ').replaceAll('-', ' ');
    if (last.isEmpty) return scope;
    return last[0].toUpperCase() + last.substring(1);
  }
}

/// One result in a player's recent form.
enum FormResult {
  win('W', 'Win'),
  loss('L', 'Loss'),
  draw('D', 'Draw');

  const FormResult(this.letter, this.label);

  final String letter;
  final String label;

  /// Accepts `"W"`, `"win"`, `"won"`… or `{"result": "win"}`; null otherwise.
  static FormResult? tryParse(Object? value) {
    final raw = switch (value) {
      {'result': final Object? result} => result,
      {'outcome': final Object? outcome} => outcome,
      _ => value,
    };
    if (raw is! String) return null;
    return switch (raw.toLowerCase()) {
      'w' || 'win' || 'won' => win,
      'l' || 'loss' || 'lost' || 'lose' => loss,
      'd' || 'draw' || 'drew' || 'tie' => draw,
      _ => null,
    };
  }
}

/// `GET /v1/users/{handle}`. For a minor who isn't a friend, the server
/// leaves out ratings, form and head-to-head; those read as absent here.
@immutable
class PublicProfile {
  const PublicProfile({
    required this.user,
    this.ratings,
    this.form,
    this.h2h,
    this.relationship = Relationship.none,
    this.canChallenge = false,
  });

  factory PublicProfile.fromJson(Object? json) {
    final r = JsonReader(json, 'public profile');
    final ratings = r['ratings'];
    final form = r['form'];
    return PublicProfile(
      user: UserCard.fromItem(json),
      ratings: ratings is List ? _lenientList(ratings, ScopedRating.fromJson) : null,
      form: form is List
          ? List.unmodifiable([for (final item in form) ?FormResult.tryParse(item)])
          : null,
      h2h: HeadToHead.tryParse(r['h2h']),
      relationship: Relationship.parse(r['relationship']),
      canChallenge: r['can_challenge'] == true,
    );
  }

  final UserCard user;

  /// Null when the server keeps them private.
  final List<ScopedRating>? ratings;

  /// Up to the last 5 results, oldest first; null when private.
  final List<FormResult>? form;

  /// The user's record against this player; null when private.
  final HeadToHead? h2h;
  final Relationship relationship;
  final bool canChallenge;

  /// Only the card (name, avatar, level) is shown.
  bool get isLimited => ratings == null && form == null && h2h == null;
}

/// A page of a cursor-paginated list.
@immutable
class CursorPage<T> {
  const CursorPage(this.items, {this.nextCursor});

  /// Reads `{"items", "next_cursor"}`, or a bare list. Items that can't be
  /// read are skipped rather than failing the whole list.
  factory CursorPage.fromJson(Object? json, T Function(Object? json) item) => switch (json) {
    final List<Object?> list => CursorPage(_lenientList(list, item)),
    {'items': final Object? items} && final Map<Object?, Object?> map => CursorPage(
      _lenientList(items, item),
      nextCursor: map['next_cursor'] is String ? map['next_cursor']! as String : null,
    ),
    _ => throw const FormatException('page: expected {"items": [...]}'),
  };

  final List<T> items;
  final String? nextCursor;
}

/// Why a player is reported (`POST /v1/reports`).
enum ReportReason {
  cheating('cheating', 'Cheating', 'Using help or tools during a game'),
  offensiveName('offensive_name', 'Offensive name', 'Their name or handle is inappropriate'),
  harassment('harassment', 'Harassment', 'Unwanted invites or requests'),
  other('other', 'Something else', 'Tell us a little more below');

  const ReportReason(this.wire, this.label, this.hint);

  final String wire;
  final String label;
  final String hint;
}

int? _int(Object? value) => switch (value) {
  final int v => v,
  final double v when v.isFinite => v.round(),
  final String v => int.tryParse(v),
  _ => null,
};

List<T> _lenientList<T>(Object? value, T Function(Object? json) parse) {
  if (value is! List) return List<T>.unmodifiable(const []);
  final out = <T>[];
  for (final item in value) {
    try {
      out.add(parse(item));
    } on FormatException catch (e) {
      debugPrint('Skipping unreadable item: $e');
    }
  }
  return List.unmodifiable(out);
}
