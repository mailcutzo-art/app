import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_app/core/network/api_client.dart';
import 'package:quiz_app/core/network/app_failure.dart';
import 'package:quiz_app/features/share/share_models.dart';
import 'package:quiz_app/features/social/data/social_models.dart';
import 'package:quiz_app/features/social/data/social_repository.dart';
import 'package:quiz_app/features/social/widgets/social_widgets.dart';

import '../../support/fakes.dart';

Map<String, Object?> _card(String id) => {
  'id': id,
  'handle': 'h_$id',
  'display_name': 'N $id',
  'avatar': {'tone': 'mint', 'symbol': 'dna'},
  'level': 3,
};

Map<String, Object?> _error(String code, {Map<String, Object?>? details}) => {
  'error': {'code': code, 'message': 'Nope', 'details': details, 'request_id': 'r1'},
};

void main() {
  (ApiSocialRepository, FakeAdapter) build(
    FutureOr<ResponseBody> Function(RequestOptions options) handler,
  ) {
    final adapter = FakeAdapter(handler);
    final dio = Dio(BaseOptions(baseUrl: 'http://api.test', contentType: Headers.jsonContentType))
      ..httpClientAdapter = adapter;
    return (ApiSocialRepository(ApiClient(dio)), adapter);
  }

  Object? body(RequestOptions options) =>
      options.data is String ? jsonDecode(options.data as String) : options.data;

  test('friends GETs a page with the cursor', () async {
    final (repo, adapter) = build(
      (_) => jsonBody({
        'items': [
          {..._card('u1'), 'presence': 'online'},
        ],
        'next_cursor': 'c2',
      }),
    );
    final page = await repo.friends(cursor: 'c1');
    expect(adapter.requests.single.path, '/v1/me/friends');
    expect(adapter.requests.single.queryParameters, {'cursor': 'c1'});
    expect(page.items.single.presence, FriendPresence.online);
    expect(page.nextCursor, 'c2');

    await repo.friends();
    expect(adapter.requests.last.queryParameters, isEmpty);
  });

  test('search sends the query and can be cancelled', () async {
    final (repo, adapter) = build(
      (_) => jsonBody({
        'items': [
          {..._card('u1'), 'relationship': 'requested'},
        ],
      }),
    );
    final results = await repo.search('rah');
    expect(adapter.requests.single.path, '/v1/users/search');
    expect(adapter.requests.single.queryParameters, {'q': 'rah'});
    expect(results.single.relationship, Relationship.requested);

    final token = CancelToken()..cancel();
    await expectLater(repo.search('rahu', cancelToken: token), throwsA(isA<CancelledFailure>()));
  });

  test('a friend request POSTs the user id; NOT_ALLOWED keeps its reason', () async {
    var allowed = true;
    final (repo, adapter) = build(
      (_) => allowed
          ? jsonBody({'id': 'fr1'}, status: 201)
          : jsonBody(_error('NOT_ALLOWED', details: {'reason': 'played_with'}), status: 403),
    );
    final sent = await repo.sendRequest('u1');
    final request = adapter.requests.single;
    expect(request.method, 'POST');
    expect(request.path, '/v1/friend-requests');
    expect(body(request), {'user_id': 'u1'});
    expect(sent.requestId, 'fr1');

    allowed = false;
    try {
      await repo.sendRequest('u2');
      fail('expected a failure');
    } on ForbiddenFailure catch (failure) {
      expect(failure.code, 'NOT_ALLOWED');
      final user = UserCard.fromJson(_card('u2'));
      expect(friendRequestError(failure, user), contains('only accepts requests from people'));
    }
  });

  test('LIMIT_REACHED is explained with the limits', () async {
    final (repo, _) = build((_) => jsonBody(_error('LIMIT_REACHED'), status: 409));
    try {
      await repo.sendRequest('u1');
      fail('expected a failure');
    } on ConflictFailure catch (failure) {
      expect(
        friendRequestError(failure, UserCard.fromJson(_card('u1'))),
        contains('20 a day and have 100 waiting'),
      );
    }
  });

  test('request actions use the request id', () async {
    final (repo, adapter) = build((options) {
      if (options.path == '/v1/me/friend-requests') {
        return jsonBody({
          'incoming': [
            {'id': 'fr/1', 'user': _card('u1')},
          ],
          'outgoing': <Object?>[],
        });
      }
      return ResponseBody.fromString('', 204);
    });
    final requests = await repo.requests();
    expect(requests.incoming.single.id, 'fr/1');
    await repo.acceptRequest('fr/1');
    await repo.declineRequest('fr2');
    await repo.cancelRequest('fr3');
    await repo.removeFriend('u9');
    expect(
      [for (final r in adapter.requests.skip(1)) '${r.method} ${r.uri.path}'],
      [
        'POST /v1/friend-requests/fr%2F1/accept',
        'POST /v1/friend-requests/fr2/decline',
        'DELETE /v1/friend-requests/fr3',
        'DELETE /v1/me/friends/u9',
      ],
    );
  });

  test('rivals, opponents and activity', () async {
    final (repo, adapter) = build((options) {
      final entry = {
        'user': _card('u1'),
        'h2h': {'wins': 3, 'losses': 0, 'draws': 0},
        'relationship': 'none',
      };
      return switch (options.path) {
        '/v1/me/rivals' || '/v1/me/opponents' => jsonBody({
          'items': [entry],
        }),
        _ => jsonBody({
          'items': [
            {
              'id': 'a1',
              'user': _card('u1'),
              'kind': 'level_up',
              'data': {'level': 5},
              'created_at': '2026-09-27T10:00:00Z',
            },
          ],
          'next_cursor': null,
        }),
      };
    });
    expect((await repo.rivals()).single.h2h.wins, 3);
    expect((await repo.opponents()).single.user.id, 'u1');
    expect(adapter.requests[1].queryParameters, {'days': 30});
    final activity = await repo.activity(cursor: 'c9');
    expect(activity.items.single.text, 'reached level 5');
    expect(adapter.requests[2].path, '/v1/me/activity');
    expect(adapter.requests[2].queryParameters, {'cursor': 'c9'});
  });

  test('a share POSTs only what to share, with an idempotency key', () async {
    final (repo, adapter) = build(
      (_) => jsonBody({
        'id': 'a1',
        'user': _card('u1'),
        'kind': 'shared_progress',
        'payload': {
          'level': 5,
          'xp': 700,
          'xp_into_level': 0,
          'xp_for_level': 350,
          'streak': {'current': 2, 'best': 3},
          'answered': 40,
          'correct': 30,
          'accuracy': 75,
          'ratings': <Object?>[],
        },
        'created_at': '2026-09-28T10:00:00Z',
      }, status: 201),
    );

    final item = await repo.share(const ProgressShareTarget(), idempotencyKey: 'k1');
    await repo.share(const MatchShareTarget('m-7'), idempotencyKey: 'k2');

    final [progress, match] = adapter.requests;
    expect(progress.method, 'POST');
    expect(progress.path, '/v1/me/activity/shares');
    expect(body(progress), {'kind': 'progress'});
    expect(progress.headers['Idempotency-Key'], 'k1');
    expect(body(match), {'kind': 'match_result', 'match_id': 'm-7'});
    expect(match.headers['Idempotency-Key'], 'k2');
    expect(item.kind, ActivityKind.sharedProgress);
    expect((item.share! as ProgressShareData).accuracyLabel, '75%');
  });

  test('a share over the daily limit or of a battle posted before is a conflict', () async {
    for (final code in ['LIMIT_REACHED', 'ALREADY_SHARED']) {
      final (repo, _) = build((_) => jsonBody(_error(code), status: 409));
      await expectLater(
        repo.share(const ProgressShareTarget(), idempotencyKey: 'k'),
        throwsA(isA<ConflictFailure>().having((f) => f.code, 'code', code)),
      );
    }
    final (repo, _) = build((_) => jsonBody(_error('NOT_FOUND'), status: 404));
    await expectLater(
      repo.share(const MatchShareTarget('m-x'), idempotencyKey: 'k'),
      throwsA(isA<NotFoundFailure>()),
    );
  });

  test('block, unblock, blocks and reports', () async {
    final (repo, adapter) = build((options) {
      if (options.path == '/v1/me/blocks') {
        return jsonBody({
          'items': [
            {'user': _card('u1'), 'created_at': '2026-09-27T10:00:00Z'},
            _card('u2'),
          ],
        });
      }
      return ResponseBody.fromString('', options.path == '/v1/reports' ? 202 : 204);
    });
    await repo.block('u1');
    expect(body(adapter.requests.last), {'user_id': 'u1'});
    await repo.unblock('u1');
    expect(adapter.requests.last.method, 'DELETE');
    expect(adapter.requests.last.path, '/v1/blocks/u1');
    expect((await repo.blocks()).map((u) => u.id), ['u1', 'u2']);

    await repo.report(userId: 'u1', reason: ReportReason.offensiveName, note: '  rude  ');
    expect(body(adapter.requests.last), {
      'user_id': 'u1',
      'reason': 'offensive_name',
      'note': 'rude',
    });
    await repo.report(userId: 'u1', reason: ReportReason.cheating, matchId: 'm1', note: ' ');
    expect(body(adapter.requests.last), {'user_id': 'u1', 'reason': 'cheating', 'match_id': 'm1'});
  });

  test('a profile GETs by handle; an unknown or blocked one is not found', () async {
    var found = true;
    final (repo, adapter) = build(
      (_) => found
          ? jsonBody({..._card('u1'), 'relationship': 'none', 'can_challenge': false})
          : jsonBody(_error('NOT_FOUND'), status: 404),
    );
    final profile = await repo.profile('rahul_07');
    expect(adapter.requests.single.path, '/v1/users/rahul_07');
    expect(profile.isLimited, isTrue);

    found = false;
    await expectLater(repo.profile('gone'), throwsA(isA<NotFoundFailure>()));
  });

  test('an unreadable payload is a generic failure', () async {
    final (repo, _) = build((_) => jsonBody({'nope': true}));
    await expectLater(repo.friends(), throwsA(isA<UnexpectedFailure>()));
  });
}
