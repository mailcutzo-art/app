import 'package:flutter/foundation.dart';

import '../../../core/network/json.dart';
import '../../learn/data/learn_models.dart' show ChapterLabel;

/// How a quick battle is played. `bot` is the Practice Bot: unrated, no coins.
enum BattleMode {
  rated('rated'),
  casual('casual'),
  bot('bot');

  const BattleMode(this.wire);

  final String wire;

  static BattleMode? parse(Object? value) => values.where((m) => m.wire == value).firstOrNull;
}

/// A rating as the app shows it: `—` before any rated game, `1523?` while provisional.
@immutable
class RatingInfo {
  const RatingInfo({required this.display, this.value, this.provisional = false});

  static const none = RatingInfo(display: '—', provisional: true);

  /// Accepts `{display, value, provisional}`; anything unreadable is [none].
  factory RatingInfo.fromJson(Object? json) {
    if (json is! Map) return none;
    final display = json['display'];
    final value = json['value'];
    return RatingInfo(
      display: display is String && display.isNotEmpty
          ? display
          : (value is num ? '${value.round()}' : '—'),
      value: value is num ? value.round() : null,
      provisional: json['provisional'] == true,
    );
  }

  final String display;
  final int? value;
  final bool provisional;

  /// Whether the player has no rating in this subject yet.
  bool get isNew => value == null;

  @override
  bool operator ==(Object other) =>
      other is RatingInfo &&
      other.display == display &&
      other.value == value &&
      other.provisional == provisional;

  @override
  int get hashCode => Object.hash(display, value, provisional);
}

@immutable
class BattleChapter {
  const BattleChapter({
    required this.slug,
    required this.name,
    this.battleReady = false,
    this.questionCount = 0,
    this.label,
  });

  factory BattleChapter.fromJson(Object? json) {
    final r = JsonReader(json, 'battle chapter');
    return BattleChapter(
      slug: r.string('slug'),
      name: r.string('name'),
      battleReady: r['battle_ready'] == true,
      questionCount: _lenientInt(r['question_count']) ?? 0,
      label: ChapterLabel.parse(r['label']),
    );
  }

  final String slug;
  final String name;

  /// Enough battle questions to be offered. Others show "Coming soon".
  final bool battleReady;
  final int questionCount;
  final ChapterLabel? label;
}

@immutable
class BattleSubject {
  const BattleSubject({
    required this.slug,
    required this.name,
    this.tone = '',
    this.rating = RatingInfo.none,
    this.chapters = const [],
  });

  factory BattleSubject.fromJson(Object? json) {
    final r = JsonReader(json, 'battle subject');
    return BattleSubject(
      slug: r.string('slug'),
      name: r.string('name'),
      tone: r['tone'] is String ? r['tone']! as String : '',
      rating: RatingInfo.fromJson(r['rating']),
      chapters: _lenientList(r['chapters'], BattleChapter.fromJson),
    );
  }

  final String slug;
  final String name;

  /// Design system pastel tone name (`sky`, `mint`…).
  final String tone;
  final RatingInfo rating;
  final List<BattleChapter> chapters;

  BattleChapter? chapter(String? slug) => chapters.where((c) => c.slug == slug).firstOrNull;

  /// Whether at least one chapter can be battled.
  bool get anyReady => chapters.any((c) => c.battleReady);
}

/// Something the user is already in: a queue, a match, a room or a tournament.
@immutable
class BattleActive {
  const BattleActive({required this.kind, this.id, this.title, this.route});

  factory BattleActive.fromJson(Object? json) {
    final r = JsonReader(json, 'battle active');
    final action = r['action'];
    return BattleActive(
      kind: r.string('kind'),
      id: r['id'] is String ? r['id']! as String : null,
      title: r['title'] is String ? r['title']! as String : null,
      route: action is Map && action['route'] is String ? action['route']! as String : null,
    );
  }

  /// `queue`, `match`, `room` or `tournament`.
  final String kind;
  final String? id;
  final String? title;

  /// Where "Go there" leads, when the server says.
  final String? route;
}

/// What the Battle tab has selected. Kept on the device and sent back by the server as `last`.
@immutable
class BattleSelection {
  const BattleSelection({required this.subject, this.chapter, this.mode = BattleMode.rated});

  /// Returns null for a payload without a subject.
  static BattleSelection? tryParse(Object? json) {
    if (json is! Map) return null;
    final subject = json['subject'];
    if (subject is! String || subject.isEmpty) return null;
    final chapter = json['chapter'];
    final mode = BattleMode.parse(json['mode']);
    return BattleSelection(
      subject: subject,
      chapter: chapter is String && chapter.isNotEmpty ? chapter : null,
      // A bot game is never the remembered mode: it starts from its own button.
      mode: mode == null || mode == BattleMode.bot ? BattleMode.rated : mode,
    );
  }

  final String subject;

  /// `null` means all chapters.
  final String? chapter;
  final BattleMode mode;

  Map<String, Object?> toJson() => {'subject': subject, 'chapter': chapter, 'mode': mode.wire};

  BattleSelection copyWith({String? subject, Object? chapter = _keep, BattleMode? mode}) =>
      BattleSelection(
        subject: subject ?? this.subject,
        chapter: identical(chapter, _keep) ? this.chapter : chapter as String?,
        mode: mode ?? this.mode,
      );

