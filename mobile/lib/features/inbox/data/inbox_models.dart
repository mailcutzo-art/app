import 'package:design_system/design_system.dart';
import 'package:flutter/foundation.dart';
import 'package:realtime_client/realtime_client.dart';

import '../../../app/router.dart';
import '../../../core/network/json.dart';

/// Where tapping something should take the app (`{"route", "params"}` in `docs/api-play.md`).
@immutable
class AppAction {
  const AppAction({required this.route, this.params = const {}});

  factory AppAction.fromJson(Object? json) {
    final r = JsonReader(json, 'action');
    final route = r.string('route');
    if (!route.startsWith('/')) throw FormatException('action: "$route" is not an app route');
    return AppAction(route: route, params: r.stringMap('params'));
  }

  /// An app path such as `/battle` or `/arena/T1`.
  final String route;

  /// Query parameters for the route, e.g. `{"subject": "physics"}`.
  final Map<String, String> params;

  /// The location to open: the route with its params as the query.
  String get location =>
      Uri(path: route, queryParameters: params.isEmpty ? null : params).toString();

  /// A tab's own page (optionally with a query) is switched to; anything else opens on top, so
  /// Back returns to where the user was.
  bool get opensTab => Routes.tabs.contains(route);

  Map<String, Object?> toJson() => {'route': route, 'params': params};

  @override
  bool operator ==(Object other) =>
      other is AppAction && other.route == route && mapEquals(other.params, params);

  @override
  int get hashCode =>
      Object.hash(route, Object.hashAllUnordered([for (final e in params.entries) '$e']));
}

/// One inbox item (`GET /v1/me/notifications`).
@immutable
class InboxItem {
  const InboxItem({
    required this.id,
    required this.kind,
    required this.title,
    required this.createdAt,
    this.body,
    this.icon,
    this.action,
    this.read = false,
  });

  factory InboxItem.fromJson(Object? json) {
    final r = JsonReader(json, 'notification');
    return InboxItem(
      id: r.string('id'),
      kind: r.string('kind'),
      title: r.string('title'),
      body: r.optString('body'),
      icon: r.optString('icon'),
      action: _lenientAction(r['action']),
      createdAt: r.dateTime('created_at'),
      read: r.flag('read'),
    );
  }

  /// A `notify` event from the realtime connection, as the inbox shows it.
  factory InboxItem.fromNotify(NotifyEvent event, {required DateTime receivedAt}) => InboxItem(
    id: event.id,
    kind: event.kind,
    title: event.title,
    body: event.body,
    icon: event.icon,
    action: switch (event.action) {
      final action? => _lenientAction({'route': action.route, 'params': action.params}),
      null => null,
    },
    createdAt: receivedAt,
  );

  final String id;

  /// `invite`, `tournament_round`, `refund`, `level_up`, … (see `docs/api-play.md`).
  final String kind;
  final String title;
  final String? body;

  /// The server's icon name, if it picked one; otherwise the kind decides.
  final String? icon;

  /// Where tapping goes; null for items that only inform.
  final AppAction? action;
  final DateTime createdAt;
  final bool read;

  InboxItem copyWith({bool? read}) => InboxItem(
    id: id,
    kind: kind,
    title: title,
    body: body,
    icon: icon,
    action: action,
    createdAt: createdAt,
    read: read ?? this.read,
  );

  /// The icon and colour of the row.
  (HugeIconData, PastelTone) get look => inboxLook(kind: kind, icon: icon);
}

/// An action the app can't read is dropped; the item still shows.
AppAction? _lenientAction(Object? json) {
  if (json == null) return null;
  try {
    return AppAction.fromJson(json);
  } on FormatException catch (e) {
    debugPrint('Ignoring an unreadable inbox action: $e');
    return null;
  }
}

/// Icon and tone for an inbox item: the server's [icon] name when the app knows it, otherwise
/// one per group of kinds.
(HugeIconData, PastelTone) inboxLook({required String kind, String? icon}) {
  final named = switch (icon) {
    'coins' => AppIcons.coins,
    'trophy' || 'arena' => AppIcons.arena,
    'medal' => AppIcons.medal,
    'award' => AppIcons.award,
    'crown' => AppIcons.crown,
    'fire' || 'streak' => AppIcons.fire,
    'star' => AppIcons.star,
    'user' || 'friend' => AppIcons.userAdd,
    'battle' => AppIcons.battle,
    'target' || 'mission' => AppIcons.target,
    'shield' => AppIcons.shield,
    'bell' => AppIcons.notification,
    _ => null,
  };
  final (fallback, tone) = switch (kind) {
    'invite' => (AppIcons.battle, PastelTone.sky),
    'friend_request' || 'friend_accepted' => (AppIcons.userAdd, PastelTone.sky),
    final k when k.startsWith('tournament_') => (AppIcons.arena, PastelTone.lavender),
    'refund' || 'prize' => (AppIcons.coins, PastelTone.lemon),
    'match_forfeit' || 'match_aborted' || 'match_settled' => (AppIcons.battle, PastelTone.peach),
    'mission_done' => (AppIcons.target, PastelTone.mint),
    'level_up' ||
    'achievement' ||
    'rank_milestone' ||
    'weekly_result' => (AppIcons.award, PastelTone.lime),
    'streak_risk' || 'streak_freeze_used' || 'streak_lost' => (AppIcons.fire, PastelTone.peach),
    'question_report' => (AppIcons.checklist, PastelTone.neutral),
    'account' => (AppIcons.shield, PastelTone.rose),
    _ => (AppIcons.notification, PastelTone.neutral),
  };
  return (named ?? fallback, tone);
}
