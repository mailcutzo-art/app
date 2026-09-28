import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_app/core/auth/user.dart';
import 'package:quiz_app/core/network/api_client.dart';
import 'package:quiz_app/core/network/app_failure.dart';
import 'package:quiz_app/core/notifications/local_reminders.dart';
import 'package:quiz_app/features/arena/data/fake_tournament_repository.dart';
import 'package:quiz_app/features/arena/data/tournament_models.dart';
import 'package:quiz_app/features/arena/data/tournament_repository.dart';
import 'package:quiz_app/features/arena/tournament_reminders.dart';
import 'package:quiz_app/features/leaderboards/data/leaderboard_models.dart';

import '../../support/arena_samples.dart';
import '../../support/fakes.dart';

const _me = PlayerCard(id: 'u1', displayName: 'Aarav', handle: 'aarav');

void main() {
  group('ApiTournamentRepository', () {
    late FakeAdapter adapter;
    late ApiTournamentRepository repo;

    setUp(() {
      adapter = FakeAdapter((options) {
        final path = options.path;
        if (path == '/v1/tournaments' || path == '/v1/me/tournaments') {
          return jsonBody({
            'items': [card()],
            'next_cursor': 'c2',
          });
        }
        if (path.endsWith('/standings')) return jsonBody({'items': <Object?>[], 'me': null});
        if (path.endsWith('/me')) return jsonBody({'rounds': <Object?>[]});
        if (options.method == 'DELETE') return jsonBody({'tournament': card(), 'refunded': 25});
        if (path.endsWith('/register') && options.method == 'POST') {
          return jsonBody({
            'error': {
              'code': 'SCHEDULE_CONFLICT',
              'message': 'Overlaps.',
              'details': {'title': 'Biology Speed Run'},
            },
          }, status: 409);
        }
        return jsonBody(card());
      });
      repo = ApiTournamentRepository(
        ApiClient(Dio(BaseOptions(baseUrl: 'http://api.test'))..httpClientAdapter = adapter),
      );
    });

    test('lists by status and exam, and pages', () async {
      final page = await repo.list(ArenaFilter.live, goal: Goal.jee, cursor: 'c1');
      expect(page.items.single.id, 't1');
      expect(page.nextCursor, 'c2');
      final request = adapter.requests.single;
      expect(request.path, '/v1/tournaments');
      expect(request.queryParameters, {'status': 'live', 'goal': 'jee', 'cursor': 'c1'});
      await repo.mine();
      expect(adapter.requests.last.path, '/v1/me/tournaments');
    });

    test('reads a tournament, its standings and my games', () async {
      await repo.detail('t 1');
      await repo.standings('t1', cursor: '20');
      await repo.myGames('t1');
      expect(adapter.requests.map((r) => r.path), [
        '/v1/tournaments/t%201',
        '/v1/tournaments/t1/standings',
        '/v1/tournaments/t1/me',
      ]);
      expect(adapter.requests[1].queryParameters, {'cursor': '20'});
    });

    test('register sends the Idempotency-Key and surfaces the error code', () async {
      await expectLater(
        repo.register('t1', idempotencyKey: 'key-1'),
        throwsA(
          isA<ConflictFailure>()
              .having((f) => f.code, 'code', ArenaErrors.scheduleConflict)
              .having((f) => f.details['title'], 'title', 'Biology Speed Run'),
        ),
      );
      final request = adapter.requests.single;
      expect(request.method, 'POST');
      expect(request.path, '/v1/tournaments/t1/register');
      expect(request.headers['Idempotency-Key'], 'key-1');
    });

    test('withdraw is a DELETE of the registration; check-in a POST', () async {
      final withdrawal = await repo.withdraw('t1');
      expect(withdrawal.refunded, 25);
      await repo.checkIn('t1');
      expect(adapter.requests.map((r) => '${r.method} ${r.path}'), [
        'DELETE /v1/tournaments/t1/register',
        'POST /v1/tournaments/t1/check-in',
      ]);
    });
  });

  group('FakeTournamentRepository', () {
    final now = DateTime.utc(2026, 9, 28, 10);
    late FakeTournamentRepository repo;

    setUp(() => repo = FakeTournamentRepository.seeded(me: _me, now: () => now));

    test('the seeded schedule has a tournament in every state', () async {
      final statuses = {for (final t in repo.tournaments) t.card.status};
      expect(statuses, TournamentStatus.values.toSet()..remove(TournamentStatus.finalizing));
      final open = await repo.list(ArenaFilter.open, goal: Goal.neet);
      expect(open.items.map((t) => t.id), isNot(contains(SeededTournaments.otherExam)));
      final all = await repo.list(ArenaFilter.open);
      expect(all.items.map((t) => t.id), contains(SeededTournaments.otherExam));
      final mine = await repo.mine();
      expect(mine.items.first.tournament.status.isOver, isFalse, reason: 'active ones first');
      expect(mine.items.last.result, isNotNull);
    });

    test('registering holds the fee and grows the pool; withdrawing returns it', () async {
      final moves = <int>[];
      repo.onCoins = (delta, _, _) => moves.add(delta);
      final coins = repo.coins;
      final t = await repo.register(SeededTournaments.open, idempotencyKey: 'k');
      expect(t.entered, isTrue);
      expect(t.players, 6);
      expect(t.effectivePool, effectivePoolFor(2500, 6));
      expect(repo.coins, coins - 25);
      expect(repo.registerKeys, ['k']);

      final again = await repo.register(SeededTournaments.open, idempotencyKey: 'k');
      expect(again.players, 6, reason: 'a retry never registers twice');

      final withdrawal = await repo.withdraw(SeededTournaments.open);
      expect(withdrawal.refunded, 25);
      expect(withdrawal.tournament.me, isNull);
      expect(repo.coins, coins);
      expect(moves, [-25, 25]);
    });

    test('every registration error is reproduced', () async {
      Future<String?> code(String id) async {
        try {
          await repo.register(id, idempotencyKey: 'k-$id');
          return null;
        } on AppFailure catch (failure) {
          return failure.code;
        }
      }

      expect(await code(SeededTournaments.full), ArenaErrors.full);
      expect(await code(SeededTournaments.locked), ArenaErrors.registrationClosed);
      expect(await code(SeededTournaments.otherExam), ArenaErrors.notAllowed);
      repo.noShowBlock = true;
      expect(await code(SeededTournaments.open), ArenaErrors.notAllowed);
      expect(await code(SeededTournaments.openFree), isNull, reason: 'free ones stay open');
      repo.noShowBlock = false;
      repo.coins = 5;
      expect(await code(SeededTournaments.open), ArenaErrors.insufficientCoins);
    });

    test('overlapping tournaments clash', () async {
      repo.add(
        FakeTournament(
          card: Tournament(
            id: 'clash',
            title: 'Physics Rapid',
            status: TournamentStatus.regOpen,
            startsAt: now.add(const Duration(hours: 6, minutes: 10)),
            rounds: 3,
            capacity: 32,
          ),
        ),
      );
      await repo.register(SeededTournaments.openFree, idempotencyKey: 'a');
      await expectLater(
        repo.register('clash', idempotencyKey: 'b'),
        throwsA(isA<ConflictFailure>().having((f) => f.code, 'code', ArenaErrors.scheduleConflict)),
      );
    });

    test('check-in only in its window, and only when registered', () async {
      final checked = await repo.checkIn(SeededTournaments.checkIn);
      expect(checked.checkedIn, isTrue);
      await expectLater(
        repo.checkIn(SeededTournaments.open),
        throwsA(isA<ConflictFailure>().having((f) => f.code, 'code', ArenaErrors.notRegistered)),
      );
      await repo.register(SeededTournaments.open, idempotencyKey: 'k');
      await expectLater(
        repo.checkIn(SeededTournaments.open),
        throwsA(isA<ConflictFailure>().having((f) => f.code, 'code', ArenaErrors.checkInClosed)),
      );
    });

    test('leaving a running tournament keeps the standings row without a refund', () async {
      final withdrawal = await repo.withdraw(SeededTournaments.live);
      expect(withdrawal.refunded, 0);
      expect(withdrawal.tournament.me!.withdrawn, isTrue);
      final standings = await repo.standings(SeededTournaments.live);
      expect(standings.me!.withdrawn, isTrue);
    });

    test('standings page with my row; my games of the live one', () async {
      final page = await repo.standings(SeededTournaments.finished);
      expect(page.items, hasLength(20));
      expect(page.nextCursor, '20');
      expect(page.me!.user.id, 'u1');
      final games = await repo.myGames(SeededTournaments.live);
      expect(games.rounds.single.result, GameResult.win);
      expect(games.record.display, '1–0');
      final detail = await repo.detail(SeededTournaments.live);
      expect(detail.currentRound, 2);
      expect(detail.schedule.map((r) => r.status), [
        RoundStatus.done,
        RoundStatus.pairing,
        RoundStatus.upcoming,
      ]);
    });

    test('failures are injectable per call', () async {
      repo.failures[FakeArenaOp.detail] = const NetworkFailure();
      await expectLater(repo.detail(SeededTournaments.open), throwsA(isA<NetworkFailure>()));
      await expectLater(repo.detail('missing'), throwsA(isA<NetworkFailure>()));
      repo.failures.clear();
      await expectLater(repo.detail('missing'), throwsA(isA<NotFoundFailure>()));
    });
  });

  group('TournamentReminders', () {
    final now = DateTime.utc(2026, 9, 28, 10);
    final t = Tournament(
      id: 't1',
      title: 'Physics Blitz',
      status: TournamentStatus.regOpen,
      startsAt: now.add(const Duration(hours: 3)),
      rounds: 3,
      capacity: 32,
    );

    test('three reminders, with ids that are the same on every run', () async {
      final scheduler = MemoryReminderScheduler();
      final reminders = TournamentReminders(scheduler, now: () => now);
      expect(await reminders.scheduleFor(t), ReminderPermission.granted);
      final scheduled = scheduler.scheduled.values.toList()..sort((a, b) => a.at.compareTo(b.at));
      expect(scheduled.map((r) => r.at), [
        t.startsAt.subtract(const Duration(hours: 1)),
        t.startsAt.subtract(const Duration(minutes: 15)),
        t.startsAt,
      ]);
      expect(scheduled.map((r) => r.title), [
        'Physics Blitz starts in 1 hour',
        'Check in for Physics Blitz',
        'Physics Blitz is starting',
      ]);
      expect(scheduled.every((r) => r.route == '/arena/t1'), isTrue);
      expect(TournamentReminders.idFor('t1', 0), TournamentReminders.idFor('t1', 0));
      expect(TournamentReminders.idFor('t1', 0), isNot(TournamentReminders.idFor('t1', 1)));
      expect(TournamentReminders.idFor('t1', 2), isNonNegative);

      await reminders.cancelFor('t1');
      expect(scheduler.scheduled, isEmpty);
      expect(scheduler.cancelled, hasLength(3));
    });

    test('reminders already in the past are skipped', () {
      final soon = TournamentReminders(
        MemoryReminderScheduler(),
        now: () => t.startsAt.subtract(const Duration(minutes: 30)),
      );
      expect(soon.remindersFor(t).map((r) => r.title), [
        'Check in for Physics Blitz',
        'Physics Blitz is starting',
      ]);
    });

    test('nothing is scheduled without permission', () async {
      final scheduler = MemoryReminderScheduler(permission: ReminderPermission.denied);
      final reminders = TournamentReminders(scheduler, now: () => now);
      expect(await reminders.scheduleFor(t), ReminderPermission.denied);
      expect(scheduler.scheduled, isEmpty);
    });

    test('the calendar entry runs from the start to the estimated end', () {
      final event = TournamentReminders.calendarEvent(t);
      expect(event.title, 'Physics Blitz');
      expect(event.start, t.startsAt);
      expect(event.end, t.startsAt.add(const Duration(minutes: 20)));
      expect(event.description, contains('quizarena://open/t/t1'));
    });
  });
}
