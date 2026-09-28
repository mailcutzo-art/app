import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_app/core/auth/user.dart';
import 'package:quiz_app/core/network/api_client.dart';
import 'package:quiz_app/core/network/app_failure.dart';
import 'package:quiz_app/features/learn/data/learn_models.dart';
import 'package:quiz_app/features/learn/data/learn_repository.dart';
import 'package:quiz_app/features/learn/data/question_models.dart';
import 'package:quiz_app/features/practice/data/practice_models.dart';
import 'package:quiz_app/features/practice/start_practice.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/fakes.dart';
import '../../support/learn_samples.dart';

Map<String, Object?> _error(String code, String message) => {
  'error': {'code': code, 'message': message, 'details': null, 'request_id': 'r1'},
};

DioException _offline(RequestOptions options) =>
    DioException(requestOptions: options, type: DioExceptionType.connectionError);

void main() {
  late SharedPreferences prefs;

  setUp(() async => prefs = await testPrefs());

  (ApiLearnRepository, FakeAdapter) build(
    FutureOr<ResponseBody> Function(RequestOptions options) handler,
  ) {
    final adapter = FakeAdapter(handler);
    final dio = Dio(BaseOptions(baseUrl: 'http://api.test', contentType: Headers.jsonContentType))
      ..httpClientAdapter = adapter;
    return (ApiLearnRepository(ApiClient(dio), cache: prefs), adapter);
  }

  group('catalog', () {
    test('GETs the exam\'s catalog and keeps a copy on the device', () async {
      final (repo, adapter) = build((_) => jsonBody(catalogJson()));

      final catalog = await repo.catalog(Goal.jee);

      final request = adapter.requests.single;
      expect(request.method, 'GET');
      expect(request.path, '/v1/catalog');
      expect(request.queryParameters, {'goal': 'jee'});
      expect(catalog.subjects.single.name, 'Physics');
      expect(catalog.fromCache, isFalse);
      expect(prefs.getString(ApiLearnRepository.catalogCacheKey(Goal.jee)), isNotNull);
    });

    test('offline, the saved copy is served and marked as such', () async {
      var online = true;
      final (repo, _) = build(
        (options) => online ? jsonBody(catalogJson()) : throw _offline(options),
      );
      await repo.catalog(Goal.neet);

      online = false;
      final saved = await repo.catalog(Goal.neet);
      expect(saved.fromCache, isTrue);
      expect(saved.subjects.single.slug, 'physics');
      await expectLater(repo.catalog(Goal.jee), throwsA(isA<NetworkFailure>()));
    });

    test('errors that a saved copy can\'t fix are not hidden', () async {
      await prefs.setString(ApiLearnRepository.catalogCacheKey(Goal.neet), '{"goal": "neet"}');
      final (repo, _) = build((_) => jsonBody(_error('FORBIDDEN', 'Banned'), status: 403));
      await expectLater(repo.catalog(Goal.neet), throwsA(isA<ForbiddenFailure>()));
    });
  });

  test('progress GETs /v1/me/progress for the exam', () async {
    final (repo, adapter) = build((_) => jsonBody(progressJson()));
    final progress = await repo.progress(Goal.neet);
    expect(adapter.requests.single.path, '/v1/me/progress');
    expect(adapter.requests.single.queryParameters, {'goal': 'neet'});
    expect(progress.reviewsDue, 3);
  });

  group('practice sessions', () {
    const settings = SessionSettings(
      mode: PracticeMode.topic,
      subject: 'physics',
      topic: 'equations-of-motion',
      count: 20,
      difficulty: Difficulty.medium,
      timed: true,
      perQuestionS: 30,
    );

    test('creating POSTs the settings with an Idempotency-Key', () async {
      final (repo, adapter) = build((_) => jsonBody(sessionJson(), status: 201));

      final session = await repo.createSession(settings, idempotencyKey: 'key-1');

      final request = adapter.requests.single;
      expect(request.method, 'POST');
      expect(request.path, '/v1/practice/sessions');
      expect(request.headers['Idempotency-Key'], 'key-1');
      expect(request.data, {
        'mode': 'topic',
        'subject': 'physics',
        'chapters': <String>[],
        'topic': 'equations-of-motion',
        'category': null,
        'count': 20,
        'difficulty': 'medium',
        'timed': true,
        'per_question_s': 30,
        'time_limit_s': null,
        'marking': 'none',
        'unseen_only': false,
      });
      expect(session.sessionId, 's-1');
    });

    test('409 NO_QUESTIONS becomes a conflict the sheet can explain', () async {
      final (repo, _) = build(
        (_) => jsonBody(_error('NO_QUESTIONS', 'No questions match.'), status: 409),
      );
      final failure = await repo
          .createSession(settings, idempotencyKey: 'k')
          .then<AppFailure?>((_) => null, onError: (Object e) => e as AppFailure);
      expect(failure, isA<ConflictFailure>().having((f) => f.code, 'code', 'NO_QUESTIONS'));
      expect(practiceStartError(failure!), 'No questions match these settings yet.');
    });

    test('too many sessions an hour is a rate limit with Retry-After', () async {
      final (repo, _) = build(
        (_) => jsonBody(
          _error('RATE_LIMITED', 'Slow down.'),
          status: 429,
          headers: {
            'retry-after': ['60'],
          },
        ),
      );
      await expectLater(
        repo.createSession(settings, idempotencyKey: 'k'),
        throwsA(
          isA<RateLimitedFailure>().having(
            (f) => f.retryAfter,
            'retryAfter',
            const Duration(minutes: 1),
          ),
        ),
      );
    });

    test('resuming GETs the session; an unknown one is not found', () async {
      final (repo, adapter) = build(
        (options) => options.path.endsWith('/gone')
            ? jsonBody(_error('NOT_FOUND', 'Session not found.'), status: 404)
            : jsonBody(sessionJson()..['finished'] = false),
      );
      final session = await repo.session('s-1');
      expect(adapter.requests.single.path, '/v1/practice/sessions/s-1');
      expect(session.finished, isFalse);
      await expectLater(repo.session('gone'), throwsA(isA<NotFoundFailure>()));
    });

    test('answers are POSTed as a batch and the results parsed', () async {
      final (repo, adapter) = build(
        (_) => jsonBody({
          'results': [
            {'client_answer_id': 'a1', 'status': 'accepted', 'outcome': 'correct'},
          ],
          'xp': {'delta': 2, 'total': 1234, 'level': 4, 'into_level': 34, 'for_next': 250},
        }),
      );
      final answer = AnswerUpload(
        clientAnswerId: 'a1',
        ref: 'q_01929f',
        position: 1,
        selectedOption: 1,
        timeMs: 5320,
        answeredAt: DateTime.utc(2026, 9, 27, 15, 0, 7),
      );

      final response = await repo.uploadAnswers('s-1', [answer]);

      final request = adapter.requests.single;
      expect(request.method, 'POST');
      expect(request.path, '/v1/practice/sessions/s-1/answers');
      expect(request.data, {
        'answers': [answer.toJson()],
      });
      expect(response.results.single.status, AnswerStatus.accepted);
      expect(response.xp?.total, 1234);
    });

    test('finishing POSTs with no body and parses the summary', () async {
      final (repo, adapter) = build(
        (_) => jsonBody({'session_id': 's-1', 'answered': 18, 'correct': 12, 'skipped': 2}),
      );
      final summary = await repo.finishSession('s-1');
      expect(adapter.requests.single.method, 'POST');
      expect(adapter.requests.single.path, '/v1/practice/sessions/s-1/finish');
      expect(adapter.requests.single.data, isNull);
      expect(summary.correct, 12);
    });

    test('a response the app can\'t read is a generic failure, not a crash', () async {
      final (repo, _) = build((_) => jsonBody({'session_id': 's-1'}));
      await expectLater(repo.finishSession('s-1'), throwsA(isA<UnexpectedFailure>()));
    });

    test('server trouble keeps its retryable failure', () async {
      final (repo, _) = build((_) => jsonBody(null, status: 502));
      await expectLater(
        repo.uploadAnswers('s-1', const []),
        throwsA(isA<ServerFailure>().having((f) => f.isRetryable, 'retryable', isTrue)),
      );
    });
  });

  group('tips, bookmarks and reviews', () {
    test('tips and dismissing one (keys are encoded)', () async {
      final (repo, adapter) = build(
        (options) => options.method == 'GET'
            ? jsonBody({'unlocked': false, 'answers_needed': 12, 'tips': <Object?>[]})
            : ResponseBody.fromString('', 204),
      );
      final tips = await repo.tips();
      await repo.dismissTip('weak_topic:physics:friction');

      expect(tips.answersNeeded, 12);
      expect(adapter.requests.map((r) => '${r.method} ${r.path}'), [
        'GET /v1/me/tips',
        'POST /v1/me/tips/weak_topic%3Aphysics%3Afriction/dismiss',
      ]);
    });

    test('bookmarks PUT to add and DELETE to remove', () async {
      final (repo, adapter) = build((_) => ResponseBody.fromString('', 204));
      await repo.setBookmark('q_1', bookmarked: true);
      await repo.setBookmark('q_1', bookmarked: false);
      expect(adapter.requests.map((r) => '${r.method} ${r.path}'), [
        'PUT /v1/me/bookmarks/q_1',
        'DELETE /v1/me/bookmarks/q_1',
      ]);
    });

    test('the bookmark limit is a conflict with its own code', () async {
      final (repo, _) = build(
        (_) => jsonBody(_error('BOOKMARK_LIMIT', 'Too many bookmarks.'), status: 409),
      );
      await expectLater(
        repo.setBookmark('q_1', bookmarked: true),
        throwsA(isA<ConflictFailure>().having((f) => f.code, 'code', 'BOOKMARK_LIMIT')),
      );
    });

    test('reviews summary', () async {
      final (repo, adapter) = build((_) => jsonBody({'due': 5, 'total': 23}));
      expect(await repo.reviewsSummary(), const ReviewsSummary(due: 5, total: 23));
      expect(adapter.requests.single.path, '/v1/me/reviews/summary');
    });

    test('the bookmarks list GETs a page by subject and cursor', () async {
      final (repo, adapter) = build((_) => jsonBody(bookmarksJson()));

      final page = await repo.listBookmarks(subject: 'physics', cursor: 'c1');

      final request = adapter.requests.single;
      expect('${request.method} ${request.path}', 'GET /v1/me/bookmarks');
      expect(request.queryParameters, {'subject': 'physics', 'cursor': 'c1', 'limit': 20});
      expect(page.nextCursor, 'c2');
      expect(page.items.map((b) => b.ref), ['q_01929f', 'q_2']);
      final first = page.items.first;
      expect(first.question.subject, 'physics');
      expect(first.question.chapter?.name, 'Motion in a Straight Line');
      expect(first.question.topic?.slug, 'equations-of-motion');
      expect(first.bookmarkedAt, DateTime.utc(2026, 9, 27, 15));
      expect(page.items.last.question.topic, isNull);
    });

    test('the first page leaves out the cursor; the last page has none', () async {
      final (repo, adapter) = build((_) => jsonBody(bookmarksJson(nextCursor: null)));
      final page = await repo.listBookmarks();
      expect(adapter.requests.single.queryParameters, {'limit': 20});
      expect(page.nextCursor, isNull);
    });
  });

  group('search, questions, reports and passages', () {
    test('search GETs /v1/search with the query and subject', () async {
      final (repo, adapter) = build(
        (_) => jsonBody({
          'items': [questionSummaryJson()],
        }),
      );

      final results = await repo.search('kine', subject: 'physics');

      final request = adapter.requests.single;
      expect(request.path, '/v1/search');
      expect(request.queryParameters, {'q': 'kine', 'subject': 'physics', 'limit': 20});
      expect(results.single.ref, 'q_01929f');
      expect(results.single.stem, startsWith('A car starts'));
    });

    test('a cancelled search fails with CancelledFailure', () async {
      final hold = Completer<ResponseBody>();
      final (repo, _) = build((_) => hold.future);
      final token = CancelToken();

      final search = repo.search('kine', cancelToken: token);
      token.cancel();

      await expectLater(search, throwsA(isA<CancelledFailure>()));
      hold.complete(jsonBody({'items': <Object?>[]}));
    });

    test('too many searches is a rate limit', () async {
      final (repo, _) = build((_) => jsonBody(_error('RATE_LIMITED', 'Slow down.'), status: 429));
      await expectLater(repo.search('kine'), throwsA(isA<RateLimitedFailure>()));
    });

    test('a question comes with its answer, explanation and bookmark', () async {
      final (repo, adapter) = build((_) => jsonBody(questionDetailJson()));

      final question = await repo.question('q_01929f');

      expect(adapter.requests.single.path, '/v1/questions/q_01929f');
      expect(question.options.map((o) => o.id), [0, 1, 2, 3]);
      expect(question.answer, 1);
      expect(question.explanation, contains('25 m'));
      expect(question.bookmarked, isTrue);
      expect(question.difficulty, 2);
      expect(question.topic?.name, 'Equations of motion');
    });

    test('a retired question is not found; a bad answer key is unreadable', () async {
      final (repo, _) = build(
        (options) => options.path.endsWith('gone')
            ? jsonBody(_error('QUESTION_NOT_FOUND', 'Gone.'), status: 404)
            : jsonBody({...questionDetailJson(), 'answer': 7}),
      );
      await expectLater(
        repo.question('gone'),
        throwsA(isA<NotFoundFailure>().having((f) => f.code, 'code', 'QUESTION_NOT_FOUND')),
      );
      await expectLater(repo.question('q_1'), throwsA(isA<UnexpectedFailure>()));
    });

    test('reporting POSTs the reason and a trimmed note (left out when empty)', () async {
      final (repo, adapter) = build((_) => ResponseBody.fromString('', 202));

      await repo.reportQuestion('q/1', ReportReason.wrongAnswer, note: '  Should be B  ');
      await repo.reportQuestion('q/1', ReportReason.typo, note: '   ');

      expect(adapter.requests.map((r) => '${r.method} ${r.path}'), [
        'POST /v1/questions/q%2F1/reports',
        'POST /v1/questions/q%2F1/reports',
      ]);
      expect(adapter.requests.first.data, {'reason': 'wrong_answer', 'note': 'Should be B'});
      expect(adapter.requests.last.data, {'reason': 'typo'});
    });

    test('the daily report limit is a rate limit', () async {
      final (repo, _) = build(
        (_) => jsonBody(_error('RATE_LIMITED', 'Most reports sent.'), status: 429),
      );
      await expectLater(
        repo.reportQuestion('q_1', ReportReason.other),
        throwsA(isA<RateLimitedFailure>()),
      );
    });

    test('passages GET by subject', () async {
      final (repo, adapter) = build((_) => jsonBody(passagesJson()));

      final all = await repo.passages();
      await repo.passages(subject: 'physics');

      expect(adapter.requests.first.queryParameters, isEmpty);
      expect(adapter.requests.last.queryParameters, {'subject': 'physics'});
      expect(all.map((p) => p.title), [
        'Galileo and the falling balls',
        'The cell\'s power stations',
      ]);
      expect(all.first.questionCount, 3);
      expect(all.first.chapter?.slug, 'kinematics');
      expect(all.first.done, isFalse);
      expect(all.last.chapter, isNull);
      expect(all.last.done, isTrue);
    });

    test('a passage session carries the passage', () async {
      final (repo, adapter) = build(
        (_) => jsonBody({
          ...sessionJson(),
          'mode': 'passage',
          'passage': {
            'id': 'p-1',
            'title': 'Galileo and the falling balls',
            'body': 'For nearly two thousand years…',
          },
        }, status: 201),
      );

      final session = await repo.createSession(
        const SessionSettings(mode: PracticeMode.passage, passageId: 'p-1'),
        idempotencyKey: 'k',
      );

      expect((adapter.requests.single.data as Map)['passage_id'], 'p-1');
      expect(session.mode, PracticeMode.passage);
      expect(session.passage?.title, 'Galileo and the falling balls');
    });

    test('a challenge session sends its time limit and marking', () async {
      final (repo, adapter) = build(
        (_) => jsonBody({
          ...sessionJson(),
          'mode': 'challenge',
          'feedback': 'end',
          'time_limit_ms': 600000,
          'marking': 'neet',
        }, status: 201),
      );

      final session = await repo.createSession(
        const SessionSettings(
          mode: PracticeMode.challenge,
          subject: 'physics',
          chapters: ['kinematics', 'laws-of-motion'],
          count: 20,
          timeLimitS: 600,
          marking: Marking.neet,
          unseenOnly: true,
        ),
        idempotencyKey: 'k',
      );

      expect(adapter.requests.single.data, {
        'mode': 'challenge',
        'subject': 'physics',
        'chapters': ['kinematics', 'laws-of-motion'],
        'topic': null,
        'category': null,
        'count': 20,
        'difficulty': 'mixed',
        'timed': false,
        'per_question_s': null,
        'time_limit_s': 600,
        'marking': 'neet',
        'unseen_only': true,
      });
      expect(session.instantFeedback, isFalse);
      expect(session.timeLimitMs, 600000);
      expect(session.marking, Marking.neet);
    });
  });
}
