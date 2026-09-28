import 'package:flutter/foundation.dart';
import 'package:realtime_client/realtime_client.dart' show PlayerCard;

import '../../../core/network/json.dart';
import '../../battle/data/battle_models.dart' show RatingInfo;
import '../../battle/data/match_models.dart' show parsePlayerCard;
import '../../practice/data/practice_models.dart' show PracticeMode;

/// The rating chart's window (`GET /v1/me/stats?range=`).
enum StatsRange {
  days30('30d', '30 days'),
  days90('90d', '90 days'),
  all('all', 'All time');

  const StatsRange(this.wire, this.label);

  final String wire;
  final String label;
}

/// Level and progress to the next one: `{"level", "into_level", "for_next"}` (as on Home).
@immutable
class LevelInfo {
  const LevelInfo({required this.level, this.intoLevel = 0, this.forNext = 0});

  factory LevelInfo.fromJson(Object? json) {
    final r = JsonReader(json, 'level');
    return LevelInfo(
      level: r.integer('level'),
      intoLevel: r.optInt('into_level') ?? 0,
      forNext: r.optInt('for_next') ?? 0,
    );
  }

  final int level;

  /// XP earned since reaching [level].
  final int intoLevel;

  /// XP [level] needs in total to reach the next one.
  final int forNext;

  double get progress => forNext <= 0 ? 0 : (intoLevel / forNext).clamp(0, 1).toDouble();
}

/// Wins, draws and losses: `{"wins", "draws", "losses"}`.
@immutable
class WinDrawLoss {
  const WinDrawLoss({this.wins = 0, this.draws = 0, this.losses = 0});

  /// Also reads the short forms `{"w", "d", "l"}` and `{"win", "draw", "loss"}`.
  factory WinDrawLoss.fromJson(Object? json) {
    final r = JsonReader(json, 'record');
    int read(List<String> keys) {
      for (final key in keys) {
        if (r.optInt(key) case final value?) return value;
      }
      return 0;
    }

    return WinDrawLoss(
      wins: read(['wins', 'win', 'w']),
      draws: read(['draws', 'draw', 'd']),
      losses: read(['losses', 'loss', 'l']),
    );
  }

  final int wins;
  final int draws;
  final int losses;

  int get played => wins + draws + losses;

  WinDrawLoss operator +(WinDrawLoss other) => WinDrawLoss(
    wins: wins + other.wins,
    draws: draws + other.draws,
    losses: losses + other.losses,
  );

  /// "12W 3D 9L".
  String get compact => '${wins}W ${draws}D ${losses}L';
}

/// A rating on one board (`overall`, a subject, …) and the player's position on it.
@immutable
class ScopeRating {
  const ScopeRating({required this.scope, required this.rating, this.name, this.position});

  factory ScopeRating.fromJson(Object? json) {
    final r = JsonReader(json, 'scope rating');
    return ScopeRating(
      scope: r.string('scope'),
      name: r.optString('name'),
      rating: RatingInfo.fromJson(r['rating']),
      position: r.optInt('position'),
    );
  }

  /// `overall`, or a subject slug such as `physics`.
  final String scope;

  /// What to call the scope; derived from [scope] when the server doesn't say.
  final String? name;
  final RatingInfo rating;

  /// Null until ranked (provisional ratings aren't on boards).
  final int? position;

  String get label => name ?? scopeLabel(scope);
}

/// "Overall", "Physics", "Organic chemistry" from `overall`, `physics`, `organic_chemistry`.
String scopeLabel(String scope) {
  final words = scope.replaceAll(RegExp('[_:-]+'), ' ').trim();
  if (words.isEmpty) return scope;
  return words[0].toUpperCase() + words.substring(1);
}

/// One point of the rating chart.
@immutable
class RatingPoint {
  const RatingPoint({required this.at, required this.value});

  factory RatingPoint.fromJson(Object? json) {
    final r = JsonReader(json, 'rating point');
    return RatingPoint(at: r.dateTime('at'), value: r.integer('value'));
  }

  final DateTime at;
  final int value;
}

/// `GET /v1/me/stats?range=`: everything on the Profile's stats card and chart.
@immutable
class PlayerStats {
  const PlayerStats({
    this.level,
    this.ratings = const [],
    this.records = const {},
    this.accuracy,
    this.questionsAnswered = 0,
    this.currentStreak = 0,
    this.bestStreak = 0,
    this.ratingHistory = const [],
  });

  factory PlayerStats.fromJson(Object? json) {
    final r = JsonReader(json, 'stats');
    final streak = r['streak'];
    final accuracy = r['accuracy'];
    return PlayerStats(
      level: r.optObject('level', LevelInfo.fromJson),
      ratings: r.optList('ratings', ScopeRating.fromJson),
      records: switch (r['record']) {
        null => const {},
        final Map<Object?, Object?> modes => Map.unmodifiable({
          for (final MapEntry(:key, :value) in modes.entries)
            if (key is String && value is Map) key: WinDrawLoss.fromJson(value),
        }),
        _ => throw const FormatException('stats: "record" must be an object'),
      },
      // A fraction (0.68) or a percentage (68) both read as 68 %.
      accuracy: switch (accuracy) {
        final num value when value > 1 => (value / 100).clamp(0, 1).toDouble(),
        final num value => value.clamp(0, 1).toDouble(),
        _ => null,
      },
      questionsAnswered: r.optInt('questions_answered') ?? 0,
      currentStreak: streak is Map && streak['current'] is num
          ? (streak['current']! as num).round()
          : 0,
      bestStreak: streak is Map && streak['best'] is num ? (streak['best']! as num).round() : 0,
      ratingHistory: r.optList('rating_history', RatingPoint.fromJson),
    );
  }

