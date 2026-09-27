import 'package:realtime_client/realtime_client.dart';

/// Short, friendly lines for live events. Pure, so every wording is testable.
abstract final class LiveText {
  /// "1 coin", "5 coins".
  static String coins(int count) => count == 1 ? '1 coin' : '$count coins';

  /// The headline when a search stopped without a match.
  static String cancelledTitle(String reason) => switch (reason) {
    'timeout' => 'No one was available',
    'background' || 'away' => 'Your search stopped while you were away',
    'cooldown' => 'Searching is paused for a bit',
    _ => 'Your search stopped',
  };

  /// Why it stopped, plus the refund.
  static String cancelledMessage(String reason, int refunded) {
    final why = switch (reason) {
      'timeout' => 'Try the Practice Bot or invite a friend',
      'background' || 'away' => 'It doesn\'t count against you',
      'disconnected' => 'The connection dropped for too long. It doesn\'t count against you',
      'cooldown' => 'Too many cancelled matches. Try again in a few minutes',
      'user' => 'You cancelled it',
      _ => 'You can start a new one any time',
    };
    return refunded > 0 ? '$why · ${coins(refunded)} returned' : why;
  }

  /// A `BUSY` answer: where the user already is.
  static String busyTitle(ActiveKind? kind) => switch (kind) {
    ActiveKind.match => 'You\'re already in a match',
    ActiveKind.queue => 'You\'re already searching',
    ActiveKind.room => 'You\'re already in a room',
    ActiveKind.tournament => 'Your tournament starts soon',
    _ => 'You\'re busy in another game',
  };

  /// "You vs Riya · Physics", or "Practice Bot · Physics".
  static String foundMessage({required String opponent, required bool bot, String? subject}) {
    final who = bot ? 'Practice Bot' : 'You vs $opponent';
    return subject == null ? who : '$who · $subject';
  }

  /// What went wrong with `mm.join`.
  static String joinError(RealtimeError error) => switch (error.code) {
    RealtimeErrorCode.insufficientCoins =>
      'You need 5 coins for a casual battle. Earn coins from missions.',
    RealtimeErrorCode.cooldown => 'Too many cancelled matches. Try again in a few minutes.',
    RealtimeErrorCode.rateLimited => 'That\'s a lot of searches. Wait a moment and try again.',
    RealtimeErrorCode.unavailable => 'Battles are paused for a moment. Please try again soon.',
    RealtimeErrorCode.busy => busyTitle(error.active?.kind),
    RealtimeErrorCode.notAllowed => 'You can\'t start this battle right now.',
    RealtimeErrorCode.badRequest ||
    RealtimeErrorCode.notFound => 'That chapter can\'t be battled yet. Pick another one.',
    _ => 'Couldn\'t reach the game server. Check your connection and try again.',
  };

  /// Why a game ended, when it wasn't played to the end. Null for a normal finish.
  static String? endReason(MatchOutcome outcome, {required String opponent}) {
    final won = outcome.result == MatchResult.win;
    return switch (outcome.reason) {
      MatchEndReason.normal || MatchEndReason.unknown => null,
      MatchEndReason.forfeit => won ? '$opponent left the game' : 'You left the game',
      MatchEndReason.opponentForfeit => '$opponent left the game',
      MatchEndReason.left => won ? '$opponent left the game' : 'You left the game',
      MatchEndReason.disconnected => won ? '$opponent left the game' : 'You were away too long',
      MatchEndReason.noShow => won ? '$opponent didn\'t show up' : 'You didn\'t get ready in time',
      MatchEndReason.endedByHost => 'The host ended the game',
      MatchEndReason.aborted => 'The game didn\'t start',
      MatchEndReason.voided => 'This game didn\'t count',
    };
  }

  /// "Riya didn't join · 5 coins returned" (or why this player's own game fell through).
  static String aborted({required String opponent, required bool iWasReady, required bool casual}) {
    final why = iWasReady ? '$opponent didn\'t join' : 'You didn\'t get ready in time';
    return casual ? '$why · ${coins(5)} returned' : why;
  }

  /// A voided game: nothing changed.
  static String voided({required bool casual}) {
    const why = 'Something went wrong, so ratings and coins didn\'t change';
    return casual ? '$why · ${coins(5)} returned' : why;
  }

  /// "Physics" for `rating:physics`, "Physics this week" for `weekly:physics`.
  static String boardName(String board) {
    final parts = board.split(':');
    String title(String slug) => slug.isEmpty
        ? slug
        : slug.split('-').map((w) => w.isEmpty ? w : w[0].toUpperCase() + w.substring(1)).join(' ');
    return switch (parts) {
      ['rating', 'overall'] => 'overall',
      ['rating', final subject] => 'in ${title(subject)}',
      ['weekly', final subject] => 'in ${title(subject)} this week',
      ['weekly_xp'] => 'this week',
      _ => 'on the board',
    };
  }

  /// "You're now #42 in Physics · ↑5", or "Play 6 more rated battles to get ranked".
  static String rankLine(RankUpdate rank) => switch (rank) {
    RankPending(:final gamesToRank) =>
      gamesToRank == 1
          ? 'Play 1 more rated battle to get ranked'
          : 'Play $gamesToRank more rated battles to get ranked',
    RankMoved(:final after, :final change, :final board) => switch (change) {
      > 0 => 'You\'re now #$after ${boardName(board)} · ↑$change',
      < 0 => 'You\'re now #$after ${boardName(board)} · ↓${-change}',
      _ => 'You\'re #$after ${boardName(board)}',
    },
  };

  /// "You were 1.2 s faster", "Riya was 0.8 s faster", "Same speed". Null in bot games and when
  /// there is nothing to compare.
  static String? speedLine(
    RevealResult reveal, {
    required String me,
    required String? opponentUid,
    required String opponent,
    required bool bot,
  }) {
    if (bot || opponentUid == null) return null;
    final mine = reveal.players[me];
    final theirs = reveal.players[opponentUid];
    if (mine == null || theirs == null) return null;
    if (mine.opt == null && theirs.opt == null) return null;
    if (mine.opt == null) return '$opponent answered, you didn\'t';
    if (theirs.opt == null) return '$opponent didn\'t answer';
    if (mine.speed == Speed.even) return 'Same speed';
    final myTime = mine.timeMs;
    final theirTime = theirs.timeMs;
    if (myTime != null && theirTime != null) {
      final gap = (theirTime - myTime).abs();
      if (gap < 50) return 'Same speed';
      final seconds = (gap / 1000).toStringAsFixed(1);
      return myTime < theirTime ? 'You were $seconds s faster' : '$opponent was $seconds s faster';
    }
    return switch (mine.speed) {
      Speed.fast => 'You were faster',
      Speed.slow => '$opponent was faster',
      _ => null,
    };
  }

  /// "+132" for points won on a question, "No points" for none.
  static String points(int pts) => pts > 0 ? '+$pts' : 'No points';

  /// "0:32".
  static String mmss(Duration duration) {
    final seconds = duration.inSeconds.clamp(0, 99 * 60 + 59);
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }
}
