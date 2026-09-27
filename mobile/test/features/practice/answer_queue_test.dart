import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_app/app/env.dart';
import 'package:quiz_app/core/auth/session.dart';
import 'package:quiz_app/core/auth/user.dart';
import 'package:quiz_app/core/network/app_failure.dart';
import 'package:quiz_app/core/network/connectivity.dart';
import 'package:quiz_app/core/storage/prefs.dart';
import 'package:quiz_app/features/learn/data/fake_learn_repository.dart';
import 'package:quiz_app/features/learn/data/learn_repository.dart';
import 'package:quiz_app/features/practice/data/answer_queue.dart';
import 'package:quiz_app/features/practice/data/practice_models.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/fakes.dart';

AnswerUpload _answer(int position, {String? id, DateTime? at}) => AnswerUpload(
  clientAnswerId: id ?? 'a$position',
  ref: 'q$position',
  position: position,
  selectedOption: 0,
  timeMs: 1000,
  answeredAt: at ?? DateTime.now().toUtc(),
);

AnswersResponse _all(List<AnswerUpload> answers, AnswerStatus status) => AnswersResponse(
  results: [
    for (final a in answers) AnswerResult(clientAnswerId: a.clientAnswerId, status: status),
  ],
);

/// A scripted server: by default it accepts every answer and finishes.
class _Server {
  final uploads = <(String, List<AnswerUpload>)>[];
  final finishes = <String>[];
  final events = <String>[];
  AppFailure? failWith;
  FutureOr<AnswersResponse> Function(String session, List<AnswerUpload> answers)? respond;
  Completer<void>? hold;

  Future<AnswersResponse> upload(String session, List<AnswerUpload> answers) async {
    uploads.add((session, answers));
    events.add('upload $session');
    await hold?.future;
    if (failWith case final failure?) throw failure;
    return respond?.call(session, answers) ?? _all(answers, AnswerStatus.accepted);
  }

  Future<SessionSummary> finish(String session) async {
    finishes.add(session);
    events.add('finish $session');
    if (failWith case final failure?) throw failure;
    return SessionSummary(sessionId: session, answered: 1, correct: 1, skipped: 0, timeMs: 1000);
  }
}

