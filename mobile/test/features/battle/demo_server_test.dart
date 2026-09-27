import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_app/features/battle/demo/demo_server.dart';
import 'package:quiz_app/features/battle/demo/demo_world.dart';
import 'package:realtime_client/realtime_client.dart';

const _me = DemoPlayer(uid: 'u1', name: 'Aarav');

/// The app's side of a demo connection, by hand.
class _Client {
  _Client(this.server, this.async);

  final DemoRealtimeServer server;
  final FakeAsync async;
  RealtimeSocket? socket;
  final frames = <Map<String, Object?>>[];
  var _ids = 0;
  bool closed = false;

  void open({bool takeover = false, List<Map<String, Object?>> resume = const []}) {
    server.connect().then((opened) {
      socket = opened;
      opened.frames.listen(
        (frame) => frames.add(jsonDecode(frame! as String) as Map<String, Object?>),
        onDone: () => closed = true,
      );
    });
    async.flushMicrotasks();
    send('hello', {'ticket': 't', 'proto': 1, 'resume': resume, 'takeover': takeover});
    settle();
  }

  String send(String type, [Map<String, Object?> data = const {}]) {
    final id = 'c${++_ids}';
    socket!.send(jsonEncode({'v': 1, 't': type, 'id': id, 'd': data}));
    return id;
  }

  void settle() => async.elapse(const Duration(milliseconds: 50));

  List<Map<String, Object?>> ofType(String type) => [
    for (final frame in frames)
      if (frame['t'] == type) frame,
  ];

  Map<String, Object?> d(Map<String, Object?> frame) => frame['d']! as Map<String, Object?>;

  Map<String, Object?> last(String type) => d(ofType(type).last);
}

DemoRealtimeServer _server() => DemoRealtimeServer(me: _me, seed: 5)..latency = Duration.zero;

/// Joins a rated search that finds Riya after 1 s, then gets both players ready.
String _startMatch(_Client client, {String mode = 'rated'}) {
  client.server
    ..world.firstSearch = false
    ..findAfter = const Duration(seconds: 1);
  client.send('mm.join', {
    'mode': mode,
    'subject': 'physics',
    'chapter': 'kinematics',
    'idem': 'i1',
  });
  client.async.elapse(const Duration(seconds: 1, milliseconds: 200));
  final matchId = client.last('mm.found')['match_id']! as String;
  client.send('match.ready', {'match_id': matchId});
  client.async.elapse(const Duration(seconds: 1));
  return matchId;
}

