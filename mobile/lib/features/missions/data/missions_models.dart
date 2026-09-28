import 'package:flutter/foundation.dart';

import '../../../core/network/json.dart';

/// Where tapping something should take the app: `{"route", "params"}`.
@immutable
class AppAction {
  const AppAction({required this.route, this.params = const {}});

  factory AppAction.fromJson(Object? json) {
    final r = JsonReader(json, 'action');
    return AppAction(route: r.string('route'), params: r.stringMap('params'));
  }

  final String route;
  final Map<String, String> params;

  /// The in-app location, e.g. `/battle?subject=physics`.
  String get location =>
      Uri(path: route, queryParameters: params.isEmpty ? null : params).toString();

  Map<String, Object?> toJson() => {'route': route, 'params': params};
}

/// One of the day's three missions.
@immutable
class Mission {
  const Mission({
    required this.id,
    required this.title,
    required this.progress,
    required this.target,
    required this.xp,
    this.done = false,
    this.action,
  });

  factory Mission.fromJson(Object? json) {
    final r = JsonReader(json, 'mission');
    final target = r.integer('target');
    final progress = r.integer('progress');
    return Mission(
      id: r.string('id'),
      title: r.string('title'),
      progress: progress,
      target: target,
      xp: r.optInt('xp') ?? 0,
      done: r.flag('done', fallback: target > 0 && progress >= target),
      action: _tryAction(r['action']),
    );
  }

  final String id;
  final String title;
  final int progress;
  final int target;
  final int xp;
  final bool done;
  final AppAction? action;

  /// 0 to 1, for progress bars.
  double get fraction => done ? 1 : (target <= 0 ? 0 : (progress / target).clamp(0, 1).toDouble());

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'progress': progress,
    'target': target,
    'xp': xp,
    'done': done,
    'action': action?.toJson(),
  };
}

/// The reward for finishing all three.
@immutable
class MissionBonus {
  const MissionBonus({required this.xp, required this.coins, this.done = false});

  static const standard = MissionBonus(xp: 100, coins: 25);

  factory MissionBonus.fromJson(Object? json) {
    final r = JsonReader(json, 'missions bonus');
    return MissionBonus(
      xp: r.optInt('xp') ?? standard.xp,
      coins: r.optInt('coins') ?? standard.coins,
      done: r.flag('done'),
    );
  }

  final int xp;
  final int coins;
  final bool done;

  Map<String, Object?> toJson() => {'xp': xp, 'coins': coins, 'done': done};
}

/// The streak as Home and Missions show it: the flame and day count.
@immutable
class StreakSummary {
  const StreakSummary({required this.days, this.todayDone = false, this.freezes = 0});

  static const none = StreakSummary(days: 0);

  factory StreakSummary.fromJson(Object? json) {
    final r = JsonReader(json, 'streak');
    return StreakSummary(
      days: r.optInt('days') ?? 0,
      todayDone: r.flag('today_done'),
      freezes: r.optInt('freezes') ?? 0,
    );
  }

  final int days;
  final bool todayDone;

  /// Freezes held (at most 2).
  final int freezes;

  Map<String, Object?> toJson() => {'days': days, 'today_done': todayDone, 'freezes': freezes};
}

/// `GET /v1/me/missions`, the same shape as Home's `missions` section.
@immutable
class MissionsDay {
  const MissionsDay({
    required this.day,
    required this.items,
    this.bonus = MissionBonus.standard,
    this.streak = StreakSummary.none,
    this.swapsLeft = 1,
  });

  /// Throws [FormatException] when `items` is missing; missions that can't be
  /// read are skipped.
  factory MissionsDay.fromJson(Object? json) {
    final r = JsonReader(json, 'missions');
    if (r['items'] is! List) throw const FormatException('missions: "items" must be a list');
    final items = <Mission>[];
    for (final item in r['items']! as List) {
      try {
        items.add(Mission.fromJson(item));
      } on FormatException catch (e) {
        debugPrint('Skipping unreadable mission: $e');
      }
    }
    return MissionsDay(
      day: r.optString('day') ?? '',
      items: List.unmodifiable(items),
      bonus: r.optObject('bonus', MissionBonus.fromJson) ?? MissionBonus.standard,
      streak: r.optObject('streak', StreakSummary.fromJson) ?? StreakSummary.none,
      swapsLeft: r.optInt('swaps_left') ?? 1,
    );
  }

  /// The IST day, `2026-09-27`.
  final String day;
  final List<Mission> items;
  final MissionBonus bonus;
  final StreakSummary streak;

  /// Free swaps left today (one a day).
  final int swapsLeft;

  int get doneCount => items.where((m) => m.done).length;
  bool get allDone => items.isNotEmpty && doneCount == items.length;

  /// "Start recommended mission": the first one not yet done.
  Mission? get recommended => items.where((m) => !m.done && m.action != null).firstOrNull;

  MissionsDay copyWith({List<Mission>? items, StreakSummary? streak, int? swapsLeft}) =>
      MissionsDay(
        day: day,
        items: items ?? this.items,
        bonus: bonus,
        streak: streak ?? this.streak,
        swapsLeft: swapsLeft ?? this.swapsLeft,
      );

