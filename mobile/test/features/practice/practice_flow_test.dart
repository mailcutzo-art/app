import 'dart:async';
import 'dart:convert';

import 'package:design_system/design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_app/app/router.dart';
import 'package:quiz_app/core/network/app_failure.dart';
import 'package:quiz_app/features/learn/data/fake_learn_repository.dart';
import 'package:quiz_app/features/practice/ask_ai.dart';
import 'package:quiz_app/features/practice/data/answer_queue.dart';
import 'package:quiz_app/features/practice/data/practice_models.dart';
import 'package:quiz_app/features/practice/start_practice.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/fakes.dart';

const _kinematics = SessionSettings(
  mode: PracticeMode.chapter,
  subject: 'physics',
  chapters: ['kinematics'],
);

/// Two questions: Newton's laws, then friction.
const _lawsOfMotion = SessionSettings(
  mode: PracticeMode.chapter,
  subject: 'physics',
  chapters: ['laws-of-motion'],
);

Finder _option(String text) => find.byWidgetPredicate((w) => w is AnswerOption && w.text == text);

AnswerOptionState _state(WidgetTester tester, String text) =>
    tester.widget<AnswerOption>(_option(text)).state;

Finder _iconButton(String label) =>
    find.byWidgetPredicate((w) => w is AppIconButton && w.semanticLabel == label);

PracticeOption _correct(PracticeQuestion q) => q.options.firstWhere((o) => o.id == q.answer);

PracticeOption _wrong(PracticeQuestion q) => q.options.firstWhere((o) => o.id != q.answer);

String _letter(PracticeQuestion q) =>
    String.fromCharCode(65 + q.options.indexWhere((o) => o.id == q.answer));

/// Opens a session made the way the app makes them (so "Practise again"
/// knows its settings), on top of the Learn tab.
Future<(ProviderContainer, PracticeSession)> _open(
  WidgetTester tester,
  FakeLearnRepository learn, {
  SessionSettings settings = _kinematics,
  FakeStopwatch? clock,
  SharedPreferences? prefs,
}) async {
  final container = await pumpApp(
    tester,
    prefs: prefs ?? await testPrefs(),
    learn: learn,
    stopwatch: clock == null ? null : () => clock,
    location: Routes.learn,
  );
  final session = await container
      .read(practiceStarterProvider)
      .start(settings, idempotencyKey: 'key-1');
  await tester.runAsync(() async {});
  unawaited(container.read(routerProvider).push(Routes.practiceSession(session.sessionId)));
  await tester.pumpAndSettle();
  return (container, session);
}

