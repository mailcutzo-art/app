import 'package:flutter/foundation.dart';

import '../../../core/auth/user.dart';
import '../../../core/network/json.dart';

/// Push categories a player can switch off (`GET /v1/me/settings/notifications` `kinds`).
enum NotificationKind {
  invites('invites', 'Invites', 'Duel and room invites'),
  tournaments('tournaments', 'Tournaments', 'Check-in, rounds and results'),
  friends('friends', 'Friends', 'Friend requests and new friends'),
  missions('missions', 'Missions', 'Daily missions and rewards'),
  streaks('streaks', 'Streaks', 'Reminders before a streak ends');

  const NotificationKind(this.wire, this.label, this.description);

  final String wire;
  final String label;
  final String description;
}

/// A time of day as the server writes it: `"22:30"`.
@immutable
class DayTime {
  const DayTime(this.hour, this.minute);

  factory DayTime.parse(String value) {
    final match = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(value.trim());
    final hour = int.tryParse(match?.group(1) ?? '');
    final minute = int.tryParse(match?.group(2) ?? '');
    if (hour == null || minute == null || hour > 23 || minute > 59) {
      throw FormatException('"$value" is not a time of day');
    }
    return DayTime(hour, minute);
  }

  final int hour;
  final int minute;

  String get wire => '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';

  @override
  bool operator ==(Object other) =>
      other is DayTime && other.hour == hour && other.minute == minute;

  @override
  int get hashCode => Object.hash(hour, minute);

  @override
  String toString() => wire;
}

/// `{"kinds": {...}, "quiet_hours": {"start": "22:30", "end": "07:00"}}`. Quiet hours are IST:
/// notifications then go to the inbox without a push.
@immutable
class NotificationSettings {
  const NotificationSettings({
    this.kinds = const {},
    this.quietStart = defaultQuietStart,
    this.quietEnd = defaultQuietEnd,
  });

  factory NotificationSettings.fromJson(Object? json) {
    final r = JsonReader(json, 'notification settings');
    final kinds = JsonReader(r['kinds'] ?? const <String, Object?>{}, 'notification kinds');
    final quiet = r['quiet_hours'] is Map ? JsonReader(r['quiet_hours'], 'quiet hours') : null;
    return NotificationSettings(
      kinds: {
        for (final kind in NotificationKind.values) kind: kinds.flag(kind.wire, fallback: true),
      },
      quietStart: switch (quiet?.optString('start')) {
        final start? => DayTime.parse(start),
        null => defaultQuietStart,
      },
      quietEnd: switch (quiet?.optString('end')) {
        final end? => DayTime.parse(end),
        null => defaultQuietEnd,
      },
    );
  }

  static const defaultQuietStart = DayTime(22, 30);
  static const defaultQuietEnd = DayTime(7, 0);

  final Map<NotificationKind, bool> kinds;
  final DayTime quietStart;
  final DayTime quietEnd;

  /// Kinds the server didn't mention are on.
  bool isOn(NotificationKind kind) => kinds[kind] ?? true;

  NotificationSettings withKind(NotificationKind kind, {required bool on}) =>
      NotificationSettings(kinds: {...kinds, kind: on}, quietStart: quietStart, quietEnd: quietEnd);

  NotificationSettings withQuietHours({DayTime? start, DayTime? end}) => NotificationSettings(
    kinds: kinds,
    quietStart: start ?? quietStart,
    quietEnd: end ?? quietEnd,
  );

  Map<String, Object?> toJson() => {
    'kinds': {for (final kind in NotificationKind.values) kind.wire: isOn(kind)},
    'quiet_hours': {'start': quietStart.wire, 'end': quietEnd.wire},
  };
}

/// Who can send friend requests.
enum FriendRequestsFrom {
  everyone('everyone', 'Everyone'),
  playedWith('played_with', 'People I\'ve played'),
  nobody('nobody', 'Nobody');

  const FriendRequestsFrom(this.wire, this.label);

  final String wire;
  final String label;
}

/// Who can challenge me to a duel.
enum ChallengesFrom {
  everyone('everyone', 'Everyone'),
  friends('friends', 'Friends'),
  nobody('nobody', 'Nobody');

  const ChallengesFrom(this.wire, this.label);

  final String wire;
  final String label;
}

/// Who sees whether I'm online.
enum PresenceTo {
  friends('friends', 'Friends'),
  nobody('nobody', 'Nobody');

  const PresenceTo(this.wire, this.label);

  final String wire;
  final String label;
}

T _choice<T extends Enum>(List<T> values, String Function(T) wire, Object? value, T fallback) =>
    values.where((v) => wire(v) == value).firstOrNull ?? fallback;