  @override
  bool operator ==(Object other) =>
      other is BattleSelection &&
      other.subject == subject &&
      other.chapter == chapter &&
      other.mode == mode;

  @override
  int get hashCode => Object.hash(subject, chapter, mode);

  @override
  String toString() => 'BattleSelection($subject, ${chapter ?? 'all'}, ${mode.wire})';
}

const Object _keep = Object();

/// "3 players searching · usually 20 s".
@immutable
class OnlineStat {
  const OnlineStat({required this.searching, this.p50WaitS});

  static OnlineStat? tryParse(Object? json) {
    if (json is! Map) return null;
    final searching = _lenientInt(json['searching']);
    if (searching == null) return null;
    return OnlineStat(searching: searching, p50WaitS: _lenientInt(json['p50_wait_s']));
  }

  final int searching;
  final int? p50WaitS;
}

/// "Physics this week: Riya leads · you're #12".
@immutable
class SubjectLeaders {
  const SubjectLeaders({this.leaderName, this.leaderIsMe = false, this.myPosition});

  static SubjectLeaders? tryParse(Object? json, {String? myId}) {
    if (json is! Map) return null;
    final leader = json['leader'];
    final me = json['me'];
    String? name;
    var leaderIsMe = false;
    if (leader is Map) {
      final user = leader['user'];
      if (user is Map) {
        final display = user['display_name'] ?? user['name'] ?? user['handle'];
        if (display is String && display.isNotEmpty) name = display;
        leaderIsMe = myId != null && user['id'] == myId;
      }
    }
    final position = me is Map ? _lenientInt(me['position']) : null;
    if (name == null && position == null) return null;
    return SubjectLeaders(leaderName: name, leaderIsMe: leaderIsMe, myPosition: position);
  }

  final String? leaderName;
  final bool leaderIsMe;
  final int? myPosition;
}

/// Everything the Battle tab needs (`GET /v1/battle/setup?goal=`).
@immutable
class BattleSetup {
  const BattleSetup({
    required this.subjects,
    this.coins,
    this.casualFee = 5,
    this.cooldownUntil,
    this.active,
    this.last,
    this.online = const {},
    this.firstSearch = false,
    this.leaders = const {},
  });

  /// Throws [FormatException] only when `subjects` is missing; every other field falls back to a
  /// safe default, and subjects or chapters that can't be read are skipped.
  factory BattleSetup.fromJson(Object? json, {String? myId}) {
    final r = JsonReader(json, 'battle setup');
    if (r['subjects'] is! List) throw const FormatException('battle setup: "subjects" is missing');
    final online = r['online'];
    final leaders = r['leaders'];
    final cooldown = r['cooldown_until'];
    final active = r['active'];
    return BattleSetup(
      subjects: _lenientList(r['subjects'], BattleSubject.fromJson),
      coins: _lenientInt(r['coins']),
      casualFee: _lenientInt(r['casual_fee']) ?? 5,
      cooldownUntil: cooldown is String ? DateTime.tryParse(cooldown) : null,
      active: active == null ? null : _tryParse(() => BattleActive.fromJson(active)),
      last: BattleSelection.tryParse(r['last']),
      online: {
        if (online is Map)
          for (final MapEntry(:key, :value) in online.entries)
            if (key is String) key: ?OnlineStat.tryParse(value),
      },
      firstSearch: r['first_search'] == true,
      leaders: {
        if (leaders is Map)
          for (final MapEntry(:key, :value) in leaders.entries)
            if (key is String) key: ?SubjectLeaders.tryParse(value, myId: myId),
      },
    );
  }

  final List<BattleSubject> subjects;

  /// The coin balance, if the server sent it.
  final int? coins;
  final int casualFee;

  /// Queueing is blocked until then (too many cancelled matches).
  final DateTime? cooldownUntil;

  /// Set when the user is already busy; the tab then offers "Go there".
  final BattleActive? active;

  /// The last selection the server remembers.
  final BattleSelection? last;
  final Map<String, OnlineStat> online;

  /// The first search ever offers the Practice Bot at 20 s instead of 45 s.
  final bool firstSearch;
  final Map<String, SubjectLeaders> leaders;

  BattleSubject? subject(String? slug) => subjects.where((s) => s.slug == slug).firstOrNull;

  /// Whether Casual can be picked: the balance covers the entry fee. An unknown balance doesn't
  /// block it; the server has the final word.
  bool get canAffordCasual => coins == null || coins! >= casualFee;
}

int? _lenientInt(Object? value) => switch (value) {
  final int v => v,
  final double v when v.isFinite => v.round(),
  final String v => int.tryParse(v),
  _ => null,
};

List<T> _lenientList<T>(Object? value, T Function(Object? json) parse) {
  if (value is! List) return List<T>.unmodifiable(const []);
  return List.unmodifiable([
    for (final item in value)
      if (_tryParse(() => parse(item)) case final T parsed) parsed,
  ]);
}

T? _tryParse<T>(T Function() parse) {
  try {
    return parse();
  } on FormatException catch (e) {
    debugPrint('Skipping an unreadable battle item: $e');
    return null;
  }
}
