import 'package:design_system/design_system.dart' show AvatarData;
import 'package:flutter/foundation.dart';

import '../../core/auth/user.dart';
import '../../core/network/json.dart';

/// The app's name as share cards and captions spell it.
const appName = 'Quiz Arena';

/// What a share is about, as `POST /v1/me/activity/shares` takes it. There is no text or
/// picture: the server builds the post from its own records.
@immutable
sealed class ShareTarget {
  const ShareTarget();

  Map<String, Object?> toJson();
}

/// A battle the user played, once it has ended.
final class MatchShareTarget extends ShareTarget {
  const MatchShareTarget(this.matchId);

  final String matchId;

  @override
  Map<String, Object?> toJson() => {'kind': 'match_result', 'match_id': matchId};

  @override
  bool operator ==(Object other) => other is MatchShareTarget && other.matchId == matchId;

  @override
  int get hashCode => matchId.hashCode;
}

/// The user's level, streak, accuracy and ratings.
final class ProgressShareTarget extends ShareTarget {
  const ProgressShareTarget();

  @override
  Map<String, Object?> toJson() => const {'kind': 'progress'};

  @override
  bool operator ==(Object other) => other is ProgressShareTarget;

  @override
  int get hashCode => (ProgressShareTarget).hashCode;
}

/// Who a card belongs to: only the display name, the handle and the avatar.
@immutable
class SharePlayer {
  const SharePlayer({required this.displayName, this.handle, this.avatar = Avatar.fallback});

  factory SharePlayer.fromMe(Me me) =>
      SharePlayer(displayName: me.displayName, handle: me.handle, avatar: me.avatar);

  final String displayName;
  final String? handle;
  final Avatar avatar;

  /// "@asha", or null before the user picked a handle.
  String? get at => handle == null ? null : '@$handle';
}

/// How a battle ended for the player on the card.
enum ShareOutcome {
  win('win', 'Victory!'),
  draw('draw', 'Draw'),
  loss('loss', 'Defeat');

  const ShareOutcome(this.wire, this.title);

  final String wire;
  final String title;

  static ShareOutcome? tryParse(Object? value) => values.where((o) => o.wire == value).firstOrNull;
}

/// One question on a result card.
enum ShareAnswer {
  correct('correct'),
  wrong('wrong'),
  skipped('skipped');

  const ShareAnswer(this.wire);

  final String wire;

  /// Unknown values read as [skipped].
  static ShareAnswer parse(Object? value) =>
      values.where((a) => a.wire == value).firstOrNull ?? skipped;
}

/// Everything a share card shows. Built from what the app already has (the result screen, the
/// profile's stats) or read from a shared item in the friends' feed.
@immutable
sealed class ShareCardData {
  const ShareCardData({required this.player});

  final SharePlayer player;

  /// What to post to friends in the app.
  ShareTarget get target;

  /// The text that goes with the image to other apps: "I won a Physics battle on Quiz Arena! 🏆".
  String get caption;

  /// The card in words, for screen readers.
  String get semanticLabel;

  /// [caption] plus a link when the build has one ([baseUrl] from `SHARE_BASE_URL`).
  String captionWithLink(String baseUrl) {
    final base = baseUrl.trim();
    if (base.isEmpty) return caption;
    return '$caption ${base.endsWith('/') ? base.substring(0, base.length - 1) : base}';
  }
}

/// A battle result: `shared_result` in the feed, or the result screen's view of a match.
final class MatchShareData extends ShareCardData {
  const MatchShareData({
    required super.player,
    required this.matchId,
    required this.outcome,
    required this.subject,
    required this.score,
    required this.opponentScore,
    required this.opponentName,
    this.chapter,
    this.opponentAvatar,
    this.answers = const [],
    this.ratingChange,
    this.coins,
    this.xp,
  });

  /// A `shared_result` payload (`docs/api-play.md`, "Share payloads"). Throws
  /// [FormatException] when a required field is missing or malformed.
  factory MatchShareData.fromPayload(Object? json, {required SharePlayer player}) {
    final r = JsonReader(json, 'shared result');
    final outcome = ShareOutcome.tryParse(r['result']);
    if (outcome == null) throw const FormatException('shared result: unknown "result"');
    final opponent = r['opponent'];
    return MatchShareData(
      player: player,
      matchId: r.string('match_id'),
      outcome: outcome,
      subject: r.string('subject'),
      chapter: r.optString('chapter'),
      score: r.integer('score'),
      opponentScore: r.integer('opponent_score'),
      opponentName:
          r.optString('opponent_name') ??
          (opponent is Map && opponent['display_name'] is String
              ? opponent['display_name']! as String
              : 'Another player'),
      opponentAvatar: opponent is Map ? Avatar.parse(opponent['avatar']).toData() : null,
      answers: [
        if (r['questions'] case final List<Object?> answers)
          for (final answer in answers) ShareAnswer.parse(answer),
      ],
      ratingChange: r.optInt('rating_change'),
      coins: r.optInt('coins'),
      xp: r.optInt('xp'),
    );
  }