  final LevelInfo? level;
  final List<ScopeRating> ratings;

  /// W/D/L per mode: `rated`, `casual`, `bot`, `friend`, `group`, `tournament`.
  final Map<String, WinDrawLoss> records;

  /// Share of answers that were right, 0–1; null before any answer.
  final double? accuracy;
  final int questionsAnswered;

  /// Days in a row with activity.
  final int currentStreak;
  final int bestStreak;

  /// The overall rating over the requested range, oldest first.
  final List<RatingPoint> ratingHistory;

  /// Every mode together.
  WinDrawLoss get total => records.values.fold(const WinDrawLoss(), (a, b) => a + b);
}

/// A played game in the history (`GET /v1/me/matches`).
@immutable
class MatchHistoryItem {
  const MatchHistoryItem({
    required this.id,
    required this.playedAt,
    this.kind,
    this.subject,
    this.chapters = const [],
    this.result,
    this.reason,
    this.scoreMe,
    this.scoreOther,
    this.opponents = const [],
    this.ratingDelta,
    this.coinsDelta,
    this.place,
  });

  factory MatchHistoryItem.fromJson(Object? json) {
    final r = JsonReader(json, 'match history');
    final score = r['score'];
    return MatchHistoryItem(
      id: r.string('id'),
      kind: r.optString('kind'),
      subject: r.optString('subject'),
      chapters: [
        if (r['chapters'] case final List<Object?> names)
          for (final name in names)
            if (name is String) name,
      ],
      playedAt: r.dateTime('played_at'),
      result: r.optString('result'),
      reason: r.optString('reason'),
      scoreMe: score is Map && score['me'] is num ? (score['me']! as num).round() : null,
      scoreOther: score is Map && score['best_other'] is num
          ? (score['best_other']! as num).round()
          : null,
      opponents: [
        if (r['opponents'] case final List<Object?> cards)
          for (final card in cards) ?parsePlayerCard(card),
      ],
      ratingDelta: r.optInt('rating_delta'),
      coinsDelta: r.optInt('coins_delta'),
      place: r.optInt('place'),
    );
  }

  final String id;

  /// `rated`, `casual`, `bot`, `friend`, `group` or `tournament`.
  final String? kind;
  final String? subject;
  final List<String> chapters;
  final DateTime playedAt;

  /// `win`, `loss`, `draw`, `aborted` or `voided`.
  final String? result;
  final String? reason;
  final int? scoreMe;
  final int? scoreOther;
  final List<PlayerCard> opponents;
  final int? ratingDelta;
  final int? coinsDelta;

  /// Finishing position in a group battle.
  final int? place;

  /// Games that were played out have a review; aborted and voided ones don't.
  bool get hasReview => result == 'win' || result == 'loss' || result == 'draw';
}

/// A practice session in the history (`GET /v1/me/practice/sessions`).
@immutable
class PracticeHistoryItem {
  const PracticeHistoryItem({
    required this.sessionId,
    required this.title,
    required this.createdAt,
    this.mode,
    this.finishedAt,
    this.answered = 0,
    this.correct = 0,
    this.score,
    this.maxScore,
  });

  factory PracticeHistoryItem.fromJson(Object? json) {
    final r = JsonReader(json, 'practice history');
    return PracticeHistoryItem(
      sessionId: r.string('session_id'),
      mode: PracticeMode.parse(r['mode']),
      title: r.optString('title') ?? '',
      createdAt: r.dateTime('created_at'),
      finishedAt: r.has('finished_at') ? r.dateTime('finished_at') : null,
      answered: r.optInt('answered') ?? 0,
      correct: r.optInt('correct') ?? 0,
      score: r.optInt('score'),
      maxScore: r.optInt('max_score'),
    );
  }

  final String sessionId;
  final PracticeMode? mode;
  final String title;
  final DateTime createdAt;

  /// Null while the session can still be continued.
  final DateTime? finishedAt;
  final int answered;
  final int correct;

  /// Marks under exam marking; null for unmarked practice.
  final int? score;
  final int? maxScore;

  bool get finished => finishedAt != null;
}

/// Someone played recently (`GET /v1/me/opponents`), with the record against them.
@immutable
class RecentOpponent {
  const RecentOpponent({
    required this.user,
    this.h2h = const WinDrawLoss(),
    this.relationship,
    this.lastPlayedAt,
  });

  /// `{"user": card, "h2h", "relationship", "last_played_at"}`; a bare card with those fields
  /// alongside also reads.
  factory RecentOpponent.fromJson(Object? json) {
    final r = JsonReader(json, 'opponent');
    final user = parsePlayerCard(r['user'] ?? json);
    if (user == null) throw const FormatException('opponent: "user" must be a player card');
    return RecentOpponent(
      user: user,
      h2h: r.optObject('h2h', WinDrawLoss.fromJson) ?? const WinDrawLoss(),
      relationship: r.optString('relationship'),
      lastPlayedAt: r.has('last_played_at') ? r.dateTime('last_played_at') : null,
    );
  }

  final PlayerCard user;

  /// Your record against them.
  final WinDrawLoss h2h;

  /// `none`, `friend`, `requested` or `blocked`.
  final String? relationship;
  final DateTime? lastPlayedAt;
}
