import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_app/core/auth/user.dart';
import 'package:quiz_app/core/network/api_client.dart';
import 'package:quiz_app/core/network/app_failure.dart';
import 'package:quiz_app/features/learn/data/learn_models.dart';
import 'package:quiz_app/features/learn/data/learn_repository.dart';
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
  });
}
