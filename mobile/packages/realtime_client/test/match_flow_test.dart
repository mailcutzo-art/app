import 'package:fake_async/fake_async.dart';
import 'package:realtime_client/realtime_client.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';
import 'support/frames.dart';
import 'support/harness.dart';
import 'support/match_script.dart';

const me = 'u1';
const them = 'u2';

/// A fake `rt` server for one match: keeps the match log for replays, and answers `mm.join`,
/// `match.ready` and `ans.submit` (with `dup` for repeats, like `answer.lua`).
final class MatchServer {
  MatchServer(this.h, this.script) {
    h.onMessage = _onMessage;
  }

  final Harness h;
  final MatchScript script;

  /// Every event emitted on the match channel, in seq order.
  final List<Map<String, Object?>> log = [];

  /// When false, a resume gets a snapshot instead of a replay.
  bool logReachesBack = true;

  /// Builds the snapshot sent when the log doesn't reach back.
  Map<String, Object?> Function()? snapshot;

  /// Swallows the next `ans.ack`, as if the socket died before it went out.
  bool dropNextAck = false;
  final Map<int, String> answers = {};

  /// Emits a match event: logged, and delivered if the client is connected.
  void emit(Map<String, Object?> frame) {
    log.add(frame);
    h.push(frame);
  }

  void _onMessage(FakeSocket socket, Map<String, Object?> message) {
    final id = message['id']! as String;
    final data = message['d']! as Map<String, Object?>;
    switch (message['t']) {
      case 'hello':
        for (final entry in (data['resume']! as List<Object?>).cast<Map<String, Object?>>()) {
          if (entry['ch'] != script.channel) continue;
          final lastSeq = entry['last_seq']! as int;
          if (logReachesBack) {
            log.where((f) => (f['seq']! as int) > lastSeq).forEach(socket.push);
          } else {
            socket.push(snapshot!());
          }
        }
      case 'mm.join':
        socket.push(
          frame('mm.queued', {
            'ticket_id': 'T1',
            'mode': data['mode'],
            'subject': data['subject'],
            'chapter': data['chapter'],
            'joined_at': h.serverNowMs,
          }, 'u'),
        );
      case 'match.ready':
        socket.push(frame('ack', {'ref': id}));
      case 'ans.submit':
        final q = data['q']! as int;
        final first = !answers.containsKey(q);
        answers.putIfAbsent(q, () => data['opt']! as String);
        if (dropNextAck) {
          dropNextAck = false;
          return;
        }
        socket.push(script.ansAck(id, q, first ? 'accepted' : 'dup'));
    }
  }
}