void main() {
  late FakeLearnRepository learn;

  setUp(() => learn = FakeLearnRepository.seeded());

  testWidgets('a correct answer turns mint, shows the explanation, then Next', (tester) async {
    usePhoneViewport(tester, height: 900);
    final (_, session) = await _open(tester, learn);
    final q = session.questions.first;
    expect(find.text('QUESTION 1 / 4'), findsOneWidget);
    expect(find.text('SPEED AND VELOCITY'), findsOneWidget, reason: 'topic overline');

    await tester.tap(_option(_correct(q).text));
    await tester.pumpAndSettle();

    expect(_state(tester, _correct(q).text), AnswerOptionState.correct);
    for (final other in q.options.where((o) => o.id != q.answer)) {
      expect(_state(tester, other.text), AnswerOptionState.dimmed);
    }
    expect(find.text('Correct'), findsOneWidget);
    expect(
      find.textContaining('Displacement is the straight-line change', findRichText: true),
      findsOneWidget,
    );
    final upload = learn.uploadedAnswers.single;
    expect(upload.selectedOption, q.answer);
    expect(upload.skipped || upload.timedOut, isFalse);

    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    expect(find.text('QUESTION 2 / 4'), findsOneWidget);
    expect(find.text('Skip'), findsOneWidget);
  });

  testWidgets('a wrong answer turns rose and the correct one is highlighted', (tester) async {
    usePhoneViewport(tester, height: 900);
    final (_, session) = await _open(tester, learn);
    final q = session.questions.first;
    final wrong = _wrong(q);

    await tester.tap(_option(wrong.text));
    await tester.pumpAndSettle();

    expect(_state(tester, wrong.text), AnswerOptionState.wrong);
    expect(_state(tester, _correct(q).text), AnswerOptionState.correct);
    expect(
      q.options.where((o) => _state(tester, o.text) == AnswerOptionState.dimmed),
      hasLength(2),
    );
    expect(find.text('Not quite · the answer is ${_letter(q)}'), findsOneWidget);
    expect(learn.uploadedAnswers.single.selectedOption, wrong.id);

    // The answer is locked.
    await tester.tap(_option(_correct(q).text));
    await tester.pumpAndSettle();
    expect(learn.uploadedAnswers, hasLength(1));
  });

  testWidgets('skip records a skipped answer and shows the right one', (tester) async {
    usePhoneViewport(tester, height: 900);
    final (_, session) = await _open(tester, learn);
    final q = session.questions.first;

    await tester.tap(find.text('Skip'));
    await tester.pumpAndSettle();

    final upload = learn.uploadedAnswers.single;
    expect(upload.skipped, isTrue);
    expect(upload.selectedOption, isNull);
    expect(_state(tester, _correct(q).text), AnswerOptionState.correct);
    expect(find.text('Skipped · the answer is ${_letter(q)}'), findsOneWidget);
  });

  testWidgets('a skipped question offers ChatGPT beside Next, with the question filled in', (
    tester,
  ) async {
    usePhoneViewport(tester, height: 900);
    final opened = <Uri>[];
    final copied = <String>[];
    final container = await pumpApp(
      tester,
      prefs: await testPrefs(),
      learn: learn,
      location: Routes.learn,
      overrides: [
        askAiUrlOpenerProvider.overrideWithValue((uri, mode) async {
          opened.add(uri);
          return true;
        }),
        askAiClipboardProvider.overrideWithValue((text) async => copied.add(text)),
      ],
    );
    final session = await container
        .read(practiceStarterProvider)
        .start(_kinematics, idempotencyKey: 'key-1');
    await tester.runAsync(() async {});
    unawaited(container.read(routerProvider).push(Routes.practiceSession(session.sessionId)));
    await tester.pumpAndSettle();
    final q = session.questions.first;
    final ask = _iconButton('Ask ChatGPT to explain this question');

    // Not before skipping, and not after a real answer.
    expect(ask, findsNothing);
    await tester.tap(find.text('Skip'));
    await tester.pumpAndSettle();
    expect(ask, findsOneWidget);
    expect(find.text('Next'), findsOneWidget);

    await tester.tap(ask);
    await tester.pumpAndSettle();
    final prompt = opened.single.queryParameters['q']!;
    expect(opened.single.host, 'chatgpt.com');
    expect(prompt, contains('Correct answer: ${_letter(q)}) ${_correct(q).text}'));
    expect(copied, [prompt]);

    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    await tester.tap(_option(_correct(session.questions[1]).text));
    await tester.pumpAndSettle();
    expect(ask, findsNothing);
  });

  testWidgets('in timed mode, running out of time records timed_out and reveals', (tester) async {
    usePhoneViewport(tester, height: 900);
    final clock = FakeStopwatch();
    final (_, session) = await _open(
      tester,
      learn,
      clock: clock,
      settings: const SessionSettings(
        mode: PracticeMode.chapter,
        subject: 'physics',
        chapters: ['kinematics'],
        timed: true,
        perQuestionS: 30,
      ),
    );
    final q = session.questions.first;
    CountdownRing ring() => tester.widget<CountdownRing>(find.byType(CountdownRing));
    expect(ring().label, '30');

    clock.advance(const Duration(seconds: 12));
    await tester.pump(const Duration(milliseconds: 150));
    expect(ring().label, '18');

    clock.advance(const Duration(seconds: 19));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pumpAndSettle();

    final upload = learn.uploadedAnswers.single;
    expect(upload.timedOut, isTrue);
    expect(upload.selectedOption, isNull);
    expect(upload.timeMs, 30000, reason: 'a timeout records the full limit');
    expect(find.text('Time\'s up · the answer is ${_letter(q)}'), findsOneWidget);
    expect(_state(tester, _correct(q).text), AnswerOptionState.correct);
    expect(ring().label, '0');
  });

  testWidgets('time_ms is the time the question was on screen, paused in the background', (
    tester,
  ) async {
    usePhoneViewport(tester, height: 900);
    final clock = FakeStopwatch();
    final (_, session) = await _open(tester, learn, clock: clock);
    final binding = tester.binding;

    clock.advance(const Duration(seconds: 3));
    binding
      ..handleAppLifecycleStateChanged(AppLifecycleState.inactive)
      ..handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    expect(clock.isRunning, isFalse);
    clock.advance(const Duration(minutes: 5));
    binding
      ..handleAppLifecycleStateChanged(AppLifecycleState.inactive)
      ..handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(clock.isRunning, isTrue);
    clock.advance(const Duration(seconds: 2));

    await tester.tap(_option(_correct(session.questions.first).text));
    await tester.pumpAndSettle();
    expect(learn.uploadedAnswers.single.timeMs, 5000);
  });

  testWidgets('finishing shows the numbers, time, XP and the per-topic list', (tester) async {
    usePhoneViewport(tester, height: 1100);
    final (_, session) = await _open(tester, learn, settings: _lawsOfMotion);
    final [first, second] = session.questions;

    await tester.tap(_option(_correct(first).text));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    await tester.tap(_option(_wrong(second).text));
    await tester.pumpAndSettle();
    expect(find.text('Finish'), findsOneWidget);
    await tester.tap(find.text('Finish'));
    await tester.pumpAndSettle();

    expect(learn.finishCalls, [session.sessionId]);
    expect(find.text('Practice complete'), findsOneWidget);
    expect(tester.widget<NumberTicker>(find.byType(NumberTicker)).value, 1);
    expect(find.text(' / 2'), findsOneWidget);
    expect(find.text('+3'), findsOneWidget, reason: '2 XP for the right answer, 1 for the other');
    expect(find.text('Newton\'s laws'), findsOneWidget);
    expect(find.text('1/1'), findsOneWidget);
    expect(find.text('Friction'), findsOneWidget);
    expect(find.text('0/1'), findsOneWidget);
    expect(find.text('Syncing…'), findsNothing);
    expect(find.text('Practise again'), findsOneWidget);
    expect(find.text('Done'), findsOneWidget);
  });

  testWidgets('offline, the summary is worked out here and syncs later', (tester) async {
    usePhoneViewport(tester, height: 1100);
    final (container, session) = await _open(tester, learn, settings: _lawsOfMotion);
    learn.failures[FakeLearnOp.finish] = const NetworkFailure();

    for (final q in session.questions) {
      await tester.tap(_option(_correct(q).text));
      await tester.pumpAndSettle();
      await tester.tap(find.text(q == session.questions.last ? 'Finish' : 'Next'));
      await tester.pumpAndSettle();
    }

    expect(find.text('Practice complete'), findsOneWidget);
    expect(find.text('Syncing…'), findsOneWidget);
    expect(tester.widget<NumberTicker>(find.byType(NumberTicker)).value, 2);
    expect(find.text('—'), findsOneWidget, reason: 'XP is only known once the server has it');

    learn.failures.clear();
    await tester.runAsync(() => container.read(answerQueueProvider).flush());
    await tester.pumpAndSettle();

    expect(find.text('Syncing…'), findsNothing);
    expect(find.text('+4'), findsOneWidget);
  });

  testWidgets('Practise again starts the same settings with a new key', (tester) async {
    usePhoneViewport(tester, height: 1100);
    final (_, session) = await _open(tester, learn, settings: _lawsOfMotion);
    for (final q in session.questions) {
      await tester.tap(find.text('Skip'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(q == session.questions.last ? 'Finish' : 'Next'));
      await tester.pumpAndSettle();
    }

    await tester.tap(find.text('Practise again'));
    await tester.pumpAndSettle();

    expect(learn.createCalls, hasLength(2));
    expect(learn.createCalls.last.$1, _lawsOfMotion);
    expect(learn.createCalls.last.$2, isNot(learn.createCalls.first.$2));
    expect(find.text('QUESTION 1 / 2'), findsOneWidget);
  });

  testWidgets('closing asks first, and leaving keeps the answers', (tester) async {
    usePhoneViewport(tester, height: 900);
    final (_, session) = await _open(tester, learn);
    await tester.tap(_option(_correct(session.questions.first).text));
    await tester.pumpAndSettle();

    await tester.tap(_iconButton('Leave practice'));
    await tester.pumpAndSettle();
    expect(find.text('Leave practice?'), findsOneWidget);
    expect(find.text('Your answers so far are saved.'), findsOneWidget);

    await tester.tap(find.text('Keep practising'));
    await tester.pumpAndSettle();
    expect(find.text('Leave practice?'), findsNothing);
    expect(find.text('QUESTION 1 / 4'), findsOneWidget);

    // The system back gesture asks too.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Leave practice?'), findsOneWidget);
    await tester.tap(find.text('Leave'));
    await tester.pumpAndSettle();

    expect(find.text('Practice tools'), findsOneWidget, reason: 'back on the Learn tab');
    expect(learn.uploadedAnswers, hasLength(1));
  });

  testWidgets('resuming continues at the first unanswered question; queued answers count', (
    tester,
  ) async {
    usePhoneViewport(tester, height: 900);
    final session = await learn.createSession(_kinematics, idempotencyKey: 'elsewhere');
    final [q1, q2, ...] = session.questions;
    // The server has the first answer; the second is still queued on the phone.
    await learn.uploadAnswers(session.sessionId, [
      AnswerUpload.create(ref: q1.ref, position: 1, selectedOption: q1.answer, timeMs: 1000),
    ]);
    final queued = AnswerUpload.create(ref: q2.ref, position: 2, selectedOption: 0, timeMs: 1000);
    final prefs = await testPrefs({
      'practice.queue.u1.${session.sessionId}': jsonEncode([queued.toJson()]),
    });
    learn.failures[FakeLearnOp.uploadAnswers] = const NetworkFailure();

    await pumpApp(
      tester,
      prefs: prefs,
      learn: learn,
      location: Routes.practiceSession(session.sessionId),
    );

    expect(find.text('QUESTION 3 / 4'), findsOneWidget);
    final progress = tester.widget<SegmentedProgress>(find.byType(SegmentedProgress));
    expect(progress.completed, 2);
  });

  testWidgets('bookmarking is optimistic, and put back with a toast if it fails', (tester) async {
    usePhoneViewport(tester, height: 900);
    final (_, session) = await _open(tester, learn);
    final ref = session.questions.first.ref;

    await tester.tap(_iconButton('Bookmark question'));
    await tester.pumpAndSettle();
    expect(_iconButton('Remove bookmark'), findsOneWidget);
    expect(learn.bookmarkCalls.single, (ref, true));

    learn
      ..failures[FakeLearnOp.bookmark] = const NetworkFailure()
      ..latency = const Duration(milliseconds: 300);
    await tester.tap(_iconButton('Remove bookmark'));
    await tester.pump();
    expect(_iconButton('Bookmark question'), findsOneWidget, reason: 'flips at once');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(_iconButton('Remove bookmark'), findsOneWidget, reason: 'put back');
    expect(find.text('You\'re offline, so the bookmark wasn\'t saved.'), findsOneWidget);
    expect(learn.bookmarks, {ref});
  });

  testWidgets('answers the server refused are reported on the summary', (tester) async {
    usePhoneViewport(tester, height: 1100);
    final (_, session) = await _open(tester, learn, settings: _lawsOfMotion);
    learn.expireSession(session.sessionId);

    for (final q in session.questions) {
      await tester.tap(_option(_correct(q).text));
      await tester.pumpAndSettle();
      await tester.tap(find.text(q == session.questions.last ? 'Finish' : 'Next'));
      await tester.pumpAndSettle();
    }

    expect(find.text('2 answers couldn\'t be saved: the session had expired'), findsOneWidget);
  });

  testWidgets('a capped XP day says so instead of showing a small number', (tester) async {
    usePhoneViewport(tester, height: 1100);
    learn.xpCapped = true;
    final (_, session) = await _open(tester, learn, settings: _lawsOfMotion);
    for (final q in session.questions) {
      await tester.tap(find.text('Skip'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(q == session.questions.last ? 'Finish' : 'Next'));
      await tester.pumpAndSettle();
    }

    expect(find.text('Daily practice XP limit reached · resets at midnight'), findsOneWidget);
    expect(find.text('XP gained'), findsNothing);
  });

  testWidgets('a session survives the app being killed offline and continues from Learn', (
    tester,
  ) async {
    usePhoneViewport(tester, height: 1100);
    var prefs = await testPrefs();
    final (_, session) = await _open(tester, learn, prefs: prefs);

    // Answer one question, then the network goes and a second is answered.
    await tester.tap(_option(_correct(session.questions[0]).text));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    for (final op in FakeLearnOp.values) {
      learn.failures[op] = const NetworkFailure();
    }
    await tester.tap(find.text('Skip'));
    await tester.pumpAndSettle();

    // The app is killed, then started again, still offline.
    await tester.pumpWidget(const SizedBox());
    SharedPreferences.resetStatic();
    prefs = await tester.runAsync(SharedPreferences.getInstance) as SharedPreferences;
    await pumpApp(tester, prefs: prefs, learn: learn, location: Routes.learn);

    expect(find.text('Couldn\'t load your progress'), findsOneWidget);
    expect(find.text('Physics · Motion in a Straight Line'), findsOneWidget);
    expect(find.text('2/4'), findsOneWidget);

    await tester.tap(find.text('Resume'));
    await tester.pumpAndSettle();
    expect(find.text('QUESTION 3 / 4'), findsOneWidget);

    // Finishing offline clears the saved session.
    for (final q in session.questions.skip(2)) {
      await tester.tap(find.text('Skip'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(q == session.questions.last ? 'Finish' : 'Next'));
      await tester.pumpAndSettle();
    }
    expect(find.text('Syncing…'), findsOneWidget);
    expect(prefs.getString('practice.active.u1'), isNull);
  });
}
