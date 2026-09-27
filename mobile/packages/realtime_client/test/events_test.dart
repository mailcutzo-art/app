import 'package:realtime_client/realtime_client.dart';
import 'package:test/test.dart';

import 'support/frames.dart';
import 'support/match_script.dart';

void main() {
  final script = MatchScript();

  group('system messages', () {
    test('welcome', () {
      final welcome = event(
        'welcome',
        welcomeData(
          active: [
            {'kind': 'match', 'ch': 'm:M1', 'state': 'q_open'},
            {'kind': 'queue', 'ticket_id': 'T1'},
          ],
        ),
        'u',
      );

      expect(welcome, isA<WelcomeEvent>());
      welcome as WelcomeEvent;
      expect(welcome.userId, 'u1');
      expect(welcome.connId, 'k9');
      expect(welcome.serverMs, 1790000000000);
      expect(welcome.hbS, 10);
      expect(welcome.active.first.kind, ActiveKind.match);
      expect(welcome.active.first.channel, 'm:M1');
      expect(welcome.active.first.state, 'q_open');
      expect(welcome.active.last.kind, ActiveKind.queue);
      expect(welcome.active.last.channel, isNull);
      expect(welcome.active.last.raw['ticket_id'], 'T1');
    });

    test('ping, hb and clock.pong', () {
      expect(event('ping', {'n': 7}), isA<PingEvent>().having((e) => e.n, 'n', 7));
      expect(event('hb', {'s': 5}, 'u'), isA<HbEvent>().having((e) => e.s, 's', 5));
      expect(
        event('clock.pong', {'c0': 100, 's': 1790000000123}),
        isA<ClockPongEvent>().having((e) => e.c0, 'c0', 100).having((e) => e.s, 's', 1790000000123),
      );
    });

    test('welcome without hb_s leaves the interval to the fallback', () {
      final welcome = event('welcome', welcomeData(hbS: null)) as WelcomeEvent;

      expect(welcome.hbS, isNull);
    });

    test('ack and error', () {
      expect(event('ack', {'ref': 'c7'}), isA<AckEvent>().having((e) => e.ref, 'ref', 'c7'));

      final error = event('error', {
        'ref': 'c7',
        'code': 'BUSY',
        'message': "You're already in a match.",
        'retryable': false,
        'details': {
          'active': {'kind': 'match', 'ch': 'm:M1'},
        },
      }) as ErrorEvent;
      final realtimeError = error.toError();
      expect(realtimeError.code, RealtimeErrorCode.busy);
      expect(realtimeError.ref, 'c7');
      expect(realtimeError.message, "You're already in a match.");
      expect(realtimeError.retryable, isFalse);
      expect(realtimeError.details['active'], {'kind': 'match', 'ch': 'm:M1'});
      expect(realtimeError.isClientSide, isFalse);

      final bare = event('error', {'code': 'UNAVAILABLE'}) as ErrorEvent;
      expect(bare.ref, isNull);
      expect(bare.message, '');
      expect(bare.retryable, isFalse);
    });

    test('RealtimeError reads the documented details', () {
      final matched = (event('error', {
        'ref': 'c3',
        'code': 'ALREADY_MATCHED',
        'details': {'match_id': 'M7'},
      }) as ErrorEvent).toError();
      final limited = (event('error', {
        'code': 'RATE_LIMITED',
        'retryable': true,
        'details': {'retry_after_s': 12},
      }) as ErrorEvent).toError();
      final cooldown = (event('error', {
        'code': 'COOLDOWN',
        'details': {'until': 1790000300000},
      }) as ErrorEvent).toError();

      expect(matched.matchId, 'M7');
      expect(limited.retryAfterSeconds, 12);
      expect(limited.retryable, isTrue);
      expect(cooldown.until, 1790000300000);
      expect(matched.toString(), 'RealtimeError(ALREADY_MATCHED ref=c3)');
    });

    test('a BUSY error says where the user is busy, typed', () {
      final busy = (event('error', {
        'ref': 'c4',
        'code': 'BUSY',
        'message': "You're in a tournament that starts soon.",
        'details': {
          'active': {
            'kind': 'tournament',
            'id': 'T1',
            'title': 'Physics Sunday Cup',
            'action': {'route': '/arena/T1'},
          },
        },
      }) as ErrorEvent).toError();

      final active = busy.active!;
      expect(active.kind, ActiveKind.tournament);
      expect(active.id, 'T1');
      expect(active.title, 'Physics Sunday Cup');
      expect(active.raw['action'], {'route': '/arena/T1'});

      const vague = RealtimeError(code: RealtimeErrorCode.busy, details: {'active': 'somewhere'});
      expect(vague.active, isNull);
      expect(const RealtimeError(code: RealtimeErrorCode.busy).active, isNull);
    });

    test('LIVE_ELSEWHERE carries the match on the other device', () {
      final error = (event('error', {
        'ref': 'c1',
        'code': 'LIVE_ELSEWHERE',
        'details': {'match_id': 'M3'},
      }) as ErrorEvent).toError();

      expect(error.code, RealtimeErrorCode.liveElsewhere);
      expect(error.matchId, 'M3');
    });
  });

  group('matchmaking (section 5)', () {
    test('mm.queued, mm.status, mm.timeout, mm.cancelled', () {
      final queued = event('mm.queued', {
        'ticket_id': 'T1',
        'mode': 'rated',
        'subject': 'physics',
        'chapter': null,
        'joined_at': 1790000000000,
      }, 'u') as MmQueuedEvent;
      expect(queued.ticketId, 'T1');
      expect(queued.chapter, isNull);

      final status =
          event('mm.status', {'waited_s': 17, 'widened': true, 'window': null}) as MmStatusEvent;
      expect(status.waitedS, 17);
      expect(status.widened, isTrue);
      expect(status.window, isNull);

      final timeout = event('mm.timeout', {
        'waited_s': 45,
        'options': ['keep', 'bot', 'invite', 'cancel'],
      }) as MmTimeoutEvent;
      expect(timeout.options, ['keep', 'bot', 'invite', 'cancel']);

      expect(
        event('mm.cancelled', {'reason': 'cooldown'}),
        isA<MmCancelledEvent>().having((e) => e.reason, 'reason', 'cooldown'),
      );
    });

    test('mm.found', () {
      final found = event('mm.found', {
        'match_id': 'M1',
        'ch': 'm:M1',
        'mode': 'rated',
        'opponent': card('u2'),
        'sources': [
          {'chapter': 'kinematics', 'count': 4},
          {'chapter': 'laws-of-motion', 'count': 3},
        ],
        'bot': false,
      }, 'u') as MmFoundEvent;

      expect(found.matchId, 'M1');
      expect(found.matchChannel, 'm:M1');
      expect(found.channel, 'u');
      final opponent = found.opponent;
      expect(opponent.uid, 'u2');
      expect(opponent.handle, 'player_u2');
      expect(opponent.displayName, 'Player u2');
      expect(opponent.avatar!.tone, 'sky');
      expect(opponent.avatar!.symbol, 'atom');
      expect(opponent.level, 4);
      expect(opponent.isBot, isFalse);
      expect(opponent.raw['avatar'], {'tone': 'sky', 'symbol': 'atom'});
      expect(
        [for (final s in found.sources) (s.chapter, s.count)],
        [('kinematics', 4), ('laws-of-motion', 3)],
      );
      expect(found.bot, isFalse);
    });

    test('mm.found derives the channel when it is missing', () {
      final found = event('mm.found', {'match_id': 'M1', 'opponent': card('u2')}) as MmFoundEvent;

      expect(found.matchChannel, 'm:M1');
      expect(found.sources, isEmpty);
    });

    test('mm.found with the opponent rating, head-to-head record and chapter names', () {
      final found = event('mm.found', {
        'match_id': 'M1',
        'opponent': {
          ...card('u2'),
          'rating': {'display': '1523?', 'value': 1523, 'provisional': true},
          'record': {'wins': 3, 'losses': 1, 'draws': 0},
        },
        'sources': [
          {'chapter': 'kinematics', 'name': 'Motion in a Straight Line', 'count': 4},
        ],
      }) as MmFoundEvent;

      expect(found.opponent.rating!.display, '1523?');
      expect(found.opponent.rating!.value, 1523);
      expect(found.opponent.rating!.provisional, isTrue);
      expect(found.opponent.record!.wins, 3);
      expect(found.opponent.record!.losses, 1);
      expect(found.opponent.record!.draws, 0);
      expect(found.sources.single.name, 'Motion in a Straight Line');
    });

    test('cards accept id instead of uid, and need little else', () {
      final found = event('mm.found', {
        'match_id': 'M1',
        'opponent': {'id': 'u2', 'handle': 'rahul_07', 'display_name': 'Rahul'},
      }) as MmFoundEvent;

      expect(found.opponent.uid, 'u2');
      expect(found.opponent.handle, 'rahul_07');
      expect(found.opponent.displayName, 'Rahul');
      expect(found.opponent.avatar, isNull);
      expect(found.opponent.level, isNull);
      expect(found.opponent.rating, isNull);

      final bot = event('mm.found', {
        'match_id': 'B1',
        'opponent': {'uid': 'bot:B1', 'display_name': 'Practice Bot', 'is_bot': true},
        'bot': true,
      }) as MmFoundEvent;
      expect(bot.opponent.isBot, isTrue);
    });

    test('mm.requeued, mm.cancelled refunds and mm.status crowd numbers', () {
      expect(
        event('mm.requeued', {'reason': 'opponent_not_ready', 'waited_s': 31}, 'u'),
        isA<MmRequeuedEvent>()
            .having((e) => e.reason, 'reason', 'opponent_not_ready')
            .having((e) => e.waitedS, 'waitedS', 31),
      );
      expect(
        event('mm.cancelled', {'reason': 'background', 'refunded': 5}),
        isA<MmCancelledEvent>().having((e) => e.refunded, 'refunded', 5),
      );
      expect((event('mm.cancelled', {'reason': 'user'}) as MmCancelledEvent).refunded, 0);

      final status =
          event('mm.status', {'waited_s': 5, 'online': 12, 'p50_wait_s': 9}) as MmStatusEvent;
      expect(status.online, 12);
      expect(status.p50WaitS, 9);
    });
  });

  group('matches (section 6)', () {
    test('match.snapshot with the current question, last reveal and my answers', () {
      final snapshot = decodeFrame(
        script.snapshot(
          phase: 'q_open',
          q: 2,
          scores: {'u1': 132},
          correct: {'u1': 1},
          connected: {'u2': false},
          graceUntil: {'u2': 1790000031000},
          answered: {'u1'},
          withQuestion: true,
          reveal: script.revealData(
            1,
            picks: {
              'u1': (script.correctOption(1), 132, 6010, 'fast'),
              'u2': (null, 0, null, 'slow'),
            },
            totals: {'u1': (132, 1), 'u2': (0, 0)},
          ),
          mine: [
            {'q': 1, 'opt': script.correctOption(1), 'status': 'accepted'},
            {'q': 2, 'opt': script.option(2, 0), 'status': 'late'},
          ],
        ),
      ) as MatchSnapshotEvent;

      expect(snapshot.matchId, 'M1');
      expect(snapshot.kind, 'quick_rated');
      expect(snapshot.phase, MatchPhase.qOpen);
      expect(snapshot.q, 2);
      expect(snapshot.total, 7);
      expect(snapshot.limitMs, 15000);
      expect(
        [
          for (final p in snapshot.players)
            (p.uid, p.presence, p.score, p.correct, p.answered, p.graceUntil),
        ],
        [
          ('u1', Presence.connected, 132, 1, true, null),
          ('u2', Presence.reconnecting, 0, 0, false, 1790000031000),
        ],
      );
      expect(snapshot.question!.q, 2);
      expect(snapshot.question!.options, hasLength(4));
      expect(snapshot.reveal!.correctOption, script.correctOption(1));
      expect(snapshot.reveal!.players['u2']!.opt, isNull);
      expect(snapshot.reveal!.players['u1']!.speed, Speed.fast);
      expect(
        [for (final m in snapshot.mine) (m.q, m.status)],
        [(1, AnswerStatus.accepted), (2, AnswerStatus.late)],
      );
      expect(snapshot.end, isNull);
      expect(snapshot.settled, isFalse);
    });

    test('match.snapshot of a finished match carries the end and whether it is settled', () {
      final snapshot = decodeFrame(
        script.snapshot(
          phase: 'finished',
          q: 7,
          end: script.endData(
            result: 'win',
            reason: 'opponent_forfeit',
            totals: {'u1': (500, 4), 'u2': (300, 2)},
          ),
          settled: true,
        ),
      ) as MatchSnapshotEvent;

      expect(snapshot.end!.result, MatchResult.win);
      expect(snapshot.end!.reason, MatchEndReason.opponentForfeit);
      expect(snapshot.end!.totals['u2'], const PlayerTotals(points: 300, correct: 2));
      expect(snapshot.end!.ranking, [
        ['u1'],
        ['u2'],
      ]);
      expect(snapshot.settled, isTrue);
    });

    test('match.snapshot accepts a presence string for connected', () {
      final snapshot = event('match.snapshot', {
        'match_id': 'M1',
        'phase': 'ready_wait',
        'q': 0,
        'total': 7,
        'players': [
          {'uid': 'u1', 'connected': 'left', 'score': 0},
        ],
      }) as MatchSnapshotEvent;

      expect(snapshot.players.single.presence, Presence.left);
      expect(snapshot.question, isNull);
      expect(snapshot.mine, isEmpty);
    });

    test('match.phase, q.show and q.progress', () {
      expect(
        event('match.phase', {'phase': 'countdown', 'q': 0, 'ends_at': 1790000003000}),
        isA<MatchPhaseEvent>()
            .having((e) => e.phase, 'phase', MatchPhase.countdown)
            .having((e) => e.endsAt, 'endsAt', 1790000003000),
      );

      final show = decodeFrame(script.show(1)) as QShowEvent;
      expect(show.question.q, 1);
      expect(show.question.total, 7);
      expect(show.question.stem, 'Question 1?');
      expect(show.question.options.first.id, script.option(1, 0));
      expect(show.question.shownAt, script.shownAt(1));
      expect(show.question.deadlineAt, script.deadlineAt(1));
      expect(show.question.limitMs, 15000);
      expect(show.question.chapter, 'Kinematics');

      final progress = decodeFrame(script.progress(1, ['u1', 'u2'])) as QProgressEvent;
      expect(progress.answered, ['u1', 'u2']);
    });

    test('q.show derives limit_ms from the deadline when it is missing', () {
      final data = script.showData(3)..remove('limit_ms');

      expect((event('q.show', data) as QShowEvent).question.limitMs, 15000);
    });

    test('ans.ack statuses, including ones this client does not know', () {
      AnswerStatus statusOf(String wire) =>
          (event('ans.ack', {'ref': 'c9', 'q': 1, 'status': wire}) as AnsAckEvent).status;

      expect(statusOf('accepted'), AnswerStatus.accepted);
      expect(statusOf('late'), AnswerStatus.late);
      expect(statusOf('too_early'), AnswerStatus.tooEarly);
      expect(statusOf('invalid'), AnswerStatus.invalid);
      expect(statusOf('wrong_phase'), AnswerStatus.wrongPhase);
      expect(statusOf('shiny_new_status'), AnswerStatus.unknown);
      expect(
        [
          for (final s in AnswerStatus.values)
            if (s.isVerdict) s,
        ],
        [
          AnswerStatus.accepted,
          AnswerStatus.late,
          AnswerStatus.tooEarly,
          AnswerStatus.invalid,
          AnswerStatus.wrongPhase,
        ],
      );
    });

    test('ans.ack repeats the first verdict with dup, and reads the legacy status "dup"', () {
      final first = decodeFrame(script.ansAck('c9', 1, 'late')) as AnsAckEvent;
      final repeat = decodeFrame(script.ansAck('c9', 1, 'late', dup: true)) as AnsAckEvent;
      final legacy = event('ans.ack', {'ref': 'c9', 'q': 1, 'status': 'dup'}) as AnsAckEvent;

      expect((first.status, first.dup), (AnswerStatus.late, false));
      expect((repeat.status, repeat.dup), (AnswerStatus.late, true));
      expect((legacy.status, legacy.dup), (AnswerStatus.dup, true));
      expect(first.seq, isNull, reason: 'per-player replies carry no seq');
    });

    test('q.reveal', () {
      final reveal = decodeFrame(
        script.reveal(
          4,
          picks: {
            'u1': (script.correctOption(4), 141, 3200, 'even'),
            'u2': (script.option(4, 1), 0, 3100, null),
          },
          totals: {'u1': (400, 3), 'u2': (250, 2)},
        ),
      ) as QRevealEvent;

      expect(reveal.reveal.q, 4);
      expect(reveal.reveal.correctOption, script.correctOption(4));
      expect(reveal.reveal.players['u1']!.correct, isTrue);
      expect(reveal.reveal.players['u1']!.pts, 141);
      expect(reveal.reveal.players['u1']!.timeMs, 3200);
      expect(reveal.reveal.players['u1']!.speed, Speed.even);
      expect(reveal.reveal.players['u2']!.correct, isFalse);
      expect(reveal.reveal.players['u2']!.speed, isNull);
      expect(reveal.reveal.totals['u2'], const PlayerTotals(points: 250, correct: 2));
      expect(reveal.reveal.ref, 'ref-4');
    });

    test('opp.conn and emote', () {
      expect(
        decodeFrame(script.oppConn('u2', 'reconnecting', graceUntil: 1790000031000)),
        isA<OppConnEvent>()
            .having((e) => e.uid, 'uid', 'u2')
            .having((e) => e.presence, 'presence', Presence.reconnecting)
            .having((e) => e.graceUntil, 'graceUntil', 1790000031000),
      );
      expect(
        decodeFrame(script.emote('u2', 'gg')),
        isA<EmoteEvent>().having((e) => e.emote, 'emote', 'gg'),
      );
    });

    test('match.end, with ties grouped in the ranking', () {
      final end = event('match.end', {
        'result': 'draw',
        'reason': 'opponent_forfeit',
        'totals': {
          'u1': {'points': 500, 'correct': 4},
        },
        'ranking': [
          ['u1', 'u2'],
          'u3',
        ],
      }) as MatchEndEvent;

      expect(end.result, MatchResult.draw);
      expect(end.reason, MatchEndReason.opponentForfeit);
      expect(end.totals['u1'], const PlayerTotals(points: 500, correct: 4));
      expect(end.ranking, [
        ['u1', 'u2'],
        ['u3'],
      ]);
    });

    test('match.settled, rated and unrated', () {
      final rated = decodeFrame(script.settled()) as MatchSettledEvent;
      expect(rated.matchId, 'M1');
      expect(rated.channel, 'm:M1');
      expect(rated.seq, isNull, reason: 'sent to one player, never logged');
      expect(rated.settlement.rating!.scope, 'physics');
      expect(rated.settlement.rating!.before, '1502?');
      expect(rated.settlement.rating!.after, '1518?');
      expect(rated.settlement.rating!.delta, 16);
      expect(rated.settlement.coins!.balance, 245);
      expect(rated.settlement.xp!.forNext, 250);
      expect(rated.settlement.resetsAt, script.t0 + 86400000);
      expect(rated.settlement.missions.single.id, 'win-3');

      final unrated = event('match.settled', {
        'rating': null,
        'coins': {'delta': 0, 'balance': 245},
        'xp': {'delta': 10, 'level': 4, 'into_level': 130, 'for_next': 250},
        'missions': <Object?>[],
      }) as MatchSettledEvent;
      expect(unrated.matchId, isNull);
      expect(unrated.settlement.rating, isNull);
      expect(unrated.settlement.coins!.delta, 0);
      expect(unrated.settlement.rank, isNull);
      expect(unrated.settlement.streak, isNull);
      expect(unrated.settlement.achievements, isEmpty);
      expect(unrated.settlement.tip, isNull);
    });

    test('match.settled with rank, level-up, caps, streak, achievements and a tip', () {
      final settled = event('match.settled', {
        'rating': {'scope': 'physics', 'before': '1502', 'after': '1518', 'delta': 16},
        'rank': {'board': 'rating:physics', 'before': 47, 'after': 42},
        'coins': {'delta': 10, 'balance': 245, 'capped': true},
        'xp': {
          'delta': 30,
          'level': 5,
          'into_level': 10,
          'for_next': 300,
          'level_up': true,
          'capped': false,
        },
        'resets_at': 1790050000000,
        'missions': [
          {'id': 'win-3', 'title': 'Win 3 battles', 'progress': 3, 'target': 3, 'done': true},
        ],
        'streak': {'days': 5, 'extended': true},
        'achievements': [
          {'id': 'first-win', 'title': 'First victory'},
        ],
        'tip': {
          'message': 'You were slower on 4 of 7. Try a timed set in Kinematics.',
          'action': 'practice',
          'params': {'chapter': 'kinematics', 'timed': true},
        },
      }) as MatchSettledEvent;
      final s = settled.settlement;

      expect(s.rank, isA<RankMoved>().having((r) => r.change, 'change', 5));
      expect((s.rank! as RankMoved).board, 'rating:physics');
      expect(s.coins!.capped, isTrue);
      expect(s.resetsAt, 1790050000000);
      expect(s.xp!.levelUp, isTrue);
      expect(s.xp!.capped, isFalse);
      expect(s.missions.single.title, 'Win 3 battles');
      expect(s.streak!.days, 5);
      expect(s.streak!.extended, isTrue);
      expect(s.achievements.single.title, 'First victory');
      expect(s.tip!.action, 'practice');
      expect(s.tip!.params, {'chapter': 'kinematics', 'timed': true});
    });

    test('match.settled rank before the player is ranked', () {
      final settled = event('match.settled', {
        'rank': {'board': 'rating:physics', 'games_to_rank': 6},
        'xp': {
          'delta': 30,
          'level': 4,
          'into_level': 120,
          'for_next': 250,
          'resets_at': '2026-09-28T00:00:00Z',
        },
      }) as MatchSettledEvent;

      expect(
        settled.settlement.rank,
        isA<RankPending>().having((r) => r.gamesToRank, 'gamesToRank', 6),
      );
      expect(settled.settlement.xp!.levelUp, isFalse);
      expect(
        settled.settlement.resetsAt,
        DateTime.utc(2026, 9, 28).millisecondsSinceEpoch,
        reason: 'the earlier spot inside xp, and ISO 8601, are still read',
      );
    });

    test('q.reveal with group standings', () {
      final reveal = event(
        'q.reveal',
        {
          'q': 2,
          'correct': 'a',
          'players': <String, Object?>{},
          'standings': [
            {'uid': 'u3', 'points': 280, 'place': 1, 'change': 2},
            {'uid': 'u1', 'points': 250, 'place': 2},
          ],
        },
        'm:G1',
        9,
      ) as QRevealEvent;

      expect(
        [for (final s in reveal.reveal.standings) (s.uid, s.points, s.place, s.change)],
        [('u3', 280, 1, 2), ('u1', 250, 2, 0)],
      );
      expect(
        (decodeFrame(script.reveal(1, picks: {}, totals: {})) as QRevealEvent).reveal.standings,
        isEmpty,
      );
    });

    test('match.end reasons added for rooms and tournaments', () {
      MatchEndReason reasonOf(String wire) =>
          (event('match.end', {'result': 'loss', 'reason': wire}) as MatchEndEvent).reason;

      expect(reasonOf('left'), MatchEndReason.left);
      expect(reasonOf('disconnected'), MatchEndReason.disconnected);
      expect(reasonOf('no_show'), MatchEndReason.noShow);
      expect(reasonOf('ended_by_host'), MatchEndReason.endedByHost);
    });

    test('rematch.status', () {
      final offered = event(
        'rematch.status',
        {'match_id': 'M1', 'state': 'offered', 'by': 'u2'},
        'm:M1',
        30,
      ) as RematchStatusEvent;
      expect(offered.matchId, 'M1');
      expect(offered.state, RematchState.offered);
      expect(offered.by, 'u2');

      final failed = event('rematch.status', {
        'match_id': 'M1',
        'state': 'failed',
        'by': 'u1',
        'reason': 'insufficient_coins',
      }) as RematchStatusEvent;
      expect(failed.state, RematchState.failed);
      expect(failed.reason, 'insufficient_coins');
    });
  });

  group('rooms (section 8)', () {
    test('room.state, room.started, room.kicked, room.closed', () {
      final state = event(
        'room.state',
        {
          'room_id': 'R1',
          'kind': 'group',
          'code': 'K7M2QX',
          'host': 'u1',
          'status': 'lobby',
          'locked': false,
          'settings': {'subject': 'physics', 'count': 10},
          'members': [
            {...card('u1'), 'ready': true, 'connected': true, 'away': true, 'role': 'host'},
            {...card('u2'), 'ready': false, 'connected': false, 'role': 'member'},
          ],
        },
        'r:R1',
        4,
      ) as RoomStateEvent;
      expect(state.code, 'K7M2QX');
      expect(state.settings['count'], 10);
      expect(
        [for (final m in state.members) (m.uid, m.ready, m.connected, m.away, m.role)],
        [('u1', true, true, true, 'host'), ('u2', false, false, false, 'member')],
      );
      expect(state.rematch, isNull);

      final afterGame = event(
        'room.state',
        {
          'room_id': 'R1',
          'kind': 'friend',
          'host': 'u1',
          'status': 'finished',
          'members': <Object?>[],
          'rematch': {'offered_by': 'u2', 'until': 1790000030000},
        },
        'r:R1',
        9,
      ) as RoomStateEvent;
      expect(afterGame.rematch!.offeredBy, 'u2');
      expect(afterGame.rematch!.until, 1790000030000);

      expect(
        event('room.started', {'match_id': 'M5'}),
        isA<RoomStartedEvent>().having((e) => e.matchChannel, 'matchChannel', 'm:M5'),
      );
      expect(
        event('room.kicked', {'room_id': 'R1'}),
        isA<RoomKickedEvent>().having((e) => e.roomId, 'roomId', 'R1'),
      );
      expect(
        event('room.closed', {'room_id': 'R1', 'reason': 'host_ended'}),
        isA<RoomClosedEvent>().having((e) => e.reason, 'reason', 'host_ended'),
      );
    });
  });

  group('invites and inbox (sections 8 and 9a)', () {
    test('invite.received and invite.updated', () {
      final received = event('invite.received', {
        'invite_id': 'I1',
        'from': card('u2'),
        'kind': 'friend',
        'room_id': 'R1',
        'subject': 'physics',
        'expires_at': 1790000120000,
      }, 'u') as InviteReceivedEvent;
      expect(received.inviteId, 'I1');
      expect(received.from.uid, 'u2');
      expect(received.kind, 'friend');
      expect(received.roomId, 'R1');
      expect(received.subject, 'physics');
      expect(received.expiresAt, 1790000120000);

      InviteStatus statusOf(String wire) => (event('invite.updated', {
        'invite_id': 'I1',
        'status': wire,
      }) as InviteUpdatedEvent).status;
      expect(statusOf('accepted'), InviteStatus.accepted);
      expect(statusOf('declined'), InviteStatus.declined);
      expect(statusOf('expired'), InviteStatus.expired);
      expect(statusOf('cancelled'), InviteStatus.cancelled);
      expect(statusOf('snoozed'), InviteStatus.unknown);
    });

    test('notify', () {
      final notify = event('notify', {
        'id': 'N1',
        'kind': 'tournament_round',
        'title': 'Round 3 is ready',
        'body': 'Tap to join',
        'action': {
          'route': '/arena/T1',
          'params': {'round': 3},
        },
        'unread': 4,
      }, 'u') as NotifyEvent;

      expect(notify.id, 'N1');
      expect(notify.kind, 'tournament_round');
      expect(notify.title, 'Round 3 is ready');
      expect(notify.body, 'Tap to join');
      expect(notify.action!.route, '/arena/T1');
      expect(notify.action!.params, {'round': 3});
      expect(notify.unread, 4);

      final bare = event('notify', {'id': 'N2', 'kind': 'account', 'title': 'Hi'}) as NotifyEvent;
      expect(bare.action, isNull);
      expect(bare.unread, isNull);
    });
  });

  group('tournaments (section 9)', () {
    test('t.standings, t.round, t.pairing', () {
      final standings = event('t.standings', {
        'round': 3,
        'rows': [
          {'rank': 1, 'uid': 'u9', 'name': 'Ana', 'points': 2.5, 'bh_c1': 4},
        ],
        'me': {'rank': 14, 'uid': 'u1', 'points': 1},
      }, 't:T1') as TStandingsEvent;
      expect(standings.tournamentId, 'T1');
      expect(standings.rows.single.points, 2.5);
      expect(standings.rows.single.raw['bh_c1'], 4);
      expect(standings.me!.rank, 14);

      expect(
        event('t.round', {'round': 3, 'status': 'live', 'starts_at': 1, 'ends_at': 2}),
        isA<TRoundEvent>().having((e) => e.status, 'status', 'live'),
      );

      final pairing = event('t.pairing', {
        'tournament_id': 'T1',
        'round': 3,
        'match_id': 'M8',
        'ch': 'm:M8',
        'opponent': card('u3'),
        'ready_by': 1790000090000,
      }, 'u') as TPairingEvent;
      expect(pairing.bye, isFalse);
      expect(pairing.matchChannel, 'm:M8');
      expect(pairing.opponent!.uid, 'u3');

      final bye = event('t.pairing', {'tournament_id': 'T1', 'round': 4, 'bye': true});
      expect(bye, isA<TPairingEvent>().having((e) => e.matchChannel, 'matchChannel', isNull));
    });

    test('t.check_in, t.at_risk, t.checked_in, t.bye, t.finished, t.cancelled', () {
      final checkIn = event('t.check_in', {
        'tournament_id': 'T1',
        'title': 'Physics Sunday Cup',
        'starts_at': 1790000900000,
        'closes_at': 1790000600000,
      }, 'u') as TCheckInEvent;
      expect(checkIn.tournamentId, 'T1');
      expect(checkIn.title, 'Physics Sunday Cup');
      expect(checkIn.startsAt, 1790000900000);
      expect(checkIn.closesAt, 1790000600000);

      final atRisk = event('t.at_risk', {
        'tournament_id': 'T1',
        'players': 5,
        'needed': 3,
      }, 'u') as TAtRiskEvent;
      expect((atRisk.tournamentId, atRisk.players, atRisk.needed), ('T1', 5, 3));

      expect(
        event('t.checked_in', {'tournament_id': 'T1'}),
        isA<TCheckedInEvent>().having((e) => e.tournamentId, 'tournamentId', 'T1'),
      );

      final bye = event('t.bye', {'tournament_id': 'T1', 'round': 2, 'points': 1}) as TByeEvent;
      expect(bye.round, 2);
      expect(bye.points, 1);

      final finished = event('t.finished', {
        'tournament_id': 'T1',
        'rank': 3,
        'players': 64,
        'points': 4.5,
        'prize': 120,
        'xp': 50,
      }) as TFinishedEvent;
      expect(finished.rank, 3);
      expect(finished.players, 64);
      expect(finished.points, 4.5);
      expect(finished.prize, 120);
      expect(finished.xp, 50);

      final cancelled = event('t.cancelled', {
        'tournament_id': 'T1',
        'reason': 'not_enough_players',
        'refunded': 15,
      }) as TCancelledEvent;
      expect(cancelled.reason, 'not_enough_players');
      expect(cancelled.refunded, 15);
    });
  });

  group('required fields', () {
    final missing = <String, (String, Map<String, Object?>)>{
      'welcome without server_ms': ('welcome', {'user_id': 'u1', 'hb_s': 10}),
      'hb without s': ('hb', {}),
      'ans.ack with a non-boolean dup': (
        'ans.ack',
        {'ref': 'c1', 'q': 1, 'status': 'accepted', 'dup': 'yes'},
      ),
      'match.snapshot with an end without a result': (
        'match.snapshot',
        {
          'match_id': 'M1',
          'phase': 'finished',
          'q': 7,
          'total': 7,
          'players': <Object?>[],
          'end': {'reason': 'normal'},
        },
      ),
      'clock.pong without s': ('clock.pong', {'c0': 1}),
      'ack without ref': ('ack', {}),
      'error without code': ('error', {'ref': 'c1'}),
      'mm.found without opponent': ('mm.found', {'match_id': 'M1'}),
      'q.show without stem': ('q.show', script.showData(1)..remove('stem')),
      'q.show with an option without id': (
        'q.show',
        script.showData(1)
          ..['options'] = [
            {'text': 'A'},
          ],
      ),
      'q.progress with a numeric uid': (
        'q.progress',
        {
          'q': 1,
          'answered': [1],
        },
      ),
      'ans.ack without ref': ('ans.ack', {'q': 1, 'status': 'accepted'}),
      'q.reveal without correct': ('q.reveal', {'q': 1, 'players': <String, Object?>{}}),
      'q.reveal with a player without pts': (
        'q.reveal',
        {
          'q': 1,
          'correct': 'a',
          'players': {
            'u1': {'opt': 'a', 'correct': true},
          },
        },
      ),
      'match.snapshot with a player without uid': (
        'match.snapshot',
        {
          'match_id': 'M1',
          'phase': 'q_open',
          'q': 1,
          'total': 7,
          'players': [
            {'connected': true, 'score': 0},
          ],
        },
      ),
      'match.end with a malformed ranking': (
        'match.end',
        {
          'result': 'win',
          'reason': 'normal',
          'ranking': [7],
        },
      ),
      'room.state without members': (
        'room.state',
        {'room_id': 'R1', 'kind': 'friend', 'host': 'u1', 'status': 'lobby'},
      ),
      't.pairing without a match or a bye': ('t.pairing', {'round': 1}),
      'mm.requeued without waited_s': ('mm.requeued', {'reason': 'match_failed'}),
      'rematch.status without match_id': ('rematch.status', {'state': 'offered'}),
      'invite.received without from': ('invite.received', {'invite_id': 'I1'}),
      'notify without title': ('notify', {'id': 'N1', 'kind': 'account'}),
      't.finished without rank': ('t.finished', {'tournament_id': 'T1'}),
      'match.settled with a rank without after': (
        'match.settled',
        {
          'rank': {'board': 'rating:physics', 'before': 3},
        },
      ),
      'q.reveal with a standing without place': (
        'q.reveal',
        {
          'q': 1,
          'correct': 'a',
          'players': <String, Object?>{},
          'standings': [
            {'uid': 'u1', 'points': 10},
          ],
        },
      ),
    };
    for (final MapEntry(key: name, value: (type, data)) in missing.entries) {
      test('rejects $name', () {
        expect(() => event(type, data), throwsFormatException);
      });
    }
  });

  test('ShownQuestion helpers take the synced server time', () {
    final question = (decodeFrame(script.show(1)) as QShowEvent).question;
    final shownAt = script.shownAt(1);

    expect(question.revealedAt(shownAt - 400), isFalse);
    expect(question.revealedAt(shownAt - 1), isFalse);
    expect(question.revealedAt(shownAt), isTrue);
    expect(question.remainingMs(shownAt), 15000);
    expect(question.remainingMs(shownAt + 6240), 8760);
    expect(question.remainingMs(shownAt + 20000), 0);
    expect(question.elapsedMs(shownAt - 300), 0);
    expect(question.elapsedMs(shownAt + 6240), 6240);
  });

  test('enums keep unknown values instead of failing', () {
    expect(MatchPhase.parse('q_open'), MatchPhase.qOpen);
    expect(MatchPhase.parse('overtime'), MatchPhase.unknown);
    expect(Presence.parse('away'), Presence.unknown);
    expect(MatchResult.parse('loss'), MatchResult.loss);
    expect(MatchEndReason.parse('aborted'), MatchEndReason.aborted);
    expect(Speed.parse('warp'), isNull);
    expect(MatchPhase.finished.isOver, isTrue);
    expect(MatchPhase.qReveal.isOver, isFalse);
  });

  test('every server message type of the protocol has a decoder', () {
    expect(
      knownServerMessageTypes,
      unorderedEquals([
        'welcome', 'ping', 'hb', 'clock.pong', 'ack', 'error', //
        'mm.queued', 'mm.status', 'mm.timeout', 'mm.cancelled', 'mm.requeued', 'mm.found',
        'match.snapshot', 'match.phase', 'q.show', 'q.progress', 'ans.ack', 'q.reveal',
        'opp.conn', 'emote', 'match.end', 'match.settled', 'rematch.status',
        'room.state', 'room.started', 'room.kicked', 'room.closed',
        'invite.received', 'invite.updated',
        't.standings', 't.round', 't.check_in', 't.at_risk', 't.checked_in', 't.pairing',
        't.bye', 't.finished', 't.cancelled',
        'notify',
      ]),
    );
  });
}
