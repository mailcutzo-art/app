import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_app/core/auth/user.dart';
import 'package:quiz_app/features/leaderboards/data/fake_leaderboard_repository.dart';
import 'package:quiz_app/features/leaderboards/data/leaderboard_models.dart';
import 'package:quiz_app/features/leaderboards/widgets/leaderboard_widgets.dart';

import '../../support/leaderboard_samples.dart';

void main() {
  group('parsing', () {
    test('the hub reads cards, standings and last week, skipping unreadable cards', () {
      final hub = LeaderboardHub.fromJson({
        'boards': [
          {
            'board': 'weekly_xp',
            'title': 'This week',
            'ends_at': '2026-09-28T18:30:00Z',
            'leader': rowJson(1, value: 2200),
            'me': const {'position': 318, 'value': 140, 'change_1d': 25},
          },
          {
            'board': 'rating:overall',
            'title': 'Overall rating',
            'leader': rowJson(1),
            'me': const {'position': null, 'games_to_rank': 7},
          },
          const {'board': 'broken'},
        ],
        'last_week': [rowJson(1), rowJson(2), rowJson(3)],
      });

      expect(hub.boards, hasLength(2));
      final weekly = hub.boards.first;
      expect(weekly.endsAt, DateTime.utc(2026, 9, 28, 18, 30));
      expect(weekly.leader!.user.displayName, 'Rahul');
      expect(weekly.leader!.user.avatar, const Avatar(tone: 'sky', symbol: 'atom'));
      expect(weekly.me!.position, 318);
      expect(weekly.me!.change1d, 25);
      expect(hub.boards.last.me!.ranked, isFalse);
      expect(hub.boards.last.me!.gamesToRank, 7);
      expect(hub.lastWeek, hasLength(3));
    });

    test('a board page reads rows, me, around me and not_ranked', () {
      final page = BoardPage.fromJson({
        'board': 'rating:physics',
        'title': 'Physics',
        'period': null,
        'items': [rowJson(1), rowJson(2)],
        'next_cursor': 'abc',
        'me': rowJson(42, id: 'me', change: 5),
        'around_me': [rowJson(41), rowJson(42, id: 'me')],
        'not_ranked': null,
      });
      expect(page.items, hasLength(2));
      expect(page.nextCursor, 'abc');
      expect(page.me!.position, 42);
      expect(page.me!.change1d, 5);
      expect(page.aroundMe, hasLength(2));
      expect(page.gamesToRank, isNull);

      final unranked = BoardPage.fromJson(const {
        'board': 'rating:overall',
        'title': 'Overall rating',
        'items': <Object>[],
        'me': null,
        'not_ranked': {'games_to_rank': 3},
      });
      expect(unranked.me, isNull);
      expect(unranked.gamesToRank, 3);
    });

    test('a card without a display name falls back to the handle', () {
      final card = PlayerCard.fromJson(const {'id': 'x', 'handle': 'riya'});
      expect(card.displayName, 'riya');
      expect(card.avatar, Avatar.fallback);
    });
  });

  test('board ids name their family and subject', () {
    expect(BoardFamily.of('weekly_xp'), BoardFamily.weeklyXp);
    expect(BoardFamily.of('weekly:physics'), BoardFamily.weeklySubject);
    expect(BoardFamily.of('weekly:physics:last'), BoardFamily.weeklySubject);
    expect(BoardFamily.of('rating:overall'), BoardFamily.rating);
    expect(BoardFamily.of('friends:weekly_xp'), BoardFamily.friendsWeekly);
    expect(BoardFamily.of('hall_of_fame:chemistry'), BoardFamily.hallOfFame);
    expect(boardSubject('rating:physics'), 'physics');
    expect(boardSubject('rating:overall'), isNull);
    expect(boardSubject('weekly:maths'), 'maths');
    expect(boardSubject('friends:rating'), isNull);
    expect(ExamScope.neet.shows('maths'), isFalse);
    expect(ExamScope.jee.shows('biology'), isFalse);
    expect(ExamScope.allIndia.shows('biology'), isTrue);
  });

  group('labels', () {
    final now = DateTime.utc(2026, 9, 26, 14, 30);

    test('countdowns read "Ends in 2 d 4 h"', () {
      expect(endsInLabel(DateTime.utc(2026, 9, 28, 18, 30), now), 'Ends in 2 d 4 h');
      expect(endsInLabel(now.add(const Duration(hours: 3, minutes: 20)), now), 'Ends in 3 h 20 m');
      expect(endsInLabel(now.add(const Duration(minutes: 12)), now), 'Ends in 12 m');
      expect(endsInLabel(now, now), 'Ending now');
    });

    test('the hub headline lists where the viewer stands', () {
      final boards = [
        const BoardSummary(
          board: 'rating:physics',
          title: 'Physics',
          me: BoardStanding(position: 42),
        ),
        const BoardSummary(
          board: 'weekly_xp',
          title: 'This week',
          me: BoardStanding(position: 310),
        ),
        const BoardSummary(
          board: 'rating:overall',
          title: 'Overall rating',
          me: BoardStanding(gamesToRank: 3),
        ),
        const BoardSummary(
          board: 'friends:weekly_xp',
          title: 'Friends',
          me: BoardStanding(position: 2),
        ),
      ];
      expect(hubHeadline(boards), '#42 Physics · #310 this week · Overall: 3 more rated games');
    });

    test('not-ranked messages count what is left', () {
      expect(notRankedMessage(BoardFamily.rating, 7), 'Play 7 more rated battles to appear');
      expect(notRankedMessage(BoardFamily.rating, 1), 'Play 1 more rated battle to appear');
      expect(notRankedMessage(BoardFamily.weeklySubject, 1), 'Play 1 battle to appear');
    });
  });

  group('fake server', () {
    late FakeLeaderboardRepository repo;
    setUp(() => repo = FakeLeaderboardRepository.seeded(now: DateTime.utc(2026, 9, 26)));

    test('pages hold 50 rows and stop at the top 100', () async {
      final first = await repo.board('weekly_xp');
      expect(first.items, hasLength(50));
      expect(first.items.first.position, 1);
      final second = await repo.board('weekly_xp', cursor: first.nextCursor);
      expect(second.items.first.position, 51);
      expect(second.nextCursor, isNull);
    });

    test('the viewer beyond the top 100 gets their row and the 10 either side', () async {
      final page = await repo.board('weekly_xp');
      expect(page.me, isNotNull);
      expect(page.me!.position, greaterThan(100));
      expect(page.aroundMe.where((row) => row.position < page.me!.position), hasLength(10));
    });

    test('an unrated viewer is told how many games are left', () async {
      final page = await repo.board('rating:overall');
      expect(page.me, isNull);
      expect(page.gamesToRank, 7);
    });

    test('the exam filter hides the other exam\'s subject and players', () async {
      final neet = await repo.hub(goal: Goal.neet);
      expect(neet.boards.map((b) => b.board), isNot(contains('weekly:maths')));
      expect(neet.boards.map((b) => b.board), contains('weekly:biology'));
      final all = await repo.hub();
      expect(all.boards.map((b) => b.board), containsAll(['weekly:maths', 'weekly:biology']));
      final page = await repo.board('rating:overall', goal: Goal.neet);
      final everyone = await repo.board('rating:overall');
      expect(page.players, lessThan(everyone.players!));
    });

    test('weekly boards end on Monday 00:00 IST', () async {
      final hub = await repo.hub();
      expect(hub.boards.first.endsAt, DateTime.utc(2026, 9, 27, 18, 30));
    });
  });
}
