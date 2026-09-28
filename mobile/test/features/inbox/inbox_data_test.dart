import 'package:design_system/design_system.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_app/core/network/api_client.dart';
import 'package:quiz_app/core/network/app_failure.dart';
import 'package:quiz_app/features/inbox/data/inbox_models.dart';
import 'package:quiz_app/features/inbox/data/inbox_repository.dart';
import 'package:realtime_client/realtime_client.dart';

import '../../support/fakes.dart';

Map<String, Object?> _item({
  String id = 'n1',
  String kind = 'refund',
  Object? action = const {'route': '/wallet'},
  bool read = false,
}) => {
  'id': id,
  'kind': kind,
  'title': 'Refund: match cancelled',
  'body': '5 coins are back.',
  'icon': 'coins',
  'action': action,
  'created_at': '2026-09-27T16:00:00Z',
  'read': read,
};

void main() {
  group('InboxItem', () {
    test('reads every field', () {
      final item = InboxItem.fromJson(_item());
      expect(item.id, 'n1');
      expect(item.kind, 'refund');
      expect(item.title, 'Refund: match cancelled');
      expect(item.body, '5 coins are back.');
      expect(item.action, const AppAction(route: '/wallet'));
      expect(item.createdAt, DateTime.utc(2026, 9, 27, 16));
      expect(item.read, isFalse);
      expect(item.look, (AppIcons.coins, PastelTone.lemon));
    });

    test('an unreadable action is dropped but the item stays', () {
      expect(InboxItem.fromJson(_item(action: {'route': 'not-a-path'})).action, isNull);
      expect(InboxItem.fromJson(_item(action: 'nope')).action, isNull);
      expect(InboxItem.fromJson(_item(action: null)).action, isNull);
    });

    test('a missing title or time is a format error', () {
      expect(() => InboxItem.fromJson({..._item(), 'title': null}), throwsFormatException);
      expect(() => InboxItem.fromJson({..._item(), 'created_at': 'soon'}), throwsFormatException);
    });

    test('a live notify becomes an unread item', () {
      final event = ServerEvent.fromEnvelope(
        const Envelope(
          type: 'notify',
          channel: 'u',
          data: {
            'id': 'n9',
            'kind': 'tournament_round',
            'title': 'Round 3 is ready',
            'action': {
              'route': '/arena/T1',
              'params': {'round': 3},
            },
            'unread': 4,
          },
        ),
      ) as NotifyEvent;
      final at = DateTime.utc(2026, 9, 28);
      final item = InboxItem.fromNotify(event, receivedAt: at);
      expect(item.id, 'n9');
      expect(item.read, isFalse);
      expect(item.createdAt, at);
      expect(item.action!.location, '/arena/T1?round=3');
      expect(item.look.$1, AppIcons.arena);
    });
  });

  group('AppAction', () {
    test('params become the query; tab pages are switched to, others pushed', () {
      const battle = AppAction(route: '/battle', params: {'subject': 'physics'});
      expect(battle.location, '/battle?subject=physics');
      expect(battle.opensTab, isTrue);

      const review = AppAction(route: '/battle/match/m1/review');
      expect(review.location, '/battle/match/m1/review');
      expect(review.opensTab, isFalse);
    });

    test('numbers and booleans in params read as strings', () {
      final action = AppAction.fromJson(const {
        'route': '/arena',
        'params': {'t': 'T1', 'round': 2, 'live': true},
      });
      expect(action.params, {'t': 'T1', 'round': '2', 'live': 'true'});
    });
  });

  group('ApiInboxRepository', () {
    late FakeAdapter adapter;
    late ApiInboxRepository repo;

    setUp(() {
      adapter = FakeAdapter(
        (options) => switch (options.path) {
          '/v1/me/notifications' => jsonBody({
            'items': [
              _item(),
              {..._item(id: 'n2', kind: 'mystery', read: true), 'icon': null},
            ],
            'next_cursor': 'c2',
          }),
          '/v1/me/notifications/unread-count' => jsonBody({'count': 3}),
          '/v1/me/notifications/read' => ResponseBody.fromString('', 204),
          _ => jsonBody(null, status: 404),
        },
      );
      repo = ApiInboxRepository(
        ApiClient(Dio(BaseOptions(baseUrl: 'http://api.test'))..httpClientAdapter = adapter),
      );
    });

    test('lists a page, passing the cursor only when there is one', () async {
      final first = await repo.notifications();
      expect(first.items.map((i) => i.id), ['n1', 'n2']);
      expect(first.nextCursor, 'c2');
      expect(first.items.last.look.$1, AppIcons.notification, reason: 'unknown kinds get a bell');
      expect(adapter.requests.last.queryParameters, isEmpty);

      await repo.notifications(cursor: 'c2');
      expect(adapter.requests.last.queryParameters, {'cursor': 'c2'});
    });

    test('reads the unread count', () async {
      expect(await repo.unreadCount(), 3);
      expect(adapter.requests.single.method, 'GET');
    });

    test('marks items read by id, or all at once', () async {
      await repo.markRead(['n1', 'n2']);
      await repo.markAllRead();
      expect(adapter.requests.map((r) => '${r.method} ${r.path}'), [
        'POST /v1/me/notifications/read',
        'POST /v1/me/notifications/read',
      ]);
      expect(adapter.requests.map((r) => r.data), [
        {
          'ids': ['n1', 'n2'],
        },
        {'all': true},
      ]);
    });

    test('an unreadable count is a generic failure', () async {
      adapter = FakeAdapter((_) => jsonBody({'count': 'many'}));
      repo = ApiInboxRepository(
        ApiClient(Dio(BaseOptions(baseUrl: 'http://api.test'))..httpClientAdapter = adapter),
      );
      await expectLater(repo.unreadCount(), throwsA(isA<UnexpectedFailure>()));
    });
  });
}