  Map<String, Object?> toJson() => {
    'day': day,
    'items': [for (final item in items) item.toJson()],
    'bonus': bonus.toJson(),
    'streak': streak.toJson(),
    'swaps_left': swapsLeft,
  };
}

/// How a day of the streak calendar went.
enum StreakDayState {
  active,
  frozen,
  missed;

  static StreakDayState parse(Object? value) => switch (value) {
    'active' => active,
    'frozen' => frozen,
    _ => missed,
  };
}

@immutable
class StreakDay {
  const StreakDay({required this.day, required this.state});

  factory StreakDay.fromJson(Object? json) {
    final r = JsonReader(json, 'streak day');
    final day = DateTime.tryParse(r.string('day'));
    if (day == null) throw const FormatException('streak day: "day" must be a date');
    return StreakDay(
      day: DateTime.utc(day.year, day.month, day.day),
      state: StreakDayState.parse(r['state']),
    );
  }

  /// The IST calendar day (as a UTC date with no time).
  final DateTime day;
  final StreakDayState state;
}

/// `GET /v1/me/streak?days=30`.
@immutable
class StreakCalendar {
  const StreakCalendar({
    required this.days,
    required this.best,
    required this.freezes,
    required this.calendar,
    this.todayDone = false,
    this.maxFreezes = 2,
    this.freezePrice = 50,
    this.coins,
  });

  factory StreakCalendar.fromJson(Object? json) {
    final r = JsonReader(json, 'streak');
    final calendar = r.list('calendar', StreakDay.fromJson).toList()
      ..sort((a, b) => a.day.compareTo(b.day));
    return StreakCalendar(
      days: r.integer('days'),
      best: r.optInt('best') ?? r.integer('days'),
      freezes: r.optInt('freezes') ?? 0,
      calendar: List.unmodifiable(calendar),
      todayDone: r.flag('today_done'),
      maxFreezes: r.optInt('max_freezes') ?? 2,
      freezePrice: r.optInt('freeze_price') ?? 50,
      coins: r.optInt('coins'),
    );
  }

  /// The current streak.
  final int days;
  final int best;

  /// Freezes held now.
  final int freezes;

  /// Oldest first; the last entry is today.
  final List<StreakDay> calendar;
  final bool todayDone;
  final int maxFreezes;
  final int freezePrice;

  /// The coin balance, when the server sends it, so the app can say up front
  /// that a freeze is out of reach.
  final int? coins;

  int get freezesUsed => calendar.where((d) => d.state == StreakDayState.frozen).length;
  bool get canHoldMore => freezes < maxFreezes;
}

/// `POST /v1/me/streak/freezes`.
@immutable
class FreezePurchase {
  const FreezePurchase({required this.freezes, this.coins});

  factory FreezePurchase.fromJson(Object? json) {
    final r = JsonReader(json, 'streak freeze');
    return FreezePurchase(freezes: r.integer('freezes'), coins: r.optInt('coins'));
  }

  /// Freezes held after buying.
  final int freezes;

  /// The coin balance after paying.
  final int? coins;
}

/// One achievement, earned or in progress.
@immutable
class Achievement {
  const Achievement({
    required this.id,
    required this.title,
    required this.description,
    required this.icon,
    required this.progress,
    required this.target,
    this.earnedAt,
    this.coins = 0,
  });

  factory Achievement.fromJson(Object? json) {
    final r = JsonReader(json, 'achievement');
    final earned = r.optString('earned_at');
    return Achievement(
      id: r.string('id'),
      title: r.string('title'),
      description: r.optString('description') ?? '',
      icon: r.optString('icon') ?? 'award',
      earnedAt: earned == null ? null : DateTime.tryParse(earned),
      progress: r.optInt('progress') ?? 0,
      target: r.optInt('target') ?? 1,
      coins: r.optInt('coins') ?? 0,
    );
  }

  final String id;
  final String title;
  final String description;

  /// An icon name, e.g. `fire` or `medal`.
  final String icon;
  final DateTime? earnedAt;
  final int progress;
  final int target;

  /// Coins credited when earned.
  final int coins;

  bool get earned => earnedAt != null;
  double get fraction =>
      earned ? 1 : (target <= 0 ? 0 : (progress / target).clamp(0, 1).toDouble());
}

/// `GET /v1/me/achievements`.
@immutable
class Achievements {
  const Achievements({required this.items});

  factory Achievements.fromJson(Object? json) {
    final r = JsonReader(json, 'achievements');
    return Achievements(items: r.list('items', Achievement.fromJson));
  }

  final List<Achievement> items;

  List<Achievement> get earned =>
      [...items.where((a) => a.earned)]..sort((a, b) => b.earnedAt!.compareTo(a.earnedAt!));
  List<Achievement> get locked =>
      [...items.where((a) => !a.earned)]..sort((a, b) => b.fraction.compareTo(a.fraction));
}

AppAction? _tryAction(Object? json) {
  if (json == null) return null;
  try {
    return AppAction.fromJson(json);
  } on FormatException {
    return null;
  }
}
