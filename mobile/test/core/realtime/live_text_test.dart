import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_app/core/realtime/live_text.dart';
import 'package:realtime_client/realtime_client.dart';

RevealResult _reveal({
  String? myOpt = 'a',
  int? myMs = 4000,
  Speed? mySpeed,
  String? theirOpt = 'b',
  int? theirMs = 5200,
}) => RevealResult(
  q: 1,
  correctOption: 'a',
  players: {
    'me': PlayerReveal(opt: myOpt, correct: myOpt == 'a', pts: 140, timeMs: myMs, speed: mySpeed),
    'riya': PlayerReveal(opt: theirOpt, correct: theirOpt == 'a', pts: 0, timeMs: theirMs),
  },
  totals: const {},
);

String? _speed(RevealResult reveal, {bool bot = false}) =>
    LiveText.speedLine(reveal, me: 'me', opponentUid: 'riya', opponent: 'Riya', bot: bot);

void main() {
  test('coins', () {
    expect(LiveText.coins(1), '1 coin');
    expect(LiveText.coins(5), '5 coins');
  });

  test('a stopped search says why in plain words, with the refund', () {
    expect(LiveText.cancelledTitle('timeout'), 'No one was available');
    expect(LiveText.cancelledMessage('timeout', 0), 'Try the Practice Bot or invite a friend');
    expect(LiveText.cancelledTitle('background'), 'Your search stopped while you were away');
    expect(
      LiveText.cancelledMessage('background', 5),
      'It doesn\'t count against you · 5 coins returned',
    );
    expect(LiveText.cancelledTitle('away'), 'Your search stopped while you were away');
    expect(LiveText.cancelledMessage('disconnected', 0), contains('connection dropped'));
    expect(LiveText.cancelledTitle('cooldown'), 'Searching is paused for a bit');
    expect(LiveText.cancelledTitle('something-new'), 'Your search stopped');
  });

  test('BUSY names where the user already is', () {
    expect(LiveText.busyTitle(ActiveKind.match), 'You\'re already in a match');
    expect(LiveText.busyTitle(ActiveKind.queue), 'You\'re already searching');
    expect(LiveText.busyTitle(ActiveKind.room), 'You\'re already in a room');
    expect(LiveText.busyTitle(ActiveKind.tournament), 'Your tournament starts soon');
    expect(LiveText.busyTitle(null), 'You\'re busy in another game');
  });

  test('"Match found!" says who and what', () {
    expect(
      LiveText.foundMessage(opponent: 'Riya', bot: false, subject: 'Physics'),
      'You vs Riya · Physics',
    );
    expect(
      LiveText.foundMessage(opponent: 'Practice Bot', bot: true, subject: 'Physics'),
      'Practice Bot · Physics',
    );
    expect(LiveText.foundMessage(opponent: 'Riya', bot: false), 'You vs Riya');
  });

  test('join errors say what to do', () {
    String text(String code) => LiveText.joinError(RealtimeError(code: code));
    expect(text(RealtimeErrorCode.insufficientCoins), contains('Earn coins from missions'));
    expect(text(RealtimeErrorCode.cooldown), contains('Too many cancelled matches'));
    expect(text(RealtimeErrorCode.rateLimited), contains('Wait a moment'));
    expect(text(RealtimeErrorCode.unavailable), contains('paused for a moment'));
    expect(text(RealtimeErrorCode.timeout), contains('Couldn\'t reach the game server'));
    expect(
      LiveText.joinError(
        const RealtimeError(
          code: RealtimeErrorCode.busy,
          details: {
            'active': {'kind': 'room', 'id': 'r1'},
          },
        ),
      ),
      'You\'re already in a room',
    );
  });

  group('why a game ended', () {
    String? reason(MatchResult result, MatchEndReason reason) => LiveText.endReason(
      MatchOutcome(result: result, reason: reason),
      opponent: 'Riya',
    );

    test('nothing to say after a normal finish', () {
      expect(reason(MatchResult.win, MatchEndReason.normal), isNull);
    });

    test('leaving, forfeits and disconnects, from each side', () {
      expect(reason(MatchResult.loss, MatchEndReason.forfeit), 'You left the game');
      expect(reason(MatchResult.win, MatchEndReason.opponentForfeit), 'Riya left the game');
      expect(reason(MatchResult.win, MatchEndReason.left), 'Riya left the game');
      expect(reason(MatchResult.loss, MatchEndReason.left), 'You left the game');
      expect(reason(MatchResult.win, MatchEndReason.disconnected), 'Riya left the game');
      expect(reason(MatchResult.loss, MatchEndReason.disconnected), 'You were away too long');
      expect(reason(MatchResult.win, MatchEndReason.noShow), 'Riya didn\'t show up');
      expect(reason(MatchResult.draw, MatchEndReason.endedByHost), 'The host ended the game');
    });
  });

  test('aborted and voided games explain themselves, with refunds for casual', () {
    expect(
      LiveText.aborted(opponent: 'Riya', iWasReady: true, casual: true),
      'Riya didn\'t join · 5 coins returned',
    );
    expect(
      LiveText.aborted(opponent: 'Riya', iWasReady: false, casual: false),
      'You didn\'t get ready in time',
    );
    expect(LiveText.voided(casual: true), endsWith('5 coins returned'));
    expect(LiveText.voided(casual: false), contains('ratings and coins didn\'t change'));
  });

  test('the rank line', () {
    expect(
      LiveText.rankLine(const RankMoved(board: 'rating:physics', before: 47, after: 42)),
      'You\'re now #42 in Physics · ↑5',
    );
    expect(
      LiveText.rankLine(const RankMoved(board: 'rating:physics', before: 40, after: 43)),
      'You\'re now #43 in Physics · ↓3',
    );
    expect(
      LiveText.rankLine(const RankMoved(board: 'rating:overall', before: 9, after: 9)),
      'You\'re #9 overall',
    );
    expect(
      LiveText.rankLine(const RankMoved(board: 'weekly:physics', after: 12)),
      'You\'re #12 in Physics this week',
    );
    expect(
      LiveText.rankLine(const RankPending(board: 'rating:physics', gamesToRank: 6)),
      'Play 6 more rated battles to get ranked',
    );
    expect(
      LiveText.rankLine(const RankPending(board: 'rating:physics', gamesToRank: 1)),
      'Play 1 more rated battle to get ranked',
    );
  });

  group('who was faster', () {
    test('from both times, to a tenth of a second', () {
      expect(_speed(_reveal()), 'You were 1.2 s faster');
      expect(_speed(_reveal(myMs: 6000)), 'Riya was 0.8 s faster');
    });

    test('the same speed', () {
      expect(_speed(_reveal(mySpeed: Speed.even, theirMs: 4100)), 'Same speed');
      expect(_speed(_reveal(theirMs: 4020)), 'Same speed');
    });

    test('from the label when times are missing', () {
      expect(_speed(_reveal(myMs: null, mySpeed: Speed.fast)), 'You were faster');
      expect(_speed(_reveal(myMs: null, mySpeed: Speed.slow)), 'Riya was faster');
    });

    test('when only one answered', () {
      expect(_speed(_reveal(theirOpt: null, theirMs: null)), 'Riya didn\'t answer');
      expect(_speed(_reveal(myOpt: null, myMs: null)), 'Riya answered, you didn\'t');
      expect(_speed(_reveal(myOpt: null, theirOpt: null)), isNull);
    });

    test('never in bot games', () {
      expect(_speed(_reveal(), bot: true), isNull);
    });
  });

  test('points and time', () {
    expect(LiveText.points(132), '+132');
    expect(LiveText.points(0), 'No points');
    expect(LiveText.mmss(const Duration(seconds: 32)), '0:32');
    expect(LiveText.mmss(const Duration(minutes: 4, seconds: 5)), '4:05');
    expect(LiveText.mmss(const Duration(seconds: -3)), '0:00');
  });
}
