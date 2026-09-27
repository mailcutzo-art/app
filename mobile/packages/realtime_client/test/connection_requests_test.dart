import 'package:fake_async/fake_async.dart';
import 'package:realtime_client/realtime_client.dart';
import 'package:test/test.dart';

import 'support/frames.dart';
import 'support/harness.dart';

void main() {
  group('requests', () {
    test('correlate acks by ref, in any order', () {
      fakeAsync((async) {
        final h = Harness(async)..open();
        final ready = Outcome(h.connection.request('match.ready', {'match_id': 'M1'}));
        final emote = Outcome(h.connection.request('emote', {'match_id': 'M1', 'e': 'gg'}));
        h.flush();
        final readyId = h.lastIdOf('match.ready');
        final emoteId = h.lastIdOf('emote');
        expect(readyId, isNot(emoteId));
        expect(h.socket.sentOfType('match.ready').single['d'], {'match_id': 'M1'});

        h.push(frame('ack', {'ref': emoteId}));
        expect(emote.value.id, emoteId);
        expect(emote.value.reply, isA<AckEvent>());
        expect(ready.isPending, isTrue);

        h.push(frame('ack', {'ref': readyId}));
        expect(ready.value.id, readyId);
        h.dispose();
      });
    });

    test('fail with the server error, typed', () {
      fakeAsync((async) {
        final h = Harness(async)..open();
        final join = Outcome(h.connection.request('room.join', {'code': 'K7M2QX'}));
        h.flush();

        h.push(
          frame('error', {
            'ref': h.lastIdOf('room.join'),
            'code': 'BUSY',
            'message': "You're already in a match.",
            'retryable': false,
            'details': {
              'active': {'kind': 'match', 'id': 'M9', 'title': 'Quick Battle'},
            },
          }),
        );

        final error = join.realtimeError;
        expect(error.code, RealtimeErrorCode.busy);
        expect(error.message, "You're already in a match.");
        expect(error.retryable, isFalse);
        expect(error.ref, h.lastIdOf('room.join'));
        expect(error.active!.kind, ActiveKind.match);
        expect(error.active!.id, 'M9');
        expect(error.isClientSide, isFalse);
        h.dispose();
      });
    });

    test('time out, and ignore a late reply', () {
      fakeAsync((async) {
        final h = Harness(async)..open();
        final ready = Outcome(
          h.connection.request('match.ready', {
            'match_id': 'M1',
          }, timeout: const Duration(seconds: 3)),
        );
        h.flush();
        final id = h.lastIdOf('match.ready');

        h.elapseMs(2999);
        expect(ready.isPending, isTrue);
        h.elapseMs(1);
        expect(ready.realtimeError.code, RealtimeErrorCode.timeout);
        expect(ready.realtimeError.ref, id);
        expect(ready.realtimeError.retryable, isTrue);

        h.push(frame('ack', {'ref': id}));
        expect(h.state, isA<Open>());
        h.dispose();
      });
    });

    test('mm.join completes with its natural reply, mm.queued', () {
      fakeAsync((async) {
        final h = Harness(async)..open();
        final join = Outcome(
          h.connection.request('mm.join', {
            'mode': 'rated',
            'subject': 'physics',
            'chapter': 'kinematics',
            'idem': 'b5a1',
          }),
        );
        h.flush();

        h.push(
          frame('mm.queued', {
            'ticket_id': 'T1',
            'mode': 'rated',
            'subject': 'physics',
            'chapter': 'kinematics',
            'joined_at': h.serverNowMs,
          }, 'u'),
        );

        expect(join.value.reply, isA<MmQueuedEvent>().having((e) => e.ticketId, 'ticketId', 'T1'));
        expect(join.value.id, h.lastIdOf('mm.join'));
        expect(h.events.single, isA<MmQueuedEvent>(), reason: 'replies are events too');
        h.dispose();
      });
    });

    test('a bot game answers mm.join with mm.found straight away', () {
      fakeAsync((async) {
        final h = Harness(async)..open();
        final join = Outcome(
          h.connection.request('mm.join', {'mode': 'bot', 'subject': 'physics', 'idem': 'c7d2'}),
        );
        h.flush();

        h.push(frame('mm.found', {'match_id': 'B1', 'opponent': card('bot:B1'), 'bot': true}, 'u'));

        expect(join.value.reply, isA<MmFoundEvent>().having((e) => e.bot, 'bot', isTrue));
        h.dispose();
      });
    });

    test('mm.join fails with the matching error', () {
      fakeAsync((async) {
        final h = Harness(async)..open();
        final join = Outcome(h.connection.request('mm.join', {'mode': 'casual'}));
        h.flush();

        h.push(
          frame('error', {
            'ref': h.lastIdOf('mm.join'),
            'code': 'INSUFFICIENT_COINS',
            'message': 'You need 5 coins.',
          }),
        );

        expect(join.realtimeError.code, RealtimeErrorCode.insufficientCoins);
        h.dispose();
      });
    });

    test('sub completes with the channel standings, match.rematch with its status', () {
      fakeAsync((async) {
        final h = Harness(async)..open();
        final sub = Outcome(h.connection.request('sub', {'ch': 't:T1'}));
        final rematch = Outcome(
          h.connection.request('match.rematch', {'match_id': 'M1', 'accept': true}),
        );
        h.flush();

        h.push(frame('t.standings', {'round': 1, 'rows': <Object?>[]}, 't:T2'));
        expect(sub.isPending, isTrue, reason: 'another tournament');
        h.push(frame('t.standings', {'round': 1, 'rows': <Object?>[]}, 't:T1'));
        expect(sub.value.reply, isA<TStandingsEvent>());

        h.push(
          frame('rematch.status', {'match_id': 'M1', 'state': 'offered', 'by': 'u1'}, 'm:M1', 40),
        );
        expect(rematch.value.reply, isA<RematchStatusEvent>());
        h.dispose();
      });
    });

    test('a custom reply matcher', () {
      fakeAsync((async) {
        final h = Harness(async)..open();
        final leave = Outcome(
          h.connection.request('room.leave', {
            'room_id': 'R1',
          }, isReply: (event, id) => event is RoomClosedEvent && event.roomId == 'R1'),
        );
        h.flush();

        h.push(frame('room.closed', {'room_id': 'R1', 'reason': 'empty'}, 'r:R1', 5));

        expect(leave.value.reply, isA<RoomClosedEvent>());
        h.dispose();
      });
    });

    test('a reply matcher that throws is logged and treated as no match', () {
      fakeAsync((async) {
        final h = Harness(async)..open();
        final leave = Outcome(
          h.connection.request('room.leave', {
            'room_id': 'R1',
          }, isReply: (event, id) => throw StateError('buggy matcher')),
        );
        h.flush();

        h.push(frame('mm.status', {'waited_s': 1}, 'u'));
        expect(h.logs, contains(startsWith('The reply matcher of room.leave threw')));
        expect(h.events.single, isA<MmStatusEvent>(), reason: 'the event is still delivered');

        h.push(frame('ack', {'ref': h.lastIdOf('room.leave')}));
        expect(leave.value.reply, isA<AckEvent>());
        h.dispose();
      });
    });

    test('wait for the connection, then go out right after welcome', () {
      fakeAsync((async) {
        final h = Harness(async);
        h.connection.acquire('battle-tab');
        final cancel = Outcome(h.connection.request('mm.cancel', {}));
        expect(h.state, isA<Ticketing>());
        h.flush();

        final types = h.socket.sent.map((m) => m['t']).toList();
        expect(types.take(2), ['hello', 'mm.cancel']);
        h.push(frame('ack', {'ref': h.lastIdOf('mm.cancel')}));
        expect(cancel.value.reply, isA<AckEvent>());
        h.dispose();
      });
    });

    test('fail as DISCONNECTED when the socket drops after sending', () {
      fakeAsync((async) {
        final h = Harness(async)..open();
        final ready = Outcome(h.connection.request('match.ready', {'match_id': 'M1'}));
        h.flush();

        h.socket.closeFromServer(1013);
        h.flush();

        expect(ready.realtimeError.code, RealtimeErrorCode.disconnected);
        expect(ready.realtimeError.retryable, isTrue);
        expect(ready.realtimeError.isClientSide, isTrue);
        h.dispose();
      });
    });

    test('ids are unique per connection and start at c1 on each', () {
      fakeAsync((async) {
        final h = Harness(async)..open();
        for (var i = 0; i < 3; i++) {
          Outcome(h.connection.request('emote', {'match_id': 'M1', 'e': 'gg'}));
        }
        h.flush();
        final first = h.socket;
        first.closeFromServer(1013);
        h.flush();
        h.elapse(h.retryIn);

        for (final socket in h.connector.sockets) {
          expect(socket.sentIds.first, 'c1');
          expect(socket.sentIds.toSet(), hasLength(socket.sentIds.length));
        }
        h.dispose();
      });
    });
  });

  group('answers', () {
    test('are sent and complete on ans.ack', () {
      fakeAsync((async) {
        final h = Harness(async)..open();
        final answer = Outcome(h.connection.submitAnswer('M1', 3, 'k2P9x', 6240));
        h.flush();

        final sent = h.socket.sentOfType('ans.submit').single;
        expect(sent['d'], {'match_id': 'M1', 'q': 3, 'opt': 'k2P9x', 'el_ms': 6240});
        expect(h.connection.pendingAnswers, 1);

        h.push(frame('ans.ack', {'ref': sent['id'], 'q': 3, 'status': 'accepted'}, 'm:M1'));
        expect(answer.value.status, AnswerStatus.accepted);
        expect(h.connection.pendingAnswers, 0);
        expect(h.events.single, isA<AnsAckEvent>(), reason: 'the reducer needs it');

        h.elapse(const Duration(seconds: 10));
        expect(h.socket.sentOfType('ans.submit'), hasLength(1));
        h.dispose();
      });
    });

    test('are resent with the same id every 2 s until acknowledged', () {
      fakeAsync((async) {
        final h = Harness(async)..open();
        Outcome(h.connection.submitAnswer('M1', 1, 'a', 900));
        h.flush();
        final id = h.lastIdOf('ans.submit');

        h.elapseMs(1999);
        expect(h.socket.sentOfType('ans.submit'), hasLength(1));
        h.elapseMs(1);
        expect(h.socket.sentOfType('ans.submit'), hasLength(2));
        h.elapse(const Duration(seconds: 2));
        final sends = h.socket.sentOfType('ans.submit');
        expect(sends, hasLength(3));
        expect(sends.map((m) => m['id']).toSet(), {id});
        expect(
          sends.map((m) => m['d']),
          everyElement({'match_id': 'M1', 'q': 1, 'opt': 'a', 'el_ms': 900}),
        );

        h.push(frame('ans.ack', {'ref': id, 'q': 1, 'status': 'accepted', 'dup': true}, 'm:M1'));
        h.elapse(const Duration(seconds: 6));
        expect(h.socket.sentOfType('ans.submit'), hasLength(3));
        h.dispose();
      });
    });

    test('an older server\'s status "dup" still counts as acknowledged', () {
      fakeAsync((async) {
        final h = Harness(async)..open();
        final answer = Outcome(h.connection.submitAnswer('M1', 1, 'a', 900));
        h.flush();

        h.push(
          frame('ans.ack', {'ref': h.lastIdOf('ans.submit'), 'q': 1, 'status': 'dup'}, 'm:M1'),
        );

        expect(answer.value.status, AnswerStatus.dup);
        expect(answer.value.dup, isTrue);
        expect(h.connection.pendingAnswers, 0);
        h.dispose();
      });
    });

    test('are resent after a reconnect with the same id, which the new connection skips', () {
      fakeAsync((async) {
        final h = Harness(async)..open();
        final answer = Outcome(h.connection.submitAnswer('M1', 2, 'b', 4100));
        h.flush();
        final id = h.lastIdOf('ans.submit');
        expect(id, 'c7', reason: 'after hello (c1) and five clock pings');

        h.socket.closeFromServer(1013);
        h.flush();
        h.elapse(h.retryIn);
        final second = h.socket;
        expect(second.sentOfType('ans.submit').single['id'], id);
        expect(second.sentOfType('ans.submit').single['d'], {
          'match_id': 'M1',
          'q': 2,
          'opt': 'b',
          'el_ms': 4100,
        });

        Outcome(h.connection.request('emote', {'match_id': 'M1', 'e': 'wow'}));
        h.flush();
        expect(second.sentIds, ['c1', 'c7', 'c2', 'c3', 'c4', 'c5', 'c6', 'c8']);

        h.push(frame('ans.ack', {'ref': id, 'q': 2, 'status': 'late', 'dup': true}, 'm:M1'));
        expect(answer.value.status, AnswerStatus.late, reason: 'the first verdict, repeated');
        expect(answer.value.dup, isTrue);
        h.dispose();
      });
    });

    test('submitted while disconnected, they go out after the next welcome', () {
      fakeAsync((async) {
        final h = Harness(async)..open(inMatch: true);
        h.socket.closeFromServer(1013);
        h.flush();
        expect(h.state, isA<Backoff>());

        final answer = Outcome(h.connection.submitAnswer('M1', 4, 'c', 3000));
        h.elapse(h.retryIn);

        final sent = h.socket.sentOfType('ans.submit').single;
        expect(h.socket.sent[1], same(sent), reason: 'answers go first after welcome');
        h.push(frame('ans.ack', {'ref': sent['id'], 'q': 4, 'status': 'late'}, 'm:M1'));
        expect(answer.value.status, AnswerStatus.late);
        h.dispose();
      });
    });

    test('an ack for another question with the same ref does not count', () {
      fakeAsync((async) {
        final h = Harness(async)..open();
        final answer = Outcome(h.connection.submitAnswer('M1', 5, 'd', 100));
        h.flush();
        final id = h.lastIdOf('ans.submit');

        h.push(frame('ans.ack', {'ref': id, 'q': 4, 'status': 'accepted'}, 'm:M1'));

        expect(answer.isPending, isTrue);
        expect(h.connection.pendingAnswers, 1);
        h.dispose();
      });
    });

    test('a second submit for the same question reuses the first', () {
      fakeAsync((async) {
        final h = Harness(async)..open();
        final first = h.connection.submitAnswer('M1', 1, 'a', 100);
        final second = h.connection.submitAnswer('M1', 1, 'b', 200);
        h.flush();

        expect(second, same(first));
        expect(h.socket.sentOfType('ans.submit'), hasLength(1));
        h.dispose();
      });
    });

    test('a retryable error keeps the answer; a final one drops it', () {
      fakeAsync((async) {
        final h = Harness(async)..open();
        final limited = Outcome(h.connection.submitAnswer('M1', 1, 'a', 100));
        final invalid = Outcome(h.connection.submitAnswer('M1', 2, 'z', 100));
        h.flush();
        final [limitedId, invalidId] = [
          for (final m in h.socket.sentOfType('ans.submit')) m['id']! as String,
        ];

        h.push(frame('error', {'ref': limitedId, 'code': 'RATE_LIMITED', 'retryable': true}));
        h.push(frame('error', {'ref': invalidId, 'code': 'BAD_REQUEST', 'retryable': false}));

        expect(limited.isPending, isTrue);
        expect(invalid.realtimeError.code, RealtimeErrorCode.badRequest);
        expect(h.connection.pendingAnswers, 1);
        h.elapse(const Duration(seconds: 2));
        expect(h.socket.sentOfType('ans.submit').where((m) => m['id'] == limitedId), hasLength(2));
        h.dispose();
      });
    });

    test('forgetting the match drops its answers', () {
      fakeAsync((async) {
        final h = Harness(async)..open();
        final answer = Outcome(h.connection.submitAnswer('M1', 7, 'a', 100));
        final other = Outcome(h.connection.submitAnswer('M2', 1, 'a', 100));
        h.flush();

        h.connection.forgetChannel('m:M1');
        h.flush();

        expect(answer.realtimeError.code, RealtimeErrorCode.cancelled);
        expect(other.isPending, isTrue);
        expect(h.connection.pendingAnswers, 1);
        h.dispose();
      });
    });

    test('an ignored answer future never raises an unhandled error', () {
      fakeAsync((async) {
        final h = Harness(async)..open();
        // Nobody listens to this future.
        h.connection.submitAnswer('M1', 1, 'a', 100);
        h.socket.closeFromServer(4403);
        h.flush();

        expect(h.state, isA<Terminal>());
        h.dispose();
      });
    });
  });
}