void main() {
  late SharedPreferences prefs;
  late _Server server;
  final backoffs = <int>[];

  setUp(() async {
    prefs = await testPrefs();
    server = _Server();
    backoffs.clear();
  });

  AnswerQueue queue({String user = 'u1', Duration retry = const Duration(hours: 1)}) {
    final q = AnswerQueue(
      prefs: prefs,
      userId: user,
      upload: server.upload,
      finish: server.finish,
      backoff: (attempt) {
        backoffs.add(attempt);
        return retry;
      },
    );
    addTearDown(q.dispose);
    return q;
  }

  List<Object?> saved(String session, {String user = 'u1'}) =>
      jsonDecode(prefs.getString('practice.queue.$user.$session') ?? '[]') as List<Object?>;

  test('an answer is saved on the device before any upload, then sent', () async {
    server.hold = Completer<void>();
    final q = queue();

    await q.add('s1', _answer(1));

    expect(saved('s1'), hasLength(1), reason: 'on disk while the upload is still going');
    expect((saved('s1').single! as Map<String, Object?>)['client_answer_id'], 'a1');
    expect(q.pending('s1').single.clientAnswerId, 'a1');
    server.hold!.complete();
    await q.flush();

    expect(server.uploads.single.$2.single.clientAnswerId, 'a1');
    expect(q.pending('s1'), isEmpty);
    expect(prefs.getString('practice.queue.u1.s1'), isNull, reason: 'nothing left to keep');
  });

  test('de-duplicates by client_answer_id and by position', () async {
    server.failWith = const NetworkFailure();
    final q = queue();

    expect(await q.add('s1', _answer(1)), isTrue);
    expect(await q.add('s1', _answer(1)), isFalse, reason: 'same answer again');
    expect(
      await q.add('s1', _answer(1, id: 'other')),
      isFalse,
      reason: 'first per position counts',
    );
    expect(await q.add('s2', _answer(1, id: 'other')), isTrue, reason: 'another session');

    expect(q.pending('s1'), hasLength(1));
    expect(q.pendingCount, 2);
    expect(saved('s1'), hasLength(1));
  });

  test('accepted, duplicate and rejected answers all leave the queue', () async {
    await prefs.setString(
      'practice.queue.u1.s1',
      jsonEncode([
        for (final p in [1, 2, 3]) _answer(p).toJson(),
      ]),
    );
    server.respond = (_, answers) => AnswersResponse(
      results: [
        AnswerResult(clientAnswerId: answers[0].clientAnswerId, status: AnswerStatus.accepted),
        AnswerResult(clientAnswerId: answers[1].clientAnswerId, status: AnswerStatus.duplicate),
        AnswerResult(
          clientAnswerId: answers[2].clientAnswerId,
          status: AnswerStatus.rejected,
          reason: 'session_expired',
        ),
      ],
    );
    final q = queue();
    await q.flush();

    expect(server.uploads.single.$2, hasLength(3));
    expect(q.pending('s1'), isEmpty);
    expect(q.refusals('s1'), ['session_expired'], reason: 'refusals are reported, not hidden');
    await q.clearRefusals('s1');
    expect(q.refusals('s1'), isEmpty);
  });

  test('an answer the server leaves unsettled stays for the next try', () async {
    server.respond = (_, answers) => const AnswersResponse(results: []);
    final q = queue();
    await q.add('s1', _answer(1));
    await q.flush();

    expect(q.pending('s1'), hasLength(1));
    expect(q.retryScheduled, isTrue);
  });

  for (final failure in const <AppFailure>[NetworkFailure(), TimeoutFailure(), ServerFailure()]) {
    test('${failure.runtimeType} keeps the answer and retries with backoff', () async {
      server.failWith = failure;
      final q = queue(retry: const Duration(milliseconds: 20));
      await q.add('s1', _answer(1));
      await q.flush();

      expect(q.pending('s1'), hasLength(1));
      expect(q.retryScheduled, isTrue);
      expect(saved('s1'), hasLength(1), reason: 'still on disk');

      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(backoffs.first, 1);
      expect(backoffs, contains(2), reason: 'each failed try waits longer');

      server.failWith = null;
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await q.flush();
      expect(q.pending('s1'), isEmpty);
    });
  }

  test('the default backoff doubles from 2 s up to a minute', () {
    Duration mid(int attempt) {
      final d = defaultAnswerBackoff(attempt);
      return Duration(seconds: (d.inMilliseconds / 1000).round());
    }

    expect(defaultAnswerBackoff(1).inMilliseconds, inInclusiveRange(1600, 2400));
    expect(defaultAnswerBackoff(3).inMilliseconds, inInclusiveRange(6400, 9600));
    expect(mid(20).inSeconds, inInclusiveRange(48, 72));
  });

  test('rate limiting waits at least Retry-After', () async {
    server.failWith = const RateLimitedFailure(retryAfter: Duration(milliseconds: 300));
    final q = queue(retry: const Duration(milliseconds: 1));
    await q.add('s1', _answer(1));
    await q.flush();
    final tries = server.uploads.length;

    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(server.uploads, hasLength(tries), reason: 'not before Retry-After');
  });

  test('a 401 keeps answers but doesn\'t retry on a timer (the next sign-in sends them)', () async {
    server.failWith = const UnauthorizedFailure();
    final q = queue();
    await q.add('s1', _answer(1));
    await q.flush();

    expect(q.pending('s1'), hasLength(1));
    expect(q.retryScheduled, isFalse);
  });

  test(
    'a request refused outright (404) is dropped, reported, and doesn\'t block others',
    () async {
      server.respond = (session, answers) => session == 'gone'
          ? throw const NotFoundFailure('Session not found.', code: 'NOT_FOUND')
          : _all(answers, AnswerStatus.accepted);
      server.failWith = const NetworkFailure();
      final q = queue();
      await q.add('gone', _answer(1, at: DateTime.utc(2026)));
      await q.add('s2', _answer(1, id: 'b1'));

      server.failWith = null;
      await q.flush();

      expect(q.pendingCount, 0);
      expect(q.refusals('gone'), ['not_found']);
      expect(q.refusals('s2'), isEmpty);
    },
  );

  test('uploads go in batches of at most 50', () async {
    final answers = [for (var p = 1; p <= 120; p++) _answer(p)];
    await prefs.setString(
      'practice.queue.u1.s1',
      jsonEncode([for (final a in answers) a.toJson()]),
    );
    final q = queue();
    await q.flush();

    expect(server.uploads.map((u) => u.$2.length), [50, 50, 20]);
    expect(server.uploads.expand((u) => u.$2).map((a) => a.position), [
      for (var p = 1; p <= 120; p++) p,
    ]);
  });

  test('answers survive a restart: a new queue on the same storage sends them', () async {
    server.failWith = const NetworkFailure();
    final before = queue();
    await before.add('s1', _answer(1));
    await before.add('s1', _answer(2));
    await before.flush();
    before.dispose();

    // A cold start: shared preferences are read back from the platform store.
    SharedPreferences.resetStatic();
    prefs = await SharedPreferences.getInstance();
    server.failWith = null;
    final after = queue();

    expect(after.pending('s1').map((a) => a.clientAnswerId), ['a1', 'a2']);
    await after.flush();
    expect(server.uploads.last.$2.map((a) => a.clientAnswerId), ['a1', 'a2']);
    expect(after.pendingCount, 0);
  });

  test('finish waits for the answers to be uploaded, then ends the session', () async {
    server.hold = Completer<void>();
    final q = queue();
    await q.add('s1', _answer(1));

    var finished = false;
    final summary = q.finish('s1').then((s) {
      finished = true;
      return s;
    });
    await pumpEventQueue();
    expect(finished, isFalse);
    expect(server.finishes, isEmpty, reason: 'answers first');

    server.hold!.complete();
    expect((await summary).sessionId, 's1');
    expect(server.events, ['upload s1', 'finish s1']);
    expect(q.summaryFor('s1'), isNotNull);
    expect(q.isFinishPending('s1'), isFalse);
  });

  test('a finish that can\'t happen offline is kept and completes in the background', () async {
    server.failWith = const NetworkFailure();
    final q = queue();
    await q.add('s1', _answer(1));
    await expectLater(q.finish('s1'), throwsA(isA<NetworkFailure>()));
    expect(q.isFinishPending('s1'), isTrue);

    // It is on disk too: a restart still finishes the session.
    final restarted = queue();
    expect(restarted.isFinishPending('s1'), isTrue);
    restarted.dispose();

    var notified = false;
    q.addListener(() => notified = true);
    server.failWith = null;
    q
      ..setOnline(online: false)
      ..setOnline(online: true);
    await q.flush();

    expect(server.events.last, 'finish s1');
    expect(q.summaryFor('s1'), isNotNull);
    expect(q.isFinishPending('s1'), isFalse);
    expect(notified, isTrue);
  });

  test('coming back online flushes straight away', () async {
    server.failWith = const NetworkFailure();
    final q = queue();
    await q.add('s1', _answer(1));
    await q.flush();
    final tries = server.uploads.length;

    server.failWith = null;
    q.setOnline(online: false);
    await pumpEventQueue();
    expect(server.uploads, hasLength(tries), reason: 'going offline sends nothing');

    q.setOnline(online: true);
    await pumpEventQueue();
    expect(server.uploads, hasLength(tries + 1));
    expect(q.pendingCount, 0);
  });

  test('answers older than 7 days are dropped when the queue loads', () async {
    final now = DateTime.now().toUtc();
    await prefs.setString(
      'practice.queue.u1.s1',
      jsonEncode([
        _answer(1, at: now.subtract(const Duration(days: 8))).toJson(),
        _answer(2, at: now.subtract(const Duration(days: 1))).toJson(),
      ]),
    );
    server.failWith = const NetworkFailure();
    final q = queue();

    expect(q.pending('s1').map((a) => a.position), [2]);
    await pumpEventQueue();
    expect(saved('s1'), hasLength(1));
  });

  test('each user has their own queue on the device', () async {
    server.failWith = const NetworkFailure();
    final a = queue(user: 'userA');
    await a.add('s1', _answer(1));

    final b = queue(user: 'userB');
    expect(b.pendingCount, 0);
    await b.flush();
    expect(server.uploads.where((u) => u.$1 == 's1'), hasLength(1), reason: 'only A\'s own try');
    expect(saved('s1', user: 'userA'), hasLength(1));
  });

  group('per signed-in user', () {
    const userA = Me(
      id: 'userA',
      displayName: 'Aarav',
      avatar: Avatar.fallback,
      onboardingCompleted: true,
    );
    const userB = Me(
      id: 'userB',
      displayName: 'Bhavya',
      avatar: Avatar.fallback,
      onboardingCompleted: true,
    );

    test('A\'s queued answers wait out B\'s session unsent, then go when A signs in', () async {
      final learn = FakeLearnRepository.seeded()
        ..failures[FakeLearnOp.uploadAnswers] = const NetworkFailure();
      final session = await learn.createSession(
        const SessionSettings(
          mode: PracticeMode.chapter,
          subject: 'physics',
          chapters: ['kinematics'],
        ),
        idempotencyKey: 'k',
      );
      final question = session.questions.first;
      final container = ProviderContainer(
        overrides: [
          appEnvProvider.overrideWithValue(testEnv),
          sessionProvider.overrideWith(() => _SwitchableSession(const SignedIn(userA))),
          sharedPrefsProvider.overrideWithValue(prefs),
          learnRepositoryProvider.overrideWithValue(learn),
          connectivityProvider.overrideWith((ref) => Stream.value(true)),
        ],
      );
      addTearDown(container.dispose);
      await container.read(sessionProvider.future);

      // A answers while offline.
      final queueA = container.read(answerQueueProvider);
      expect(queueA.userId, 'userA');
      await queueA.add(
        session.sessionId,
        AnswerUpload.create(
          ref: question.ref,
          position: question.position,
          selectedOption: question.answer,
          timeMs: 4000,
        ),
      );
      await queueA.flush();
      expect(queueA.pending(session.sessionId), hasLength(1));
      final triesByA = learn.uploadCalls.length;

      // B signs in on the same phone and the network is back.
      learn.failures.clear();
      (container.read(sessionProvider.notifier) as _SwitchableSession).become(
        const SignedIn(userB),
      );
      container.read(answerSyncProvider);
      final queueB = container.read(answerQueueProvider);
      await queueB.flush();

      expect(queueB.userId, 'userB');
      expect(queueB.pendingCount, 0);
      expect(learn.uploadCalls, hasLength(triesByA), reason: 'never sent with B\'s token');
      expect(queueA.retryScheduled, isFalse, reason: 'A\'s queue went dormant');
      expect(saved(session.sessionId, user: 'userA'), hasLength(1));

      // A signs back in: the answer goes out.
      (container.read(sessionProvider.notifier) as _SwitchableSession).become(
        const SignedIn(userA),
      );
      container.read(answerSyncProvider);
      final queueA2 = container.read(answerQueueProvider);
      await queueA2.flush();

      expect(learn.uploadCalls, hasLength(triesByA + 1));
      expect(learn.uploadedAnswers.last.ref, question.ref);
      expect(queueA2.pendingCount, 0);
    });
  });
}

class _SwitchableSession extends SessionController {
  _SwitchableSession(this._initial);

  final Session _initial;

  @override
  Future<Session> build() async => _initial;

  void become(Session session) => state = AsyncData(session);
}
