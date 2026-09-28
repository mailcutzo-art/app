import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_app/core/network/api_client.dart';
import 'package:quiz_app/core/network/app_failure.dart';
import 'package:quiz_app/features/missions/data/fake_missions_repository.dart';
import 'package:quiz_app/features/missions/data/missions_models.dart';
import 'package:quiz_app/features/missions/data/missions_repository.dart';

import '../../support/fakes.dart';

Map<String, Object?> missionsJson({int swapsLeft = 1}) => {
  'day': '2026-09-27',
  'items': [
    {
      'id': 'm1',
      'title': 'Answer 20 practice questions',
      'progress': 12,
      'target': 20,
      'xp': 20,
      'done': false,
      'action': {'route': '/learn'},
    },
    {
      'id': 'm2',
      'title': 'Play 1 rated battle or tournament game',
      'progress': 1,
      'target': 1,
      'xp': 25,
      'done': true,
      'action': {
        'route': '/battle',
        'params': {'subject': 'physics'},
      },
    },
    {'id': 'broken'},
  ],
  'bonus': {'xp': 100, 'coins': 25, 'done': false},
  'streak': {'days': 4, 'today_done': false, 'freezes': 1},
  'swaps_left': swapsLeft,
};

void main() {
  group('models', () {
    test('missions read like Home\'s section, skipping unreadable ones', () {
      final day = MissionsDay.fromJson(missionsJson());
      expect(day.day, '2026-09-27');
      expect(day.items, hasLength(2));
      expect(day.items.first.fraction, 0.6);
      expect(day.items.last.action!.location, '/battle?subject=physics');
      expect(day.doneCount, 1);
      expect(day.allDone, isFalse);
      expect(day.recommended!.id, 'm1');
      expect(day.bonus.coins, 25);
      expect(day.streak.days, 4);
      expect(day.streak.freezes, 1);
      expect(day.swapsLeft, 1);
      // Round-trips, so Home can cache it.
      expect(MissionsDay.fromJson(jsonDecode(jsonEncode(day.toJson()))).items, hasLength(2));
    });

    test('the swap count defaults to one when the server leaves it out', () {
      final json = missionsJson()..remove('swaps_left');
      expect(MissionsDay.fromJson(json).swapsLeft, 1);
    });

    test('the streak calendar is sorted oldest first with its states', () {
      final streak = StreakCalendar.fromJson(const {
        'days': 4,
        'best': 12,
        'freezes': 1,
        'calendar': [
          {'day': '2026-09-27', 'state': 'missed'},
          {'day': '2026-09-25', 'state': 'frozen'},
          {'day': '2026-09-26', 'state': 'active'},
        ],
      });
      expect(streak.calendar.map((d) => d.day.day), [25, 26, 27]);
      expect(streak.calendar.map((d) => d.state), [
        StreakDayState.frozen,
        StreakDayState.active,
        StreakDayState.missed,
      ]);
      expect(streak.freezesUsed, 1);
      expect(streak.freezePrice, 50);
      expect(streak.maxFreezes, 2);
      expect(streak.canHoldMore, isTrue);
    });

    test('achievements split into earned and in progress', () {
      final achievements = Achievements.fromJson(const {
        'items': [
          {
            'id': 'a1',
            'title': 'On fire',
            'description': 'Keep a 7-day streak.',
            'icon': 'fire',
            'earned_at': '2026-09-20T10:00:00Z',
            'progress': 7,
            'target': 7,
            'coins': 30,
          },
          {
            'id': 'a2',
            'title': 'Ten wins',
            'description': 'Win 10 rated battles.',
            'icon': 'medal',
            'earned_at': null,
            'progress': 3,
            'target': 10,
            'coins': 50,
          },
        ],
      });
      expect(achievements.earned.single.title, 'On fire');
      expect(achievements.locked.single.fraction, closeTo(0.3, 1e-9));
    });
  });

  group('api', () {
    (ApiMissionsRepository, FakeAdapter) build(
      FutureOr<ResponseBody> Function(RequestOptions options) handler,
    ) {
      final adapter = FakeAdapter(handler);
      final dio = Dio(BaseOptions(baseUrl: 'http://api.test', contentType: Headers.jsonContentType))
        ..httpClientAdapter = adapter;
      return (ApiMissionsRepository(ApiClient(dio)), adapter);
    }

    test('missions and a swap', () async {
      final (repo, adapter) = build((_) => jsonBody(missionsJson(swapsLeft: 0)));
      await repo.missions();
      expect(adapter.requests.last.path, '/v1/me/missions');

      final swapped = await repo.swap('m/1');
      expect(adapter.requests.last.method, 'POST');
      expect(adapter.requests.last.uri.path, '/v1/me/missions/m%2F1/swap');
      expect(swapped.swapsLeft, 0);
    });

    test('a swap answered with less than the whole day reads the day again', () async {
      final (repo, adapter) = build(
        (options) => options.method == 'POST' ? jsonBody({'id': 'm9'}) : jsonBody(missionsJson()),
      );
      final day = await repo.swap('m1');
      expect(adapter.requests.map((r) => r.method), ['POST', 'GET']);
      expect(day.items, hasLength(2));
    });

    test('buying a freeze sends the idempotency key', () async {
      final (repo, adapter) = build((_) => jsonBody({'freezes': 2, 'coins': 195}));
      final result = await repo.buyFreeze(idempotencyKey: 'k1');
      expect(adapter.requests.single.path, '/v1/me/streak/freezes');
      expect(adapter.requests.single.headers['Idempotency-Key'], 'k1');
      expect(result.freezes, 2);
      expect(result.coins, 195);
    });

    test('not enough coins is a conflict with its code', () async {
      final (repo, _) = build(
        (_) => jsonBody({
          'error': {'code': 'INSUFFICIENT_COINS', 'message': 'Not enough coins.'},
        }, status: 409),
      );
      await expectLater(
        repo.buyFreeze(idempotencyKey: 'k'),
        throwsA(isA<ConflictFailure>().having((f) => f.code, 'code', 'INSUFFICIENT_COINS')),
      );
    });

    test('the streak asks for 30 days; achievements have their own path', () async {
      final (repo, adapter) = build(
        (options) => options.path == '/v1/me/streak'
            ? jsonBody({'days': 0, 'best': 0, 'freezes': 0, 'calendar': <Object>[]})
            : jsonBody({'items': <Object>[]}),
      );
      await repo.streak();
      expect(adapter.requests.last.queryParameters, {'days': 30});
      await repo.achievements();
      expect(adapter.requests.last.path, '/v1/me/achievements');
    });
  });

  group('fake server', () {
    late FakeMissionsRepository repo;
    setUp(() => repo = FakeMissionsRepository.seeded(today: DateTime.utc(2026, 9, 27)));

    test('one free swap a day, never for a done mission', () async {
      await expectLater(
        repo.swap('m-rated'),
        throwsA(isA<ConflictFailure>().having((f) => f.code, 'code', 'MISSION_DONE')),
      );
      final day = await repo.swap('m-practice');
      expect(day.items.first.id, 'm-chapter');
      expect(day.swapsLeft, 0);
      await expectLater(
        repo.swap('m-review'),
        throwsA(isA<ConflictFailure>().having((f) => f.code, 'code', 'SWAP_USED')),
      );
    });

    test('freezes cost 50, at most 2 are held, and a repeated key buys once', () async {
      final first = await repo.buyFreeze(idempotencyKey: 'a');
      expect(first.freezes, 2);
      expect(repo.coins, 195);
      final again = await repo.buyFreeze(idempotencyKey: 'a');
      expect(again.freezes, 2);
      expect(repo.coins, 195);
      await expectLater(
        repo.buyFreeze(idempotencyKey: 'b'),
        throwsA(isA<ConflictFailure>().having((f) => f.code, 'code', 'LIMIT_REACHED')),
      );
    });

    test('the calendar ends today', () async {
      final streak = await repo.streak();
      expect(streak.calendar, hasLength(30));
      expect(streak.calendar.last.day, DateTime.utc(2026, 9, 27));
    });
  });
}