  final String matchId;
  final ShareOutcome outcome;

  /// "Physics".
  final String subject;

  /// "Kinematics", or null for all chapters.
  final String? chapter;
  final int score;
  final int opponentScore;

  /// The opponent's display name ("Practice Bot" for a bot).
  final String opponentName;

  /// Null when unknown or hidden; the card then shows a neutral avatar.
  final AvatarData? opponentAvatar;

  /// The player's answers in order.
  final List<ShareAnswer> answers;

  /// Settlement, when it applies and has arrived.
  final int? ratingChange;
  final int? coins;
  final int? xp;

  int get correct => answers.where((a) => a == ShareAnswer.correct).length;

  @override
  ShareTarget get target => MatchShareTarget(matchId);

  @override
  String get caption => switch (outcome) {
    ShareOutcome.win => 'I won a $subject battle on $appName! 🏆',
    ShareOutcome.draw => 'I drew a $subject battle on $appName! 🤝',
    ShareOutcome.loss => 'I played a close $subject battle on $appName. Rematch soon! 💪',
  };

  @override
  String get semanticLabel => [
    '${outcome.title} $subject battle',
    ?chapter,
    '${player.displayName} $score, $opponentName $opponentScore',
    if (answers.isNotEmpty) '$correct of ${answers.length} correct',
    if (ratingChange case final change?) 'Rating ${signed(change)}',
    if (coins case final coins?) '${signed(coins)} coins',
    if (xp case final xp?) '${signed(xp)} XP',
  ].join(', ');
}

/// A rating on a progress card.
@immutable
class ShareRating {
  const ShareRating({required this.label, required this.rating});

  /// "Physics", "Overall".
  final String label;

  /// "1524", or "1524?" while provisional.
  final String rating;
}

/// The player's progress: `shared_progress` in the feed, or the profile's stats.
final class ProgressShareData extends ShareCardData {
  const ProgressShareData({
    required super.player,
    required this.level,
    this.xpIntoLevel = 0,
    this.xpForLevel = 0,
    this.ratings = const [],
    this.accuracy,
    this.answered = 0,
    this.currentStreak = 0,
    this.bestStreak = 0,
  });

  /// A `shared_progress` payload. Throws [FormatException] without a level.
  factory ProgressShareData.fromPayload(Object? json, {required SharePlayer player}) {
    final r = JsonReader(json, 'shared progress');
    final streak = r['streak'];
    final accuracy = r['accuracy'];
    return ProgressShareData(
      player: player,
      level: r.integer('level'),
      xpIntoLevel: r.optInt('xp_into_level') ?? 0,
      xpForLevel: r.optInt('xp_for_level') ?? 0,
      ratings: [
        if (r['ratings'] case final List<Object?> ratings)
          for (final rating in ratings)
            if (rating case {'scope': final String scope, 'rating': final num value})
              ShareRating(label: _scopeLabel(scope), rating: '${value.round()}'),
      ],
      // Whole percent from the server; a fraction reads the same.
      accuracy: switch (accuracy) {
        final num value when value > 1 => (value / 100).clamp(0, 1).toDouble(),
        final num value => value.clamp(0, 1).toDouble(),
        _ => null,
      },
      answered: r.optInt('answered') ?? 0,
      currentStreak: streak is Map && streak['current'] is num
          ? (streak['current']! as num).round()
          : 0,
      bestStreak: streak is Map && streak['best'] is num ? (streak['best']! as num).round() : 0,
    );
  }

  final int level;
  final int xpIntoLevel;

  /// XP the whole level spans; 0 at the top level.
  final int xpForLevel;
  final List<ShareRating> ratings;

  /// Share of answers that were right, 0–1; null before any answer.
  final double? accuracy;
  final int answered;
  final int currentStreak;
  final int bestStreak;

  double get levelProgress =>
      xpForLevel <= 0 ? 1 : (xpIntoLevel / xpForLevel).clamp(0, 1).toDouble();

  /// "72%", or "—" before any answer.
  String get accuracyLabel => accuracy == null ? '—' : '${(accuracy! * 100).round()}%';

  @override
  ShareTarget get target => const ProgressShareTarget();

  @override
  String get caption => currentStreak >= 2
      ? 'Level $level on $appName with a $currentStreak-day streak! 📈'
      : 'I\'m level $level on $appName! 📈';

  @override
  String get semanticLabel => [
    '${player.displayName}, level $level',
    for (final rating in ratings) '${rating.label} rating ${rating.rating}',
    'accuracy $accuracyLabel',
    '$answered questions answered',
    'streak $currentStreak days, best $bestStreak',
  ].join(', ');
}

/// "+14", "−3", "0".
String signed(int value) => value > 0 ? '+$value' : (value < 0 ? '−${-value}' : '0');

String _scopeLabel(String scope) {
  final words = scope.split(':').last.replaceAll(RegExp('[_-]+'), ' ').trim();
  if (words.isEmpty) return scope;
  return words[0].toUpperCase() + words.substring(1);
}
