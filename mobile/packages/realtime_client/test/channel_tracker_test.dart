import 'package:realtime_client/realtime_client.dart';
import 'package:test/test.dart';

import 'support/frames.dart';

void main() {
  late ChannelTracker tracker;

  setUp(() => tracker = ChannelTracker());

  SeqDecision accept(String type, String? ch, int? seq, [Map<String, Object?> data = const {}]) =>
      tracker.accept(event(type, data, ch, seq));

  SeqDecision matchEvent(int seq) =>
      accept('q.progress', 'm:M1', seq, {'q': 1, 'answered': <String>[]});

  SeqDecision snapshot(String ch, int seq) => accept('match.snapshot', ch, seq, {
    'match_id': ch.substring(2),
    'phase': 'q_open',
    'q': 1,
    'total': 7,
    'players': <Object?>[],
  });

  test('applies events in order', () {
    expect(snapshot('m:M1', 0), SeqDecision.apply);
    expect([matchEvent(1), matchEvent(2), matchEvent(3)], everyElement(SeqDecision.apply));
    expect(tracker.lastSeq('m:M1'), 3);
  });

  test('drops duplicates: any seq at or below the last applied one', () {
    snapshot('m:M1', 5);

    expect(matchEvent(5), SeqDecision.duplicate);
    expect(matchEvent(2), SeqDecision.duplicate);
    expect(matchEvent(6), SeqDecision.apply);
    expect(matchEvent(6), SeqDecision.duplicate);
  });

  test('reports a gap without moving the last seq', () {
    snapshot('m:M1', 5);

    expect(matchEvent(7), SeqDecision.gap);
    expect(matchEvent(9), SeqDecision.gap);
    expect(tracker.lastSeq('m:M1'), 5);
    expect(matchEvent(6), SeqDecision.apply);
    expect(matchEvent(7), SeqDecision.apply);
  });

  test('a snapshot resets the seq, forwards or backwards', () {
    snapshot('m:M1', 5);
    matchEvent(7);

    expect(snapshot('m:M1', 40), SeqDecision.apply);
    expect(tracker.lastSeq('m:M1'), 40);
    expect(matchEvent(41), SeqDecision.apply);

    expect(snapshot('m:M1', 12), SeqDecision.apply);
    expect(tracker.lastSeq('m:M1'), 12);
    expect(matchEvent(13), SeqDecision.apply);
  });

  test('room.state is the snapshot of a room channel', () {
    expect(accept('room.state', 'r:R1', 9, _roomState), SeqDecision.apply);
    expect(tracker.lastSeq('r:R1'), 9);
    expect(accept('room.state', 'r:R1', 3, _roomState), SeqDecision.apply);
    expect(tracker.lastSeq('r:R1'), 3);
  });

  test('a new channel starts at 0: seq 1 applies, a later seq is a gap', () {
    expect(matchEvent(1), SeqDecision.apply);
    expect(accept('room.started', 'r:R1', 4, {'match_id': 'M2'}), SeqDecision.gap);
    expect(tracker.lastSeq('r:R1'), 0);
    expect(tracker.resumeList(), contains(const ResumeEntry('r:R1', 0)));
  });

  test('channels without seq, and non-resumable channels, always apply', () {
    expect(accept('mm.status', 'u', 7, {'waited_s': 1}), SeqDecision.apply);
    expect(accept('mm.status', 'u', 7, {'waited_s': 1}), SeqDecision.apply);
    expect(accept('t.round', 't:T1', 3, {'round': 1, 'status': 'live'}), SeqDecision.apply);
    expect(
      accept('ans.ack', 'm:M1', null, {'ref': 'c1', 'q': 1, 'status': 'dup'}),
      SeqDecision.apply,
    );
    expect(accept('ping', null, null, {'n': 1}), SeqDecision.apply);
    expect(tracker.channels, isEmpty);
  });

  test('builds the resume list for hello', () {
    snapshot('m:M1', 0);
    for (var seq = 1; seq <= 41; seq++) {
      matchEvent(seq);
    }
    accept('room.state', 'r:R1', 4, _roomState);
    tracker.track('m:M2');

    expect(tracker.resumeList(), const [
      ResumeEntry('m:M1', 41),
      ResumeEntry('r:R1', 4),
      ResumeEntry('m:M2', 0),
    ]);
    expect(tracker.resumeList().first.toJson(), {'ch': 'm:M1', 'last_seq': 41});
  });

  test('track only adds channels it does not know yet', () {
    snapshot('m:M1', 8);
    tracker
      ..track('m:M1')
      ..track('u')
      ..track('t:T1');

    expect(tracker.resumeList(), const [ResumeEntry('m:M1', 8)]);
  });

  test('forgotten channels leave the resume list, and late events pass through', () {
    snapshot('m:M1', 20);
    tracker.forget('m:M1');

    expect(tracker.resumeList(), isEmpty);
    expect(tracker.isTracked('m:M1'), isFalse);
    expect(matchEvent(25), SeqDecision.apply, reason: 'no gap handling for a forgotten channel');
    expect(tracker.resumeList(), isEmpty);
  });

  test('a snapshot on a forgotten channel tracks it again', () {
    accept('room.state', 'r:R1', 3, _roomState);
    tracker.forget('r:R1');

    expect(accept('room.state', 'r:R1', 10, _roomState), SeqDecision.apply);
    expect(tracker.resumeList(), const [ResumeEntry('r:R1', 10)]);
  });

  test('isResumable', () {
    expect(ChannelTracker.isResumable('m:M1'), isTrue);
    expect(ChannelTracker.isResumable('r:R1'), isTrue);
    expect(ChannelTracker.isResumable('t:T1'), isFalse);
    expect(ChannelTracker.isResumable('u'), isFalse);
  });
}

const _roomState = <String, Object?>{
  'room_id': 'R1',
  'kind': 'friend',
  'host': 'u1',
  'status': 'lobby',
  'members': <Object?>[],
};
