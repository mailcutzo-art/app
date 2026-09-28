import 'package:realtime_client/realtime_client.dart';
import 'package:test/test.dart';

import 'support/frames.dart';
import 'support/match_script.dart';

const me = 'u1';
const them = 'u2';

/// Everything the UI reads from a state, for comparing two runs.
Map<String, Object?> summary(MatchState s) => {
  'match': s.matchId,
  'phase': s.phase,
  'endsAt': s.endsAt,
  'q': s.q,
  'total': s.total,
  'players': [for (final p in s.players.values) (p.uid, p.presence, p.graceUntil)],
  'question': s.question?.q,
  'mine': [for (final e in s.mine.entries) (e.key, e.value.opt, e.value.status)],
  'answered': s.answered.toList(),
  'reveal': s.reveal?.q,
  'standings': [for (final g in s.standings) (g.uid, g.place)],
  'totals': [for (final e in s.totals.entries) (e.key, e.value.points, e.value.correct)],
  'emote': (s.lastEmote?.uid, s.lastEmote?.emote, s.lastEmote?.serial),
  'end': (s.end?.result, s.end?.reason, s.endedAt),
  'settled': (s.settlement?.coins?.balance, s.settledOnServer),
  'rematch': (s.rematch, s.rematchFailure),
};

/// Applies frames and local answer selections, keeping a log to replay.
final class Player {
  MatchState state = const MatchState.initial('M1');
  final List<Object> steps = [];

  MatchState frame(Map<String, Object?> frame) {
    steps.add(frame);
    return state = reduceMatch(state, decodeFrame(frame), me: me);
  }

  MatchState select(int q, String opt) {
    steps.add((q, opt));
    return state = selectAnswer(state, q: q, opt: opt);
  }

  static MatchState replay(List<Object> steps) {
    var state = const MatchState.initial('M1');
    for (final step in steps) {
      state = switch (step) {
        final Map<String, Object?> f => reduceMatch(state, decodeFrame(f), me: me),
        (final int q, final String opt) => selectAnswer(state, q: q, opt: opt),
        _ => throw StateError('bad step $step'),
      };
    }
    return state;
  }
}

