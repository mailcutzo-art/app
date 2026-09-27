import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_app/features/practice/data/practice_models.dart';
import 'package:quiz_app/features/practice/data/session_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/fakes.dart';
import '../../support/learn_samples.dart';

void main() {
  late SharedPreferences prefs;
  final now = DateTime.utc(2026, 9, 27, 16);

  setUp(() async => prefs = await testPrefs());

  PracticeSessionStore store({String user = 'u1', DateTime? at}) =>
      PracticeSessionStore(prefs, userId: user, now: () => at ?? now);

  PracticeSession session({String id = 's-1'}) =>
      PracticeSession.fromJson(sessionJson()..['session_id'] = id);

  const settings = SessionSettings(
    mode: PracticeMode.chapter,
    subject: 'physics',
    chapters: ['kinematics'],
    count: 20,
  );

  test('a session reads back from disk exactly as the API sent it', () {
    final original = session();
    final copy = PracticeSession.fromJson(original.toJson());
    expect(copy.toJson(), original.toJson());
    expect(copy.questions.single.options, original.questions.single.options);
    expect(copy.createdAt, original.createdAt);
  });

  test('a created session is known at once, and becomes the active one on disk', () async {
    final first = store();
    await first.save(session(), settings);

    expect(first.activeFor('s-1')?.session.title, 'Physics · Motion in a Straight Line');
    expect(first.recent('s-1'), isNotNull);
    expect(first.settings('s-1'), settings);

    // A cold start (e.g. the app was killed offline): only the disk is left.
    SharedPreferences.resetStatic();
    prefs = await SharedPreferences.getInstance();
    final restarted = store();
    final active = restarted.active();
    expect(active?.session.sessionId, 's-1');
    expect(active?.session.questions.single.ref, 'q_01929f');
    expect(restarted.activeFor('s-1'), isNotNull);
    expect(restarted.recent('s-1'), isNull, reason: 'memory is gone after a restart');
    expect(restarted.settings('s-1'), settings, reason: '"Practise again" still works');
  });

  test('answers and bookmarks given so far are saved with the active session', () async {
    final first = store();
    await first.save(session(), settings);
    await first.saveProgress(
      's-1',
      answers: {
        1: const SessionAnswer(
          position: 1,
          selectedOption: 1,
          outcome: AnswerOutcome.correct,
          timeMs: 900,
        ),
      },
      bookmarks: {'q_01929f'},
    );

    final restarted = store();
    expect(restarted.active()?.answers.values.single.outcome, AnswerOutcome.correct);
    expect(restarted.active()?.bookmarks, {'q_01929f'});
  });

  test('finishing clears the active session; another session doesn\'t', () async {
    final s = store();
    await s.save(session(), settings);
    await s.clearActive('other');
    expect(s.active(), isNotNull);

    await s.clearActive('s-1');
    expect(s.active(), isNull);
    expect(store().active(), isNull, reason: 'gone from disk too');
  });

  test('an expired session is not offered for continuing', () async {
    await store().save(session(), settings);
    final dayLater = store(at: DateTime.utc(2026, 9, 28, 15));
    expect(dayLater.active(), isNull);
    expect(store().active(), isNull, reason: 'and it is removed');
  });

  test('each user has their own sessions on the device', () async {
    await store(user: 'a').save(session(), settings);
    final b = store(user: 'b');
    expect(b.active(), isNull);
    expect(b.activeFor('s-1'), isNull);
    expect(b.settings('s-1'), isNull);
    expect(store(user: 'a').active(), isNotNull);
  });

  test('only the last 20 sessions\' settings are kept', () async {
    final s = store();
    for (var i = 0; i < 25; i++) {
      await s.save(session(id: 's$i'), settings);
    }
    expect(s.settings('s0'), isNull);
    expect(s.settings('s4'), isNull);
    expect(s.settings('s5'), settings);
    expect(s.settings('s24'), settings);
    expect(s.active()?.session.sessionId, 's24', reason: 'the newest is active');
  });

  test('unreadable saved data is dropped instead of crashing', () async {
    await prefs.setString('practice.active.u1', '{"session_id": 1}');
    await prefs.setString('practice.settings.u1', 'not json');
    final s = store();
    expect(s.active(), isNull);
    expect(s.settings('s-1'), isNull);
  });
}