void main() {
  test('a Quick Battle end to end: queue, play, drop, replay, restart, snapshot, result', () {
    fakeAsync((async) {
      final h = Harness(async);
      final s = MatchScript();
      final server = MatchServer(h, s);
      var state = const MatchState.initial('M1');
      final delivered = <ServerEvent>[];
      h.connection.events.listen((event) {
        delivered.add(event);
        state = reduceMatch(state, event, me: me);
      });

      /// I pick [opt] for question [q], optimistically and on the wire.
      Outcome<AnsAckEvent> answer(int q, String opt, int elMs) {
        state = selectAnswer(state, q: q, opt: opt);
        final outcome = Outcome(h.connection.submitAnswer('M1', q, opt, elMs));
        h.flush();
        return outcome;
      }

      h.connection.setAppForeground(true);
      final tab = h.open(reason: 'battle-tab');

      // C → mm.join ← mm.queued, mm.status, mm.found.
      final join = Outcome(
        h.connection.request('mm.join', {
          'mode': 'rated',
          'subject': 'physics',
          'chapter': 'kinematics',
          'idem': 'j-1',
        }),
      );
      h.flush();
      expect(join.value.reply, isA<MmQueuedEvent>());
      h
        ..push(frame('mm.status', {'waited_s': 15, 'widened': true}, 'u'))
        ..push(
          frame('mm.found', {
            'match_id': 'M1',
            'ch': 'm:M1',
            'mode': 'rated',
            'opponent': card(them),
            'sources': [
              {'chapter': 'kinematics', 'count': 4},
              {'chapter': 'laws-of-motion', 'count': 3},
            ],
          }, 'u'),
        );
      final matchLease = h.connection.acquire('match:M1', inMatch: true);
      expect(h.connection.resumeList, const [ResumeEntry('m:M1', 0)]);

      // (m:) match.snapshot {ready_wait}; C → match.ready ← match.phase {countdown}.
      server.emit(s.snapshot(phase: 'ready_wait'));
      expect(state.phase, MatchPhase.readyWait);
      final ready = Outcome(h.connection.request('match.ready', {'match_id': 'M1'}));
      h.flush();
      expect(ready.value.reply, isA<AckEvent>());
      server.emit(s.phase('countdown', endsAt: s.t0 + 3000));
      expect(state.phase, MatchPhase.countdown);

      // Q1 and Q2 go normally.
      var totals = (me: (0, 0), them: (0, 0));
      for (final q in [1, 2]) {
        server.emit(s.show(q));
        final outcome = answer(q, s.correctOption(q), 5000);
        expect(outcome.value.status, AnswerStatus.accepted);
        server
          ..emit(s.progress(q, [me]))
          ..emit(s.progress(q, [me, them]));
        totals = (me: (totals.me.$1 + 140, q), them: totals.them);
        server.emit(
          s.reveal(
            q,
            picks: {
              me: (s.correctOption(q), 140, 5000, 'fast'),
              them: (s.option(q, 0), 0, 7000, 'slow'),
            },
            totals: {me: totals.me, them: totals.them},
          ),
        );
        expect(state.phase, MatchPhase.qReveal);
        expect(state.myAnswer!.status, AnswerStatus.accepted);
      }
      expect(state.totalsOf(me), const PlayerTotals(points: 280, correct: 2));

      // Q3: I answer, and the socket dies before the ack reaches me.
      server.emit(s.show(3));
      server.dropNextAck = true;
      final answer3 = answer(3, s.correctOption(3), 4200);
      final id3 = h.lastIdOf('ans.submit');
      final lastSeq = h.connection.lastSeq('m:M1')!;
      final dropped = h.socket..closeFromServer(1013);
      h.flush();
      expect(h.state, isA<Backoff>());
      expect(h.retryIn, lessThanOrEqualTo(const Duration(seconds: 2)), reason: 'in-match cap');

      // The match clock never pauses: these happen while I'm away.
      server
        ..emit(s.progress(3, [me]))
        ..emit(s.progress(3, [me, them]));
      expect(state.answered, isEmpty, reason: 'nothing arrives while disconnected');

      h.elapse(h.retryIn);
      expect(h.state, isA<Open>());
      final rejoined = h.socket;
      expect(rejoined, isNot(same(dropped)));
      final hello = rejoined.sentOfType('hello').single['d']! as Map<String, Object?>;
      expect(hello['resume'], [
        {'ch': 'm:M1', 'last_seq': lastSeq},
      ]);
      expect(rejoined.sentOfType('client.state').single['d'], {'state': 'foreground'});
      expect(rejoined.sentOfType('ans.submit').single['id'], id3, reason: 'resent with its id');
      expect(answer3.value.status, AnswerStatus.dup, reason: 'the server already had it');
      expect(state.answered, {me, them}, reason: 'replayed from the log');
      expect(state.myAnswer, MyAnswer(q: 3, opt: s.correctOption(3), status: AnswerStatus.dup));
      totals = (me: (420, 3), them: (0, 0));
      server.emit(
        s.reveal(
          3,
          picks: {me: (s.correctOption(3), 140, 4200, 'fast'), them: (null, 0, null, 'slow')},
          totals: {me: totals.me, them: totals.them},
        ),
      );

      // Q4: the opponent drops for a while.
      server
        ..emit(s.show(4))
        ..emit(s.oppConn(them, 'reconnecting', graceUntil: s.shownAt(4) + 30000));
      expect(state.players[them]!.presence, Presence.reconnecting);
      answer(4, s.option(4, 1), 3000);
      server
        ..emit(s.oppConn(them, 'connected'))
        ..emit(
          s.reveal(
            4,
            picks: {me: (s.option(4, 1), 0, 3000, 'fast'), them: (null, 0, null, 'slow')},
            totals: {me: totals.me, them: totals.them},
          ),
        );
      expect(state.players[them]!.presence, Presence.connected);

      // Q5: the server restarts (1012) and the log no longer reaches back: resume by snapshot.
      server.emit(s.show(5));
      h.socket.closeFromServer(1012);
      h.flush();
      expect(h.retryIn, lessThanOrEqualTo(const Duration(seconds: 2)));
      server
        ..logReachesBack = false
        ..emit(s.progress(5, [them]))
        ..emit(
          s.reveal(
            5,
            picks: {me: (null, 0, null, 'slow'), them: (s.correctOption(5), 145, 2000, 'fast')},
            totals: {me: totals.me, them: (145, 1)},
          ),
        );
      server.snapshot = () => s.snapshot(
        phase: 'q_reveal',
        q: 5,
        withQuestion: true,
        scores: {me: 420, them: 145},
        reveal: s.revealData(
          5,
          picks: {me: (null, 0, null, 'slow'), them: (s.correctOption(5), 145, 2000, 'fast')},
          totals: {me: totals.me, them: (145, 1)},
        ),
        mine: [
          for (final q in [1, 2, 3]) {'q': q, 'opt': s.correctOption(q), 'status': 'accepted'},
          {'q': 4, 'opt': s.option(4, 1), 'status': 'accepted'},
        ],
      );
      h.elapse(h.retryIn);
      expect(h.state, isA<Open>());
      expect(state.phase, MatchPhase.qReveal);
      expect(state.q, 5);
      expect(state.currentReveal!.players[them]!.pts, 145);
      expect(state.myAnswer, isNull, reason: 'I missed question 5');
      expect(state.mine.keys, [1, 2, 3, 4]);
      expect(state.totalsOf(them), const PlayerTotals(points: 145, correct: 1));
      server.logReachesBack = true;

      // Q6 and Q7.
      for (final q in [6, 7]) {
        server.emit(s.show(q));
        answer(q, s.correctOption(q), 2500);
        server.emit(
          s.reveal(
            q,
            picks: {
              me: (s.correctOption(q), 145, 2500, 'fast'),
              them: (s.option(q, 0), 0, 9000, 'slow'),
            },
            totals: {me: (420 + 145 * (q - 5), 3 + q - 5), them: (145, 1)},
          ),
        );
      }

      // ← match.end {result: win}, ← match.settled.
      server.emit(s.end(result: 'win', totals: {me: (710, 5), them: (145, 1)}));
      expect(state.phase, MatchPhase.finished);
      expect(state.end!.result, MatchResult.win);
      expect(state.awaitingSettlement, isTrue);
      server.emit(s.settled());
      expect(state.settlement!.rating!.delta, 16);
      expect(state.totalsOf(me), const PlayerTotals(points: 710, correct: 5));

      // Every match event arrived once and in order: snapshots aside, seqs only go up.
      final matchSeqs = [
        for (final e in delivered)
          if (e.channel == 'm:M1' && e.seq != null && e is! MatchSnapshotEvent) e.seq!,
      ];
      expect(matchSeqs.toSet(), hasLength(matchSeqs.length));
      for (var i = 1; i < matchSeqs.length; i++) {
        expect(matchSeqs[i], greaterThan(matchSeqs[i - 1]));
      }
      expect(h.connection.pendingAnswers, 0);
      expect(h.connection.protocolErrors, 0);

      // Done: forget the match and let the socket go.
      h.connection.forgetChannel('m:M1');
      matchLease.release();
      tab.release();
      expect(h.connection.resumeList, isEmpty);
      h.dispose();
    });
  });
}