/// `GET /v1/me/settings/privacy`. Minors start with the safest options.
@immutable
class PrivacySettings {
  const PrivacySettings({
    this.friendRequests = FriendRequestsFrom.everyone,
    this.challenges = ChallengesFrom.friends,
    this.presence = PresenceTo.friends,
    this.publicBoards = true,
  });

  factory PrivacySettings.fromJson(Object? json) {
    final r = JsonReader(json, 'privacy settings');
    return PrivacySettings(
      friendRequests: _choice(
        FriendRequestsFrom.values,
        (v) => v.wire,
        r['friend_requests'],
        FriendRequestsFrom.playedWith,
      ),
      challenges: _choice(
        ChallengesFrom.values,
        (v) => v.wire,
        r['challenges'],
        ChallengesFrom.friends,
      ),
      presence: _choice(PresenceTo.values, (v) => v.wire, r['presence'], PresenceTo.friends),
      publicBoards: r.flag('public_boards', fallback: true),
    );
  }

  final FriendRequestsFrom friendRequests;
  final ChallengesFrom challenges;
  final PresenceTo presence;

  /// Whether the player appears on public leaderboards.
  final bool publicBoards;

  PrivacySettings copyWith({
    FriendRequestsFrom? friendRequests,
    ChallengesFrom? challenges,
    PresenceTo? presence,
    bool? publicBoards,
  }) => PrivacySettings(
    friendRequests: friendRequests ?? this.friendRequests,
    challenges: challenges ?? this.challenges,
    presence: presence ?? this.presence,
    publicBoards: publicBoards ?? this.publicBoards,
  );

  Map<String, Object?> toJson() => {
    'friend_requests': friendRequests.wire,
    'challenges': challenges.wire,
    'presence': presence.wire,
    'public_boards': publicBoards,
  };
}

/// `GET /v1/me/settings/app`: settings the server needs to know about.
@immutable
class AppSettings {
  const AppSettings({this.analytics = true});

  factory AppSettings.fromJson(Object? json) {
    final r = JsonReader(json, 'app settings');
    return AppSettings(analytics: r.flag('analytics', fallback: true));
  }

  /// Whether this player's screen events are recorded (minors' never carry their id).
  final bool analytics;

  Map<String, Object?> toJson() => {'analytics': analytics};
}

/// A signed-in device (`GET /v1/me/sessions`).
@immutable
class DeviceSession {
  const DeviceSession({
    required this.id,
    required this.platform,
    required this.appVersion,
    required this.createdAt,
    required this.lastSeenAt,
    this.current = false,
  });

  factory DeviceSession.fromJson(Object? json) {
    final r = JsonReader(json, 'session');
    return DeviceSession(
      id: r.string('id'),
      platform: r.string('platform'),
      appVersion: r.string('app_version'),
      createdAt: r.dateTime('created_at'),
      lastSeenAt: r.dateTime('last_seen_at'),
      current: r.flag('current'),
    );
  }

  final String id;
  final String platform;
  final String appVersion;
  final DateTime createdAt;
  final DateTime lastSeenAt;

  /// This phone.
  final bool current;

  /// "Android", "iOS", "Web".
  String get platformLabel => switch (platform) {
    'android' => 'Android',
    'ios' => 'iPhone',
    'web' => 'Web',
    final other when other.isNotEmpty => other[0].toUpperCase() + other.substring(1),
    _ => 'Unknown device',
  };
}

/// What a feedback message is about (`POST /v1/feedback` `kind`).
enum FeedbackKind {
  problem('problem', 'Report a problem'),
  idea('idea', 'Suggest an idea'),
  coins('coins', 'Coins or rewards'),
  banAppeal('ban_appeal', 'Appeal a restriction');

  const FeedbackKind(this.wire, this.label);

  final String wire;
  final String label;
}

/// A fresh sign-in proof for deleting the account: `{"provider": "google", "id_token": "…"}`,
/// or `{"provider": "dev"}` in development builds.
@immutable
class SignInProof {
  const SignInProof.google(String this.idToken) : provider = 'google';

  const SignInProof.dev() : provider = 'dev', idToken = null;

  final String provider;
  final String? idToken;

  Map<String, Object?> toJson() => {'provider': provider, 'id_token': ?idToken};
}

/// The editable parts of the profile, for `PATCH /v1/me`. Only the fields that changed are sent.
@immutable
class ProfilePatch {
  const ProfilePatch({this.displayName, this.handle, this.avatar, this.goal});

  final String? displayName;
  final String? handle;
  final Avatar? avatar;
  final Goal? goal;

  bool get isEmpty => displayName == null && handle == null && avatar == null && goal == null;

  Map<String, Object?> toJson() => {
    'display_name': ?displayName,
    'handle': ?handle,
    'avatar': ?avatar?.toJson(),
    'goal': ?goal?.name,
  };
}