void main() {
  test('says welcome, answers clock pings, and pings every 10 s', () {
    fakeAsync((async) {
      final server = _server();
      final client = _Client(server, async)..open();
      final welcome = client.last('welcome');
      expect(welcome['user_id'], 'u1');
      expect(welcome['hb_s'], 10);
      expect(welcome['active'], isEmpty);
      client.send('clock.ping', {'c0': 42});
      client.settle();
      expect(client.last('clock.pong')['c0'], 42);
      async.elapse(const Duration(seconds: 21));
      expect(client.ofType('ping'), hasLength(2));
      server.dispose();
    });
  });

  test('a rated search finds Riya after about 6 s', () {
    fakeAsync((async) {
      final server = _server()..world.firstSearch = false;
      final client = _Client(server, async)..open();
      client.send('mm.join', {'mode': 'rated', 'subject': 'physics', 'chapter': null, 'idem': 'a'});
      client.settle();
      expect(client.last('mm.queued')['mode'], 'rated');
      expect(client.last('mm.status')['online'], 3);
      async.elapse(const Duration(seconds: 5));
      expect(client.ofType('mm.found'), isEmpty);
      async.elapse(const Duration(seconds: 1));
      final found = client.last('mm.found');
      final opponent = found['opponent']! as Map<String, Object?>;
      expect(opponent['display_name'], 'Riya');
      expect(opponent['record'], {'wins': 3, 'losses': 1, 'draws': 0});
      expect(found['sources'], isNotEmpty);
      async.elapse(const Duration(milliseconds: 200));
      final snapshot = client.ofType('match.snapshot').single;
      expect(snapshot['ch'], 'm:${found['match_id']}');
      expect(client.d(snapshot)['phase'], 'ready_wait');
      expect(server.world.last?.subject, 'physics');
      server.dispose();
    });
  });

  test('the first search widens at 15 s and offers the bot at 20 s; Keep searching finds '
      'Riya', () {
    fakeAsync((async) {
      final server = _server();
      final client = _Client(server, async)..open();
      client.send('mm.join', {'mode': 'rated', 'subject': 'physics', 'idem': 'a'});
      async.elapse(const Duration(seconds: 15, milliseconds: 100));
      expect(client.last('mm.status')['widened'], isTrue);
      async.elapse(const Duration(seconds: 5));
      expect(client.last('mm.timeout')['options'], ['keep', 'bot', 'invite', 'cancel']);
      expect(client.ofType('mm.found'), isEmpty);
      expect(server.world.firstSearch, isFalse);

      client.send('mm.respond', {'choice': 'keep'});
      async.elapse(const Duration(seconds: 4, milliseconds: 100));
      expect(client.ofType('mm.found'), hasLength(1));
      server.dispose();
    });
  });

  test('choosing the bot ends the search first, then starts a bot game', () {
    fakeAsync((async) {
      final server = _server();
      final client = _Client(server, async)..open();
      client.send('mm.join', {'mode': 'casual', 'subject': 'physics', 'idem': 'a'});
      async.elapse(const Duration(seconds: 20, milliseconds: 100));
      expect(server.world.coins, 240, reason: 'the casual entry is held');
      client.send('mm.respond', {'choice': 'bot'});
      client.settle();
      final types = client.frames.map((f) => f['t']).toList();
      expect(
        types.sublist(types.indexOf('mm.timeout') + 1),
        containsAllInOrder(['ack', 'mm.cancelled', 'mm.found']),
      );
      expect(client.last('mm.cancelled'), {'reason': 'user', 'refunded': 5});
      expect(client.last('mm.found')['bot'], isTrue);
      expect(server.world.coins, 245);
      server.dispose();
    });
  });

  test('cancel releases a casual hold; a poor player can\'t queue casual', () {
    fakeAsync((async) {
      final server = _server()..world.firstSearch = false;
      final client = _Client(server, async)..open();
      client.send('mm.join', {'mode': 'casual', 'subject': 'physics', 'idem': 'a'});
      client.settle();
      expect(server.world.coins, 240);
      client.send('mm.cancel');
      client.settle();
      expect(client.last('mm.cancelled'), {'reason': 'user', 'refunded': 5});
      expect(server.world.coins, 245);
      expect(server.searching, isFalse);

      server.world.coins = 3;
      client.send('mm.join', {'mode': 'casual', 'subject': 'physics', 'idem': 'b'});
      client.settle();
      expect(client.last('error')['code'], 'INSUFFICIENT_COINS');
      server.dispose();
    });
  });

  test('the Practice Bot starts at once, with mm.found as the reply', () {
    fakeAsync((async) {
      final server = _server();
      final client = _Client(server, async)..open();
      client.send('mm.join', {'mode': 'bot', 'subject': 'physics', 'idem': 'a'});
      client.settle();
      expect(client.ofType('mm.queued'), isEmpty);
      final found = client.last('mm.found');
      expect(found['bot'], isTrue);
      expect((found['opponent']! as Map)['is_bot'], isTrue);
      expect((found['opponent']! as Map).containsKey('rating'), isFalse);
      server.dispose();
    });
  });

  test('10 s in the background stops a search, without a penalty', () {
    fakeAsync((async) {
      final server = _server()..world.firstSearch = false;
      server.findAfter = const Duration(minutes: 1);
      final client = _Client(server, async)..open();
      client.send('mm.join', {'mode': 'rated', 'subject': 'physics', 'idem': 'a'});
      client.send('client.state', {'state': 'background'});
      async.elapse(const Duration(seconds: 9));
      client.send('client.state', {'state': 'foreground'});
      async.elapse(const Duration(seconds: 5));
      expect(client.ofType('mm.cancelled'), isEmpty, reason: 'back in time');
      client.send('client.state', {'state': 'background'});
      async.elapse(const Duration(seconds: 10, milliseconds: 100));
      expect(client.last('mm.cancelled')['reason'], 'background');
      server.dispose();
    });
  });

  test('a match plays 7 questions, reveals each, ends and settles', () {
    fakeAsync((async) {
      final server = _server()
        ..opponentPlan = [
          for (var q = 0; q < 7; q++) const DemoAnswerPlan(correct: false, ms: 3000),
        ];
      final client = _Client(server, async)..open();
      final matchId = _startMatch(client);
      final phase = client.last('match.phase');
      expect(phase['phase'], 'countdown');
      for (var q = 1; q <= 7; q++) {
        async.elapse(const Duration(seconds: 3));
        final show = client.ofType('q.show').map(client.d).last;
        expect(show['q'], q);
        expect(show['options'], hasLength(4));
        expect(show.containsKey('correct'), isFalse, reason: 'nothing leaks early');
        final shownAt = show['shown_at']! as int;
        expect(show['deadline_at'], shownAt + 15000);
        async.elapse(Duration(milliseconds: shownAt - server.now + 1000));
        final id = client.send('ans.submit', {
          'match_id': matchId,
          'q': q,
          'opt': server.correctOption(matchId, q),
          'el_ms': 1000,
        });
        client.settle();
        expect(client.last('ans.ack'), {'ref': id, 'q': q, 'status': 'accepted', 'dup': false});
        async.elapse(const Duration(seconds: 3));
        final reveal = client.ofType('q.reveal').map(client.d).last;
        expect(reveal['q'], q);
        final mine = (reveal['players']! as Map)['u1']! as Map;
        expect(mine['correct'], isTrue);
        expect(mine['pts'], 150, reason: 'full speed bonus within the first second');
        expect(mine['speed'], 'fast');
      }
      async.elapse(const Duration(seconds: 3));
      final end = client.last('match.end');
      expect(end['result'], 'win');
      expect(end['reason'], 'normal');
      expect(((end['totals']! as Map)['u1']! as Map)['points'], 1050);

      async.elapse(const Duration(seconds: 2));
      final settled = client.last('match.settled');
      expect(settled['match_id'], matchId);
      expect(settled['rating'], {
        'scope': 'physics',
        'before': '1502?',
        'after': '1518?',
        'delta': 16,
      });
      expect(settled['rank'], {'board': 'rating:physics', 'before': 47, 'after': 42});
      expect((settled['coins']! as Map)['delta'], 10);
      expect((settled['tip']! as Map)['action'], isNotNull);
      expect(server.world.rating('physics').display, '1518?');
      final summary = server.summaryJson(matchId)!;
      expect(summary['status'], 'settled');
      expect(summary['settlement'], isNotNull);
      final review = server.reviewJson(matchId)!;
      expect(review['questions'], hasLength(7));
      server.dispose();
    });
  });

  test('a repeated answer gets the first verdict again; a stale one is out of phase', () {
    fakeAsync((async) {
      final server = _server();
      final client = _Client(server, async)..open();
      final matchId = _startMatch(client);
      async.elapse(const Duration(seconds: 3));
      final data = {
        'match_id': matchId,
        'q': 1,
        'opt': server.wrongOption(matchId, 1),
        'el_ms': 800,
      };
      client.send('ans.submit', data);
      client.settle();
      final repeat = client.send('ans.submit', data);
      client.settle();
      expect(client.last('ans.ack'), {'ref': repeat, 'q': 1, 'status': 'accepted', 'dup': true});
      client.send('ans.submit', {...data, 'q': 5});
      client.settle();
      expect(client.last('ans.ack')['status'], 'wrong_phase');
      server.dispose();
    });
  });

  test('forfeiting before question 1 aborts; after it, it is a loss', () {
    fakeAsync((async) {
      final server = _server();
      final client = _Client(server, async)..open();
      var matchId = _startMatch(client);
      client.send('match.forfeit', {'match_id': matchId});
      client.settle();
      expect(client.last('match.end')['reason'], 'aborted');

      client.frames.clear();
      server.findAfter = const Duration(seconds: 1);
      client.send('mm.join', {'mode': 'rated', 'subject': 'physics', 'idem': 'x'});
      async.elapse(const Duration(seconds: 1, milliseconds: 200));
      matchId = client.last('mm.found')['match_id']! as String;
      client.send('match.ready', {'match_id': matchId});
      async.elapse(const Duration(seconds: 5));
      client.send('match.forfeit', {'match_id': matchId});
      client.settle();
      expect(client.last('match.end')['result'], 'loss');
      expect(client.last('match.end')['reason'], 'forfeit');
      server.dispose();
    });
  });

  test('an opponent who never gets ready aborts the match and requeues the search', () {
    fakeAsync((async) {
      final server = _server()..opponentNeverReady = true;
      final client = _Client(server, async)..open();
      final matchId = _startMatch(client);
      server.findAfter = const Duration(seconds: 30);
      async.elapse(const Duration(seconds: 10));
      expect(client.last('match.end')['reason'], 'aborted');
      expect(client.last('mm.requeued')['reason'], 'opponent_not_ready');
      expect(server.searching, isTrue);
      expect(server.summaryJson(matchId)!['status'], 'aborted');
      server.dispose();
    });
  });

  test('a withheld settlement is still committed for REST', () {
    fakeAsync((async) {
      final server = _server()
        ..withholdSettlement = true
        ..opponentPlan = [for (var q = 0; q < 7; q++) null];
      final client = _Client(server, async)..open();
      final matchId = _startMatch(client);
      async.elapse(const Duration(minutes: 3));
      expect(client.last('match.end')['result'], 'draw');
      expect(client.ofType('match.settled'), isEmpty);
      expect(server.summaryJson(matchId)!['settlement'], isNotNull);
      server.dispose();
    });
  });

  test('resume replays what was missed; sync from 0 gets a snapshot; unknown is NOT_FOUND', () {
    fakeAsync((async) {
      final server = _server();
      final client = _Client(server, async)..open();
      final matchId = _startMatch(client);
      final lastSeq = client.frames
          .where((f) => f['ch'] == 'm:$matchId' && f['seq'] != null)
          .map((f) => f['seq']! as int)
          .reduce((a, b) => a > b ? a : b);
      server.dropConnection();
      async.elapse(const Duration(seconds: 4));
      final second = _Client(server, async)
        ..open(
          resume: [
            {'ch': 'm:$matchId', 'last_seq': lastSeq},
          ],
        );
      final replayed = second.frames.where((f) => f['ch'] == 'm:$matchId').toList();
      expect(replayed.first['seq'], lastSeq + 1);
      expect(replayed.map((f) => f['t']), contains('q.show'));

      second.send('sync', {'ch': 'm:$matchId', 'last_seq': 0});
      second.settle();
      expect(second.ofType('match.snapshot'), hasLength(1));
      second.send('sync', {'ch': 'm:nope', 'last_seq': 0});
      second.settle();
      expect(second.last('error')['code'], 'NOT_FOUND');
      server.dispose();
    });
  });

  test('a game live elsewhere answers LIVE_ELSEWHERE and 4409, unless taken over', () {
    fakeAsync((async) {
      final server = _server()..liveElsewhereMatchId = 'm7';
      final first = _Client(server, async)..open();
      expect(first.last('error'), containsPair('code', 'LIVE_ELSEWHERE'));
      expect((first.last('error')['details']! as Map)['match_id'], 'm7');
      expect(first.closed, isTrue);
      expect(first.socket!.closeCode, 4409);

      final second = _Client(server, async)..open(takeover: true);
      expect(second.ofType('welcome'), hasLength(1));
      expect(server.connected, isTrue);
      server.dispose();
    });
  });

  test('emotes are echoed to everyone, at most one every 3 s', () {
    fakeAsync((async) {
      final server = _server();
      final client = _Client(server, async)..open();
      final matchId = _startMatch(client);
      client.send('emote', {'match_id': matchId, 'e': 'gg'});
      client.settle();
      expect(client.last('emote'), {'uid': 'u1', 'e': 'gg'});
      client.send('emote', {'match_id': matchId, 'e': 'wow'});
      client.settle();
      expect(client.last('error')['code'], 'RATE_LIMITED');
      server.dispose();
    });
  });

  test('a casual rematch is offered, accepted by Riya, and makes a new match', () {
    fakeAsync((async) {
      final server = _server()
        ..opponentPlan = [
          for (var q = 0; q < 7; q++) const DemoAnswerPlan(correct: true, ms: 1500),
        ];
      final client = _Client(server, async)..open();
      final matchId = _startMatch(client, mode: 'casual');
      async.elapse(const Duration(minutes: 3));
      expect(client.ofType('match.end'), hasLength(1));
      client.send('match.rematch', {'match_id': matchId, 'accept': true});
      client.settle();
      expect(client.last('rematch.status')['state'], 'offered');
      async.elapse(const Duration(seconds: 2));
      final states = client.ofType('rematch.status').map((f) => client.d(f)['state']);
      expect(states, ['offered', 'accepted']);
      expect(client.last('mm.found')['match_id'], isNot(matchId));
      expect(client.last('mm.found')['mode'], 'casual');
      server.dispose();
    });
  });

  test('BUSY carries where the user already is', () {
    fakeAsync((async) {
      final server = _server()..busyOnJoin = {'kind': 'match', 'id': 'm9', 'title': 'Quick battle'};
      final client = _Client(server, async)..open();
      client.send('mm.join', {'mode': 'rated', 'subject': 'physics', 'idem': 'a'});
      client.settle();
      final error = client.last('error');
      expect(error['code'], 'BUSY');
      expect((error['details']! as Map)['active'], {
        'kind': 'match',
        'id': 'm9',
        'title': 'Quick battle',
      });
      server.dispose();
    });
  });
}
