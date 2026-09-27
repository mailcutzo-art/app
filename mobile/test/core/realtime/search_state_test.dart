import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_app/core/realtime/search_state.dart';
import 'package:realtime_client/realtime_client.dart';

import '../../support/rt_server.dart';

const _now = 1790000060000;

SearchState _apply(SearchState state, ServerEvent event) =>
    reduceSearch(state, event, nowServerMs: _now);

ServerEvent _queued({String? chapter = 'kinematics', int? joinedAt = _now - 2000}) =>
    event('mm.queued', {
      'ticket_id': 't1',
      'mode': 'rated',
      'subject': 'physics',
      'chapter': chapter,
      'joined_at': joinedAt,
    });

void main() {
  const request = SearchRequest(
    mode: 'rated',
    subject: 'physics',
    chapter: 'kinematics',
    subjectName: 'Physics',
    chapterName: 'Motion in a Straight Line',
  );

  test('joining keeps the request and the online figures from the tab', () {
    final state = SearchState.joining(request, online: 3, p50WaitS: 20);
    expect(state.phase, SearchPhase.joining);
    expect(state.isSearching, isFalse);
    expect(state.online, 3);
  });

  test('mm.queued starts the search, keeping the names the tab knew', () {
    final state = _apply(SearchState.joining(request, online: 3), _queued());
    expect(state.phase, SearchPhase.queued);
    expect(state.isSearching, isTrue);
    expect(state.ticketId, 't1');
    expect(state.joinedAt, _now - 2000);
    expect(state.request?.subjectLabel, 'Physics');
    expect(state.request?.chapterLabel, 'Motion in a Straight Line');
    expect(state.online, 3);
  });

  test('without joined_at the search starts now; unknown names fall back to the slug', () {
    final state = _apply(const SearchState(), _queued(joinedAt: null, chapter: 'laws-of-motion'));
    expect(state.joinedAt, _now);
    expect(state.request?.chapterLabel, 'Laws Of Motion');
  });

  test('mm.status widens (for good) and updates who is searching', () {
    var state = _apply(SearchState.joining(request), _queued());
    state = _apply(
      state,
      event('mm.status', {'waited_s': 15, 'widened': true, 'online': 4, 'p50_wait_s': 25}),
    );
    expect(state.widened, isTrue);
    expect(state.waitedS, 15);
    expect(state.online, 4);
    expect(state.p50WaitS, 25);
    state = _apply(state, event('mm.status', {'waited_s': 20, 'widened': false}));
    expect(state.widened, isTrue, reason: 'a widened search stays widened');
    expect(state.online, 4);
  });

  test('mm.status after a cold start dates the search from waited_s', () {
    final adopted = const SearchState().adoptQueue(ticketId: 't9');
    expect(adopted.phase, SearchPhase.queued);
    final state = _apply(adopted, event('mm.status', {'waited_s': 30}));
    expect(state.joinedAt, _now - 30000);
  });

  test('mm.status is ignored when not searching', () {
    const idle = SearchState();
    expect(_apply(idle, event('mm.status', {'waited_s': 3})), idle);
  });

  test('mm.timeout offers the options once per offer; keep goes back to searching', () {
    var state = _apply(SearchState.joining(request), _queued());
    state = _apply(
      state,
      event('mm.timeout', {
        'waited_s': 20,
        'options': ['keep', 'bot', 'invite', 'cancel'],
      }),
    );
    expect(state.phase, SearchPhase.offered);
    expect(state.isSearching, isTrue, reason: 'still searching while the sheet is up');
    expect(state.options, ['keep', 'bot', 'invite', 'cancel']);
    expect(state.offers, 1);
    state = state.keepSearching();
    expect(state.phase, SearchPhase.queued);
    expect(state.offers, 1);
  });

  test('mm.cancelled ends the search and says why, with the refund', () {
    final queued = _apply(SearchState.joining(request), _queued());
    final state = _apply(queued, event('mm.cancelled', {'reason': 'background', 'refunded': 5}));
    expect(state.phase, SearchPhase.idle);
    expect(state.lastEnd, const SearchEnd(reason: 'background', refunded: 5));
    expect(state.request, request, reason: 'kept for "Search again"');
  });

  test('mm.requeued puts the search back with its original waiting time', () {
    final found = _apply(
      _apply(SearchState.joining(request), _queued()),
      event('mm.found', {
        'match_id': 'm1',
        'opponent': {'uid': 'riya'},
      }),
    );
    expect(found.phase, SearchPhase.matched);
    expect(found.matchId, 'm1');
    final state = _apply(
      found,
      event('mm.requeued', {'reason': 'opponent_not_ready', 'waited_s': 31}),
    );
    expect(state.phase, SearchPhase.queued);
    expect(state.requeued, isTrue);
    expect(state.joinedAt, _now - 31000);
    expect(state.waitedS, 31);
  });

  test('a failed join goes back to idle, keeping the request', () {
    final state = SearchState.joining(request).joinFailed();
    expect(state.phase, SearchPhase.idle);
    expect(state.request, request);
  });

  test('a search the server dropped while the app was away says so', () {
    final queued = _apply(SearchState.joining(request), _queued());
    final state = queued.stoppedWhileAway();
    expect(state.phase, SearchPhase.idle);
    expect(state.lastEnd?.reason, 'away');
    expect(state.lastEnd?.byUser, isFalse);
  });

  test('events of other kinds change nothing', () {
    final queued = _apply(SearchState.joining(request), _queued());
    expect(_apply(queued, event('notify', {'id': 'n', 'kind': 'refund', 'title': 'x'})), queued);
  });

  test('SearchRequest builds mm.join and switches mode for the bot', () {
    expect(request.toJoin('k1'), {
      'mode': 'rated',
      'subject': 'physics',
      'chapter': 'kinematics',
      'idem': 'k1',
    });
    final bot = request.withMode('bot');
    expect(bot.isBot, isTrue);
    expect(bot.chapter, 'kinematics');
    expect(const SearchRequest(mode: 'casual', subject: 'physics').chapterLabel, isNull);
  });
}
