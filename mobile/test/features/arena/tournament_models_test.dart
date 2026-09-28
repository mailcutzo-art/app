import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_app/core/auth/user.dart';
import 'package:quiz_app/core/network/app_failure.dart';
import 'package:quiz_app/features/arena/arena_text.dart';
import 'package:quiz_app/features/arena/data/tournament_models.dart';
import 'package:quiz_app/features/arena/data/tournament_repository.dart';

import '../../support/arena_samples.dart';

void main() {
  group('the card', () {
    test('reads every field and derives the lines the Arena shows', () {
      final t = Tournament.fromJson(
        card(me: {'registered': true, 'checked_in': false, 'withdrawn': false}),
      );
      expect(t.status, TournamentStatus.regOpen);
      expect(t.status.filter, ArenaFilter.open);
      expect(t.goal, TournamentGoal.neet);
      expect(t.entered, isTrue);
      expect(t.checkedIn, isFalse);
      expect(t.needed, 3);
      expect(t.poolGrows, isTrue);
      expect(neededLine(t), '5 of 8 needed');
      expect(prizeLine(t), 'Prize now 390 of 2,500 · grows with players');
      expect(t.startsAt, DateTime.utc(2026, 10, 4, 12, 30));
      expect(Tournament.fromJson(t.toJson()).toJson(), t.toJson());
    });

    test('unknown statuses and exams stay readable; a missing required field does not', () {
      final t = Tournament.fromJson({...card(), 'status': 'paused', 'goal': 'upsc'});
      expect(t.status, TournamentStatus.scheduled);
      expect(t.goal, TournamentGoal.any);
      expect(() => Tournament.fromJson({...card(), 'starts_at': null}), throwsFormatException);
    });

    test('every status maps to its Arena filter', () {
      final filters = {for (final status in TournamentStatus.values) status: status.filter};
      expect(filters, {
        TournamentStatus.scheduled: ArenaFilter.upcoming,
        TournamentStatus.regOpen: ArenaFilter.open,
        TournamentStatus.checkIn: ArenaFilter.open,
        TournamentStatus.locked: ArenaFilter.upcoming,
        TournamentStatus.running: ArenaFilter.live,
        TournamentStatus.finalizing: ArenaFilter.live,
        TournamentStatus.finished: ArenaFilter.finished,
        TournamentStatus.cancelled: ArenaFilter.finished,
      });
    });

    test('check-in is open from 15 to 2 minutes before the start', () {
      final t = Tournament.fromJson(card(status: 'check_in'));
      final start = t.startsAt;
      expect(t.checkInOpen(start.subtract(const Duration(minutes: 16))), isFalse);
      expect(t.checkInOpen(start.subtract(const Duration(minutes: 15))), isTrue);
      expect(t.checkInOpen(start.subtract(const Duration(minutes: 3))), isTrue);
      expect(t.checkInOpen(start.subtract(const Duration(minutes: 2))), isFalse);
      final open = Tournament.fromJson(card());
      expect(
        open.checkInOpen(start.subtract(const Duration(minutes: 10))),
        isFalse,
        reason: 'only in the check-in (or locked) state',
      );
    });
  });

  group('what the card button does', () {
    final start = DateTime.utc(2026, 10, 4, 12, 30);
    CardAction action(Map<String, Object?> json, {Duration before = const Duration(hours: 3)}) =>
        cardAction(Tournament.fromJson(json), start.subtract(before), goal: Goal.neet);

    test('open tournaments: Register, Full, or not your exam', () {
      expect(action(card()), CardAction.register);
      expect(action(card(players: 64)), CardAction.full);
      expect(action(card(goal: 'jee')), CardAction.otherExam);
      expect(action(card(status: 'locked')), CardAction.locked);
      expect(action(card(status: 'scheduled')), CardAction.view);
    });

    test('an entry: Registered, then Check in in the window, then Checked in', () {
      const registered = {'registered': true, 'checked_in': false, 'withdrawn': false};
      const checkedIn = {'registered': true, 'checked_in': true, 'withdrawn': false};
      expect(action(card(me: registered)), CardAction.registered);
      expect(
        action(
          card(status: 'check_in', me: registered),
          before: const Duration(minutes: 10),
        ),
        CardAction.checkIn,
      );
      expect(
        action(
          card(status: 'check_in', me: checkedIn),
          before: const Duration(minutes: 10),
        ),
        CardAction.checkedIn,
      );
      expect(CardAction.checkIn.primary && CardAction.register.primary, isTrue);
      expect(CardAction.full.enabled, isFalse);
    });

    test('live and finished: Open or Watch, Results or View', () {
      const entered = {'registered': true, 'checked_in': true, 'withdrawn': false};
      expect(action(card(status: 'running', me: entered)), CardAction.open);
      expect(action(card(status: 'running')), CardAction.watch);
      expect(action(card(status: 'finished', me: entered)), CardAction.results);
      expect(action(card(status: 'cancelled')), CardAction.view);
    });
  });

  group('text', () {
    final now = DateTime(2026, 10, 4, 9);

    test('start lines', () {
      Tournament at(DateTime startsAt, [String status = 'reg_open']) =>
          Tournament.fromJson(card(status: status, startsAt: startsAt.toUtc().toIso8601String()));
      expect(startLine(at(now.add(const Duration(minutes: 12))), now), 'Starts in 12 min');
      expect(startLine(at(DateTime(2026, 10, 4, 18, 30)), now), 'Today, 18:30');
      expect(startLine(at(DateTime(2026, 10, 5, 7)), now), 'Tomorrow, 07:00');
      expect(startLine(at(DateTime(2026, 10, 10, 19)), now), 'Sat 10 Oct, 19:00');
      expect(startLine(at(DateTime(2026, 10, 4, 8, 30), 'running'), now), 'Started 08:30');
    });

    test('status badges', () {
      final now = DateTime.utc(2026, 10, 4, 10);
      String? label(String status) =>
          statusBadge(Tournament.fromJson(card(status: status)), now)?.label;
      expect(label('reg_open'), 'Registration');
      expect(label('check_in'), 'Check-in open');
      expect(label('locked'), 'Locked');
      expect(label('running'), isNull, reason: 'the LIVE badge says it');
      expect(label('finished'), 'Finished');
    });

    test('small helpers', () {
      expect(ordinal(1), '1st');
      expect(ordinal(2), '2nd');
      expect(ordinal(3), '3rd');
      expect(ordinal(11), '11th');
      expect(ordinal(22), '22nd');
      expect(formatPoints(2), '2');
      expect(formatPoints(2.5), '2.5');
      expect(mmss(const Duration(seconds: 48)), '0:48');
      expect(subjectName(null), 'All subjects');
      expect(subjectName('biology'), 'Biology');
      expect(const TournamentRecord(wins: 2).display, '2–0');
      expect(const TournamentRecord(wins: 2, draws: 1, losses: 1).display, '2–1–1');
    });
  });

  group('prizes and rounds', () {
    test('the pool grows to its full size at 32 players', () {
      expect(effectivePoolFor(2500, 5), 390);
      expect(effectivePoolFor(2500, 32), 2500);
      expect(effectivePoolFor(2500, 100), 2500);
    });

    test('the split follows the field size; the remainder goes to 1st', () {
      expect(prizeTableFor(1000, 3), isEmpty, reason: 'no prizes under 4 players');
      final seven = prizeTableFor(3200, 7);
      expect([for (final p in seven) p.coins], [490, 210]);
      final twenty = prizeTableFor(3200, 20);
      expect([for (final p in twenty) p.places], ['1st', '2nd', '3rd', '4th–5th']);
      final effective = effectivePoolFor(3200, 20);
      final paid = twenty.fold(0, (sum, p) => sum + p.coins * (p.to - p.from + 1));
      expect(paid, effective);
      final big = prizeTableFor(10000, 200);
      expect(big.last.places, '11th–30th');
    });

    test('small fields play fewer rounds', () {
      expect(roundsPlayed(5, 64), 5);
      expect(roundsPlayed(5, 4), 3);
      expect(roundsPlayed(6, 9), 6);
      expect(roundsPlayed(3, 9), 3);
      expect(roundsPlayed(5, 2), 1);
    });
  });

  group('the other payloads', () {
    test('detail: rules, schedule, prizes and my standing with the next pairing', () {
      final detail = TournamentDetail.fromJson({
        ...card(status: 'running'),
        'description': 'Five rounds.',
        'rules': const {'questions': 10, 'seconds_per_question': 15, 'rated': true},
        'schedule': const [
          {'round': 1, 'starts_at': '2026-10-04T12:30:00Z', 'status': 'done'},
          {'round': 2, 'status': 'pairing'},
        ],
        'prizes': const [
          {'from': 1, 'to': 1, 'coins': 195},
          {'from': 6, 'to': 10, 'coins': 18},
        ],
        'current_round': 2,
        'me': {
          'registered': true,
          'checked_in': true,
          'record': const {'wins': 1, 'draws': 0, 'losses': 0},
          'points': 1,
          'rank': 4,
          'next_pairing': {
            'round': 2,
            'opponent': user('u9'),
            'match_id': 'm2',
            'ready_by': '2026-10-04T12:41:30Z',
          },
          'final': null,
        },
      });
      expect(detail.description, 'Five rounds.');
      expect(detail.rules.readySeconds, 90, reason: 'defaults fill what is absent');
      expect(detail.schedule.map((r) => r.status), [RoundStatus.done, RoundStatus.pairing]);
      expect(detail.totalRounds, 2);
      expect(detail.prizes.last.places, '6th–10th');
      expect(detail.currentRound, 2);
      expect(detail.me!.entry.checkedIn, isTrue);
      expect(detail.me!.record.display, '1–0');
      expect(detail.me!.rank, 4);
      expect(detail.me!.nextPairing!.opponent!.displayName, 'Player u9');
      expect(detail.me!.nextPairing!.matchId, 'm2');
      expect(TournamentDetail.fromJson(detail.toJson()).toJson(), detail.toJson());
    });

    test('standings, my games, my tournaments and a withdrawal', () {
      final standings = StandingsPage.fromJson({
        'items': [
          {'position': 1, 'user': user('a'), 'points': 3, 'w': 3, 'd': 0, 'l': 0, 'bh_c1': 5},
          const {'position': 2, 'user': 'broken'},
        ],
        'next_cursor': '20',
        'me': {'position': 12, 'user': user('u1'), 'points': 1.5, 'w': 1, 'd': 1, 'l': 1},
        'round': 3,
      });
      expect(standings.items, hasLength(1), reason: 'an unreadable row is skipped');
      expect(standings.items.single.record.display, '3–0');
      expect(standings.me!.points, 1.5);
      expect(standings.nextCursor, '20');

      final games = MyGames.fromJson({
        'rounds': [
          {'round': 1, 'opponent': user('a'), 'result': 'win', 'points': 1, 'match_id': 'm1'},
          const {'round': 2, 'bye': true, 'points': 1},
          {'round': 3, 'opponent': user('b'), 'result': null, 'match_id': 'm3'},
        ],
        'current': {'round': 3, 'opponent': user('b'), 'match_id': 'm3'},
        'record': const {'wins': 1},
        'points': 2,
        'rank': 2,
      });
      expect(games.rounds.map((g) => g.result), [GameResult.win, null, null]);
      expect(games.rounds[1].bye, isTrue);
      expect(games.current!.round, 3);

      final mine = MyTournament.fromJson({
        ...card(status: 'finished'),
        'players': 24,
        'final_rank': 3,
        'prize': 120,
        'xp': 50,
        'points': 3.5,
      });
      expect(mine.result!.placeLine, '#3 of 24');
      expect(mine.result!.prize, 120);
      expect(MyTournament.fromJson(card()).result, isNull);

      final withdrawal = Withdrawal.fromJson({'tournament': card(), 'refunded': 25});
      expect(withdrawal.refunded, 25);
    });
  });

  group('error messages', () {
    final t = Tournament.fromJson(card(goal: 'jee'));
    String message(String code, [Map<String, Object?> details = const {}]) => arenaErrorMessage(
      ConflictFailure('raw server text', code: code, details: details),
      tournament: t,
    );

    test('every tournament error code reads clearly', () {
      expect(message(ArenaErrors.full), 'This tournament is full.');
      expect(message(ArenaErrors.registrationClosed), contains('Registration has closed'));
      expect(message(ArenaErrors.insufficientCoins), startsWith('You need 25 coins'));
      expect(message(ArenaErrors.insufficientCoins, {'needed': 40}), startsWith('You need 40'));
      expect(
        message(ArenaErrors.scheduleConflict, {'title': 'Biology Speed Run'}),
        'It overlaps Biology Speed Run, which you already entered.',
      );
      expect(message(ArenaErrors.scheduleConflict), contains('another tournament'));
      expect(message(ArenaErrors.notAllowed, {'reason': 'no_shows'}), contains('paused for 7'));
      expect(
        message(ArenaErrors.notAllowed, {'reason': 'exam'}),
        'This tournament is for JEE '
        'players.',
      );
      expect(message(ArenaErrors.checkInClosed), contains('15 to 2 minutes'));
      expect(message(ArenaErrors.notRegistered), contains('not registered'));
      expect(arenaErrorMessage(const NetworkFailure()), const NetworkFailure().message);
      expect(arenaErrorMessage(StateError('x')), 'Something went wrong. Please try again.');
    });
  });
}
