import 'package:design_system/design_system.dart' show DotOutcome;
import 'package:realtime_client/realtime_client.dart' show MatchResult;

import '../../core/auth/user.dart';
import '../../core/realtime/live_match.dart';
import '../battle/match/match_widgets.dart' show avatarOf;
import '../battle/match/result_view.dart' show resultDots;
import '../profile/data/profile_models.dart';
import 'share_models.dart';

/// The result screen's match as a share card, or null while the result isn't known (the game
/// is still on, or it was cancelled).
MatchShareData? matchShareData(MatchView view, Me me) {
  if (!view.isOver) return null;
  final outcome = switch (view.outcome?.result) {
    MatchResult.win => ShareOutcome.win,
    MatchResult.draw => ShareOutcome.draw,
    MatchResult.loss => ShareOutcome.loss,
    _ => null,
  };
  if (outcome == null) return null;
  final request = view.intro?.request;
  final summary = view.summary;
  final settlement = view.settlement;
  final live = view.hasLiveState;
  return MatchShareData(
    player: SharePlayer.fromMe(me),
    matchId: view.matchId,
    outcome: outcome,
    subject: request?.subjectLabel ?? summary?.subject ?? 'Quiz',
    chapter:
        request?.chapterLabel ??
        (summary != null && summary.chapters.length == 1 ? summary.chapters.single : null),
    score: live ? view.myTotals.points : (summary?.scoreMe ?? 0),
    opponentScore: live ? view.opponentTotals.points : (summary?.scoreOther ?? 0),
    opponentName: view.opponentName,
    opponentAvatar: view.opponentCard == null ? null : avatarOf(view.opponentCard),
    answers: [
      for (final dot in resultDots(view))
        switch (dot.outcome) {
          DotOutcome.right => ShareAnswer.correct,
          DotOutcome.wrong => ShareAnswer.wrong,
          DotOutcome.missed || DotOutcome.unknown => ShareAnswer.skipped,
        },
    ],
    ratingChange: settlement?.rating?.delta ?? summary?.ratingDelta,
    coins: view.isBot ? null : (settlement?.coins?.delta ?? summary?.coinsDelta),
    xp: settlement?.xp?.delta,
  );
}

/// The profile's stats as a progress card, or null before the level is known.
ProgressShareData? progressShareData(PlayerStats stats, Me me) {
  final level = stats.level;
  if (level == null) return null;
  return ProgressShareData(
    player: SharePlayer.fromMe(me),
    level: level.level,
    xpIntoLevel: level.intoLevel,
    xpForLevel: level.forNext,
    ratings: [
      for (final rating in stats.ratings)
        if (!rating.rating.isNew) ShareRating(label: rating.label, rating: rating.rating.display),
    ],
    accuracy: stats.accuracy,
    answered: stats.questionsAnswered,
    currentStreak: stats.currentStreak,
    bestStreak: stats.bestStreak,
  );
}