void main() {
  group('a scripted Quick Battle', () {
    test('7 questions with a drop and a resume, as in docs/protocol.md section 11', () {
      final s = MatchScript();
      final p = Player();

      // u: mm.found. Not a match-channel event, so nothing changes.
      p.frame(frame('mm.found', {'match_id': 'M1', 'ch': 'm:M1', 'opponent': card(them)}, 'u'));
      expect(p.state.phase, MatchPhase.unknown);

      // (m:) match.snapshot {phase: ready_wait}
      var state = p.frame(s.snapshot(phase: 'ready_wait'));
      expect(state.phase, MatchPhase.readyWait);
      expect(state.kind, 'quick_rated');
      expect(state.q, 0);
      expect(state.total, 7);
      expect(state.limitMs, 15000);
      expect(state.players.keys, [me, them]);
      expect(state.opponentsOf(me).single.card.displayName, 'Player u2');
      expect(state.question, isNull);
      expect(state.totalsOf(me), PlayerTotals.zero);

      // match.ready → match.phase {countdown, ends_at}
      state = p.frame(s.phase('countdown', endsAt: s.t0 + 3000));
      expect(state.phase, MatchPhase.countdown);
      expect(state.endsAt, s.t0 + 3000);

      // Q1: q.show; the question stays hidden until the synced clock reaches shown_at.
      state = p.frame(s.show(1));
      expect(state.phase, MatchPhase.qOpen);
      expect(state.q, 1);
      expect(state.question!.stem, 'Question 1?');
      expect(state.question!.options.map((o) => o.id), [
        for (var i = 0; i < 4; i++) s.option(1, i),
      ]);
      expect(state.endsAt, s.deadlineAt(1));
      expect(state.isQuestionRevealed(s.shownAt(1) - 400), isFalse);
      expect(state.isQuestionRevealed(s.shownAt(1)), isTrue);
      expect(state.question!.remainingMs(s.shownAt(1) + 5000), 10000);
      expect(state.myAnswer, isNull);

      // I tap an option: shown at once as pending, then ans.ack {accepted}.
      state = p.select(1, s.correctOption(1));
      expect(state.myAnswer, MyAnswer(q: 1, opt: s.correctOption(1), status: AnswerStatus.pending));
      state = p.frame(s.ansAck('c7', 1, 'accepted'));
      expect(state.myAnswer!.status, AnswerStatus.accepted);
      expect(state.myAnswer!.opt, s.correctOption(1));

      // q.progress shows who has answered, never what.
      state = p.frame(s.progress(1, [me]));
      expect(state.answered, {me});
      state = p.frame(s.progress(1, [me, them]));
      expect(state.answered, {me, them});

      state = p.frame(
        s.reveal(
          1,
          picks: {
            me: (s.correctOption(1), 132, 6010, 'fast'),
            them: (s.option(1, 0), 0, 7020, 'slow'),
          },
          totals: {me: (132, 1), them: (0, 0)},
        ),
      );
      expect(state.phase, MatchPhase.qReveal);
      expect(state.endsAt, isNull);
      final reveal1 = state.currentReveal!;
      expect(reveal1.correctOption, s.correctOption(1));
      expect(reveal1.players[me]!.pts, 132);
      expect(reveal1.players[me]!.timeMs, 6010);
      expect(reveal1.players[me]!.speed, Speed.fast);
      expect(reveal1.players[them]!.correct, isFalse);
      expect(reveal1.players[them]!.speed, Speed.slow);
      expect(reveal1.ref, 'ref-1');
      expect(state.totalsOf(me), const PlayerTotals(points: 132, correct: 1));

      // Q2: my answer arrives late.
      state = p.frame(s.show(2));
      expect(state.q, 2);
      expect(state.answered, isEmpty, reason: 'progress starts over');
      expect(state.myAnswer, isNull);
      expect(state.currentReveal, isNull);
      expect(state.reveal!.q, 1, reason: 'the last reveal is kept for the leaderboard');
      p
        ..select(2, s.option(2, 0))
        ..frame(s.progress(2, [them]))
        ..frame(s.ansAck('c9', 2, 'late'));
      state = p.frame(
        s.reveal(
          2,
          picks: {
            me: (s.option(2, 0), 0, 15300, 'slow'),
            them: (s.correctOption(2), 145, 1900, 'fast'),
          },
          totals: {me: (132, 1), them: (145, 1)},
        ),
      );
      expect(state.mine[2], MyAnswer(q: 2, opt: s.option(2, 0), status: AnswerStatus.late));
      expect(state.totalsOf(them), const PlayerTotals(points: 145, correct: 1));

      // Q3: the opponent drops and comes back, and sends emotes.
      p.frame(s.show(3));
      state = p.frame(s.oppConn(them, 'reconnecting', graceUntil: s.shownAt(3) + 30000));
      expect(state.players[them]!.presence, Presence.reconnecting);
      expect(state.players[them]!.graceUntil, s.shownAt(3) + 30000);
      expect(state.players[me]!.presence, Presence.connected);
      p
        ..select(3, s.correctOption(3))
        ..frame(s.ansAck('c11', 3, 'accepted'))
        ..frame(s.progress(3, [me]));
      state = p.frame(s.oppConn(them, 'connected'));
      expect(state.players[them]!.presence, Presence.connected);
      expect(state.players[them]!.graceUntil, isNull);
      state = p.frame(s.emote(them, 'wow'));
      expect(state.lastEmote!.emote, 'wow');
      expect(state.lastEmote!.serial, 1);
      state = p.frame(s.emote(them, 'wow'));
      expect(state.lastEmote!.serial, 2, reason: 'the same emote again still animates');
      p.frame(
        s.reveal(
          3,
          picks: {me: (s.correctOption(3), 120, 9500, 'fast'), them: (null, 0, null, 'slow')},
          totals: {me: (252, 2), them: (145, 1)},
        ),
      );

      // Q4: I answer, then my connection drops before the ack. The log no longer reaches back,
      // so the server resumes me with a snapshot, which replaces the state entirely.
      p
        ..frame(s.show(4))
        ..select(4, s.correctOption(4));
      expect(p.state.myAnswer!.status, AnswerStatus.pending);
      // What happened while I was away (never applied here):
      s
        ..progress(4, [me])
        ..progress(4, [me, them]);
      state = p.frame(
        s.snapshot(
          phase: 'q_open',
          q: 4,
          endsAt: s.deadlineAt(4),
          scores: {me: 252, them: 145},
          correct: {me: 2, them: 1},
          answered: {me, them},
          withQuestion: true,
          reveal: s.revealData(
            3,
            picks: {me: (s.correctOption(3), 120, 9500, 'fast'), them: (null, 0, null, 'slow')},
            totals: {me: (252, 2), them: (145, 1)},
          ),
          mine: [
            {'q': 1, 'opt': s.correctOption(1), 'status': 'accepted'},
            {'q': 2, 'opt': s.option(2, 0), 'status': 'late'},
            {'q': 3, 'opt': s.correctOption(3), 'status': 'accepted'},
            {'q': 4, 'opt': s.correctOption(4), 'status': 'accepted'},
          ],
        ),
      );
      expect(state.phase, MatchPhase.qOpen);
      expect(state.q, 4);
      expect(state.question!.q, 4);
      expect(state.endsAt, s.deadlineAt(4));
      expect(
        state.myAnswer,
        MyAnswer(q: 4, opt: s.correctOption(4), status: AnswerStatus.accepted),
      );
      expect(state.mine.keys, [1, 2, 3, 4]);
      expect(state.answered, {me, them});
      expect(state.reveal!.q, 3);
      expect(state.totalsOf(me), const PlayerTotals(points: 252, correct: 2));
      expect(state.totalsOf(them), const PlayerTotals(points: 145, correct: 1));
      expect(state.lastEmote, isNull, reason: 'a snapshot replaces everything');
      expect(state.players[them]!.presence, Presence.connected);

      state = p.frame(
        s.reveal(
          4,
          picks: {
            me: (s.correctOption(4), 138, 4700, 'even'),
            them: (s.correctOption(4), 139, 4600, 'even'),
          },
          totals: {me: (390, 3), them: (284, 2)},
        ),
      );
      expect(state.currentReveal!.players[me]!.speed, Speed.even);

      // Q5: the 2 s resend races the first ack; the repeat carries the same verdict, with dup.
      p
        ..frame(s.show(5))
        ..select(5, s.correctOption(5))
        ..frame(s.ansAck('c3', 5, 'accepted'));
      state = p.frame(s.ansAck('c3', 5, 'accepted', dup: true));
      expect(state.myAnswer!.status, AnswerStatus.accepted);
      p.frame(
        s.reveal(
          5,
          picks: {
            me: (s.correctOption(5), 141, 3900, 'fast'),
            them: (s.option(5, 3), 0, 6000, 'slow'),
          },
          totals: {me: (531, 4), them: (284, 2)},
        ),
      );

      // Q6: tapped before the question went live on the server.
      p
        ..frame(s.show(6))
        ..select(6, s.option(6, 0));
      state = p.frame(s.ansAck('c5', 6, 'too_early'));
      expect(state.myAnswer!.status, AnswerStatus.tooEarly);
      p.frame(
        s.reveal(
          6,
          picks: {
            me: (s.option(6, 0), 0, 0, 'fast'),
            them: (s.correctOption(6), 133, 5200, 'slow'),
          },
          totals: {me: (531, 4), them: (417, 3)},
        ),
      );

      // Q7: I don't answer in time.
      p.frame(s.show(7));
      state = p.frame(s.progress(7, [them]));
      expect(state.answered, {them});
      state = p.frame(
        s.reveal(
          7,
          picks: {me: (null, 0, null, 'slow'), them: (s.option(7, 1), 0, 8000, 'fast')},
          totals: {me: (531, 4), them: (417, 3)},
        ),
      );
      expect(state.myAnswer, isNull);
      expect(state.currentReveal!.players[me]!.opt, isNull);

      // match.end {result: win}, then match.settled (to me alone, without a seq).
      final endFrame = s.end(result: 'win', totals: {me: (531, 4), them: (417, 3)});
      state = p.frame(endFrame);
      expect(state.phase, MatchPhase.finished);
      expect(state.isOver, isTrue);
      expect(state.end!.result, MatchResult.win);
      expect(state.end!.reason, MatchEndReason.normal);
      expect(state.end!.ranking, [
        [me],
        [them],
      ]);
      expect(state.awaitingSettlement, isTrue, reason: 'shows "Results syncing…"');
      final endedAt = endFrame['ts']! as int;
      expect(state.endedAt, endedAt);
      expect(state.settledOnServer, isFalse);
      expect(state.needsSettlementFetch(endedAt + 19999), isFalse);
      expect(state.needsSettlementFetch(endedAt + 20000), isTrue, reason: 'REST after 20 s');

      state = p.frame(s.settled());
      expect(state.awaitingSettlement, isFalse);
      expect(state.settledOnServer, isTrue);
      expect(state.needsSettlementFetch(endedAt + 60000), isFalse);
      expect(state.settlement!.rating!.after, '1518?');
      expect(state.settlement!.coins!.balance, 245);
      expect(state.settlement!.xp!.delta, 30);
      expect(state.settlement!.missions.single.progress, 2);

      // Deterministic: replaying the same steps gives the same state.
      expect(summary(Player.replay(p.steps)), summary(state));
      expect(summary(Player.replay(p.steps)), summary(Player.replay(p.steps)));
    });
  });

  group('reduceMatch', () {
    late MatchScript s;
    late Player p;

    setUp(() {
      s = MatchScript();
      p = Player()..frame(s.snapshot(phase: 'ready_wait'));
    });

    test('ignores events for other matches', () {
      final other = MatchScript(matchId: 'M2');
      final before = p.state;

      p
        ..frame(other.snapshot(phase: 'q_open', q: 3))
        ..frame(other.show(1))
        ..frame(frame('rematch.status', {'match_id': 'M2', 'state': 'offered', 'by': them}, 'u'))
        ..frame(other.settled());

      expect(p.state, same(before));
    });

    test("a settlement naming another match never lands, even on this match's channel", () {
      final before = p.state;

      p.frame(s.settled(matchId: 'M2'));
      expect(p.state, same(before));

      // Without match_id, the channel decides.
      final unnamed = s.settled()['d']! as Map<String, Object?>;
      p.frame(frame('match.settled', {...unnamed}..remove('match_id'), 'm:M2'));
      expect(p.state, same(before));
      p.frame(frame('match.settled', {...unnamed}..remove('match_id'), 'm:M1'));
      expect(p.state.settlement, isNotNull);
    });

    test('a snapshot of a finished match restores the end and the settlement flag', () {
      final state = p.frame(
        s.snapshot(
          phase: 'q_reveal',
          q: 7,
          scores: {me: 400, them: 200},
          end: s.endData(result: 'loss', reason: 'forfeit', totals: {me: (400, 3), them: (620, 5)}),
          settled: true,
        ),
      );

      expect(state.phase, MatchPhase.finished, reason: 'the end decides the phase');
      expect(state.isOver, isTrue);
      expect(state.end!.result, MatchResult.loss);
      expect(state.end!.reason, MatchEndReason.forfeit);
      expect(state.endsAt, isNull);
      expect(state.totalsOf(them), const PlayerTotals(points: 620, correct: 5));
      expect(state.settledOnServer, isTrue);
      expect(state.endedAt, isNull);
      expect(state.needsSettlementFetch(0), isTrue, reason: 'settled, but match.settled is gone');
    });

    test('a snapshot with an unsettled end asks for REST at once: the app was away', () {
      final state = p.frame(
        s.snapshot(
          phase: 'aborted',
          end: s.endData(result: 'draw', reason: 'aborted', totals: {}),
        ),
      );

      expect(state.phase, MatchPhase.aborted);
      expect(state.totalsOf(me), PlayerTotals.zero);
      expect(state.settledOnServer, isFalse);
      expect(state.needsSettlementFetch(0), isTrue);
    });

    test('a running match never needs a settlement fetch', () {
      p.frame(s.show(1));

      expect(p.state.needsSettlementFetch(s.t0 + 3600000), isFalse);
      expect(p.state.settledOnServer, isFalse);
    });

    test('ignores events that are not about a match', () {
      final before = p.state;

      p
        ..frame(frame('mm.status', {'waited_s': 3}, 'u'))
        ..frame(frame('lb.update', {}, 'u'))
        ..frame(
          frame(
            'room.state',
            {
              'room_id': 'R1',
              'kind': 'friend',
              'host': me,
              'status': 'lobby',
              'members': <Object?>[],
            },
            'r:R1',
            3,
          ),
        );

      expect(p.state, same(before));
    });

    test('starts from an empty state without a match id', () {
      final state = reduceMatch(
        const MatchState(),
        decodeFrame(s.snapshot(phase: 'countdown')),
        me: me,
      );

      expect(state.matchId, 'M1');
      expect(state.phase, MatchPhase.countdown);
    });

    test('selectAnswer only takes an option of the open question, once', () {
      p.frame(s.show(1));

      expect(selectAnswer(p.state, q: 2, opt: s.option(1, 0)), same(p.state));
      expect(selectAnswer(p.state, q: 1, opt: 'nope'), same(p.state));
      final picked = p.select(1, s.option(1, 2));
      expect(selectAnswer(picked, q: 1, opt: s.option(1, 3)), same(picked));

      p.frame(s.reveal(1, picks: {}, totals: {}));
      expect(selectAnswer(p.state, q: 1, opt: s.option(1, 3)).myAnswer!.opt, s.option(1, 2));
    });

    test('a repeated ack carries the verdict, even when the first ack was lost', () {
      p
        ..frame(s.show(1))
        ..select(1, s.option(1, 1))
        ..frame(s.ansAck('c1', 1, 'late', dup: true));

      expect(p.state.myAnswer, MyAnswer(q: 1, opt: s.option(1, 1), status: AnswerStatus.late));
    });

    test('a legacy status "dup" keeps the verdict, or counts as locked in without one', () {
      p
        ..frame(s.show(1))
        ..select(1, s.option(1, 1))
        ..frame(s.ansAck('c1', 1, 'dup'));
      expect(p.state.myAnswer!.status, AnswerStatus.dup);
      expect(p.state.myAnswer!.opt, s.option(1, 1));

      p
        ..frame(s.ansAck('c1', 1, 'accepted'))
        ..frame(s.ansAck('c1', 1, 'dup'));
      expect(p.state.myAnswer!.status, AnswerStatus.accepted);
    });

    test('knows I answered when the server says so, even without a local pick', () {
      p
        ..frame(s.show(1))
        ..frame(s.progress(1, [me]));
      expect(p.state.myAnswer, const MyAnswer(q: 1, opt: null, status: AnswerStatus.unknown));

      p.frame(s.ansAck('c4', 1, 'accepted'));
      expect(p.state.myAnswer!.status, AnswerStatus.accepted);

      p.frame(s.reveal(1, picks: {me: (s.option(1, 3), 0, 5000, null)}, totals: {me: (0, 0)}));
      expect(p.state.mine[1], MyAnswer(q: 1, opt: s.option(1, 3), status: AnswerStatus.accepted));
    });

    test('a snapshot where I answered but mine lacks the question', () {
      final state = p.frame(s.snapshot(phase: 'q_open', q: 2, withQuestion: true, answered: {me}));

      expect(state.myAnswer, const MyAnswer(q: 2, opt: null, status: AnswerStatus.unknown));
    });

    test('ignores stale question events', () {
      p
        ..frame(s.show(1))
        ..frame(s.show(2));
      final state = p.state;

      p
        ..frame(s.show(1))
        ..frame(s.progress(1, [me, them]))
        ..frame(s.reveal(1, picks: {}, totals: {me: (500, 5)}));

      expect(summary(p.state), summary(state));
    });

    test('the same q.show twice keeps the progress', () {
      p
        ..frame(s.show(1))
        ..frame(s.progress(1, [them]))
        ..frame(s.show(1));

      expect(p.state.answered, {them});
    });

    test('opp.conn for a player the state does not know yet adds them', () {
      p.frame(s.oppConn('u3', 'left'));

      expect(p.state.players['u3']!.presence, Presence.left);
      expect(p.state.players.keys, [me, them, 'u3']);
    });

    test('match.phase moves the phase, question and deadline', () {
      p.frame(s.phase('q_open', q: 2, endsAt: s.deadlineAt(2)));

      expect(p.state.phase, MatchPhase.qOpen);
      expect(p.state.q, 2);
      expect(p.state.endsAt, s.deadlineAt(2));
    });

    final endings = {
      'aborted': MatchPhase.aborted,
      'voided': MatchPhase.voided,
      'forfeit': MatchPhase.finished,
      'opponent_forfeit': MatchPhase.finished,
      'left': MatchPhase.finished,
      'no_show': MatchPhase.finished,
      'ended_by_host': MatchPhase.finished,
    };
    for (final MapEntry(key: reason, value: phase) in endings.entries) {
      test('match.end with reason $reason ends in ${phase.name}', () {
        final state = p.frame(s.end(result: 'loss', reason: reason, totals: {}));

        expect(state.phase, phase);
        expect(state.isOver, isTrue);
        expect(state.end!.reason, MatchEndReason.parse(reason));
        expect(state.totals, p.state.totals, reason: 'empty totals keep the running ones');
      });
    }

    group('rematch', () {
      MatchState status(String state, {String? by, String? reason}) => p.frame(
        frame(
          'rematch.status',
          {'match_id': 'M1', 'state': state, 'by': by, 'reason': reason},
          'm:M1',
          99,
        ),
      );

      setUp(() => p.frame(s.end(result: 'win', totals: {})));

      test('starts as none', () {
        expect(p.state.rematch, Rematch.none);
      });

      test('offered by me or by them', () {
        expect(status('offered', by: me).rematch, Rematch.offeredByMe);
        expect(status('offered', by: them).rematch, Rematch.offeredByThem);
      });

      test('accepted, declined, expired', () {
        expect(status('accepted', by: them).rematch, Rematch.accepted);
        expect(status('declined', by: them).rematch, Rematch.declined);
        expect(status('expired').rematch, Rematch.expired);
        expect(p.state.rematchFailure, isNull);
      });

      test('failed, with the reason', () {
        final state = status('failed', by: me, reason: 'insufficient_coins');

        expect(state.rematch, Rematch.failed);
        expect(state.rematchFailure, 'insufficient_coins');
        expect(status('offered', by: them).rematchFailure, isNull);
      });

      test('ignores states it does not know', () {
        status('offered', by: them);

        expect(status('paused').rematch, Rematch.offeredByThem);
      });

      test('arrives on the user channel too', () {
        p.frame(frame('rematch.status', {'match_id': 'M1', 'state': 'offered', 'by': them}, 'u'));

        expect(p.state.rematch, Rematch.offeredByThem);
      });
    });

    test('group standings come with the reveal and stay until the next ones', () {
      final g = MatchScript(matchId: 'G1');
      final group = Player()..state = const MatchState.initial('G1');
      group
        ..frame(g.snapshot(phase: 'q_open', q: 1, withQuestion: true))
        ..frame(
          frame(
            'q.reveal',
            {
              ...g.revealData(1, picks: {}, totals: {}),
              'standings': [
                {'uid': 'u3', 'points': 150, 'place': 1, 'change': 2},
                {'uid': me, 'points': 132, 'place': 2, 'change': -1},
              ],
            },
            'm:G1',
            5,
          ),
        );
      expect(
        [for (final x in group.state.standings) (x.uid, x.place, x.change)],
        [('u3', 1, 2), (me, 2, -1)],
      );

      group
        ..frame(g.show(2))
        ..frame(frame('q.reveal', g.revealData(2, picks: {}, totals: {}), 'm:G1', 7));
      expect(group.state.standings, hasLength(2));

      group.frame(
        g.snapshot(
          phase: 'q_reveal',
          q: 3,
          reveal: {
            ...g.revealData(3, picks: {}, totals: {}),
            'standings': [
              {'uid': me, 'points': 280, 'place': 1},
            ],
          },
        ),
      );
      expect(group.state.standings.single.uid, me);
    });

    test('a late joiner who only watches is not among the players', () {
      const players = {
        'u2': MatchPlayer(card: PlayerCard(uid: 'u2')),
        'u3': MatchPlayer(card: PlayerCard(uid: 'u3')),
      };
      expect(const MatchState(players: players).isSpectator(me), isTrue);
      expect(const MatchState(players: players).isSpectator('u2'), isFalse);
      expect(const MatchState().isSpectator(me), isFalse, reason: 'nothing known yet');
    });

    test('places come from the standings, or from the totals', () {
      const players = {
        me: MatchPlayer(card: PlayerCard(uid: me)),
        'u2': MatchPlayer(card: PlayerCard(uid: 'u2')),
        'u3': MatchPlayer(card: PlayerCard(uid: 'u3')),
      };
      const byTotals = MatchState(
        players: players,
        totals: {
          me: PlayerTotals(points: 250, correct: 2),
          'u2': PlayerTotals(points: 250, correct: 3),
          'u3': PlayerTotals(points: 120, correct: 1),
        },
      );
      expect([byTotals.placeOf(me), byTotals.placeOf('u2'), byTotals.placeOf('u3')], [2, 1, 3]);

      const byStandings = MatchState(
        players: players,
        standings: [
          GroupStanding(uid: 'u3', points: 300, place: 1),
          GroupStanding(uid: me, points: 250, place: 2),
        ],
      );
      expect(byStandings.placeOf(me), 2);
      expect(byStandings.placeOf('u2'), 1, reason: 'not in the standings: from the totals');
    });

    test('the state is immutable', () {
      final state = p.frame(s.show(1));

      expect(
        () => state.players[me] = const MatchPlayer(card: PlayerCard(uid: 'x')),
        throwsUnsupportedError,
      );
      expect(() => state.answered.add(me), throwsUnsupportedError);
      expect(
        () => state.mine[1] = const MyAnswer(q: 1, opt: 'a', status: AnswerStatus.pending),
        throwsUnsupportedError,
      );
      expect(() => state.totals[me] = PlayerTotals.zero, throwsUnsupportedError);
    });
  });
}
