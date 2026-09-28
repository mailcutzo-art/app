import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_app/core/auth/user.dart';
import 'package:quiz_app/core/network/api_client.dart';
import 'package:quiz_app/core/network/app_failure.dart';
import 'package:quiz_app/features/leaderboards/data/leaderboard_repository.dart';

import '../../support/fakes.dart';
import '../../support/leaderboard_samples.dart';

void main() {
  (ApiLeaderboardRepository, FakeAdapter) build(
    FutureOr<ResponseBody> Function(RequestOptions options) handler,
  ) {
    final adapter = FakeAdapter(handler);
    final dio = Dio(BaseOptions(baseUrl: 'http://api.test', contentType: Headers.jsonContentType))
      ..httpClientAdapter = adapter;
    return (ApiLeaderboardRepository(ApiClient(dio)), adapter);
  }

  test('the hub GETs /v1/leaderboards with the exam, or without for All India', () async {
    final (repo, adapter) = build(
      (_) => jsonBody({
        'boards': [
          {'board': 'weekly_xp', 'title': 'This week', 'leader': rowJson(1), 'me': null},
        ],
        'last_week': <Object>[],
      }),
    );

    final hub = await repo.hub(goal: Goal.jee);
    expect(adapter.requests.single.path, '/v1/leaderboards');
    expect(adapter.requests.single.queryParameters, {'goal': 'jee'});
    expect(hub.boards.single.title, 'This week');

    await repo.hub();
    expect(adapter.requests.last.queryParameters, isEmpty);
  });

  test('a board is fetched by its encoded id, with the cursor', () async {
    final (repo, adapter) = build(
      (_) => jsonBody({
        'board': 'rating:physics',
        'title': 'Physics',
        'items': [rowJson(51)],
        'next_cursor': null,
        'me': null,
        'around_me': <Object>[],
        'not_ranked': {'games_to_rank': 7},
      }),
    );

    final page = await repo.board('rating:physics', goal: Goal.neet, cursor: 'c50');
    final request = adapter.requests.single;
    expect(request.uri.path, '/v1/leaderboards/rating%3Aphysics');
    expect(request.queryParameters, {'goal': 'neet', 'cursor': 'c50'});
    expect(page.items.single.position, 51);
    expect(page.gamesToRank, 7);
  });

  test('a payload the app can\'t read is a generic failure', () async {
    final (repo, _) = build((_) => jsonBody({'boards': 'nope'}));
    await expectLater(repo.hub(), throwsA(isA<UnexpectedFailure>()));
  });
}
