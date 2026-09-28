import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:quiz_app/core/network/api_client.dart';
import 'package:quiz_app/features/practice/data/practice_models.dart';
import 'package:quiz_app/features/profile/data/profile_models.dart';
import 'package:quiz_app/features/profile/data/profile_repository.dart';

import '../../support/fakes.dart';

const _stats = {
  'level': {'level': 7, 'into_level': 140, 'for_next': 400},
  'ratings': [
    {
      'scope': 'overall',
      'rating': {'display': '1523', 'value': 1523, 'provisional': false},
      'position': 42,
    },
    {
      'scope': 'organic_chemistry',
      'rating': {'display': '1498?', 'value': 1498, 'provisional': true},
      'position': null,
    },
  ],
  'record': {
    'rated': {'wins': 12, 'draws': 2, 'losses': 8},
    'casual': {'w': 3, 'd': 0, 'l': 1},
  },
  'accuracy': 0.684,
  'questions_answered': 1240,
  'streak': {'current': 4, 'best': 11},
  'rating_history': [
    {'at': '2026-09-01T00:00:00Z', 'value': 1500},
    {'at': '2026-09-20T00:00:00Z', 'value': 1523},
  ],
};

void main() {
  group('PlayerStats', () {
    test('reads the documented shape', () {
      final stats = PlayerStats.fromJson(_stats);
      expect(stats.level!.level, 7);
      expect(stats.level!.progress, closeTo(0.35, 0.001));
      expect(stats.ratings.first.label, 'Overall');
      expect(stats.ratings.first.position, 42);
      expect(stats.ratings.last.label, 'Organic chemistry');
      expect(stats.ratings.last.rating.provisional, isTrue);
      expect(stats.ratings.last.position, isNull);
      expect(stats.records['rated']!.compact, '12W 2D 8L');
      expect(stats.records['casual']!.wins, 3, reason: 'short keys read too');
      expect(stats.total.played, 26);
      expect(stats.accuracy, closeTo(0.684, 0.0001));
      expect(stats.questionsAnswered, 1240);
      expect(stats.currentStreak, 4);
      expect(stats.bestStreak, 11);
      expect(stats.ratingHistory.map((p) => p.value), [1500, 1523]);
    });

    test('a new player has empty stats, and a percentage accuracy reads too', () {
      final fresh = PlayerStats.fromJson(const {});
      expect(fresh.level, isNull);
      expect(fresh.ratings, isEmpty);
      expect(fresh.accuracy, isNull);
      expect(fresh.total.played, 0);
      expect(PlayerStats.fromJson(const {'accuracy': 68}).accuracy, closeTo(0.68, 0.0001));
    });
  });

  test('a match history row reads the documented shape', () {
    final match = MatchHistoryItem.fromJson(const {
      'id': 'm1',
      'kind': 'group',
      'subject': 'physics',
      'chapters': ['Kinematics'],
      'played_at': '2026-09-27T16:00:00Z',
      'result': 'loss',
      'reason': 'normal',
      'score': {'me': 510, 'best_other': 700},
      'opponents': [
        {
          'id': 'u2',
          'handle': 'riya_s',
          'display_name': 'Riya',
          'avatar': {'tone': 'rose', 'symbol': 'dna'},
          'level': 6,
        },
      ],
      'rating_delta': null,
      'coins_delta': 0,
      'place': 2,
    });
    expect(match.kind, 'group');
    expect(match.chapters, ['Kinematics']);
    expect(match.scoreMe, 510);
    expect(match.scoreOther, 700);
    expect(match.opponents.single.displayName, 'Riya');
    expect(match.place, 2);
    expect(match.hasReview, isTrue);
    expect(
      MatchHistoryItem.fromJson(const {
        'id': 'm2',
        'played_at': '2026-09-27T16:00:00Z',
        'result': 'aborted',
      }).hasReview,
      isFalse,
    );
  });

  test('a practice history row reads the documented shape', () {
    final session = PracticeHistoryItem.fromJson(const {
      'session_id': 's1',
      'mode': 'challenge',
      'title': 'Self Challenge',
      'created_at': '2026-09-27T16:00:00Z',
      'finished_at': '2026-09-27T16:20:00Z',
      'answered': 20,
      'correct': 14,
      'score': 50,
      'max_score': 80,
    });
    expect(session.mode, PracticeMode.challenge);
    expect(session.finished, isTrue);
    expect(session.score, 50);
    final open = PracticeHistoryItem.fromJson(const {
      'session_id': 's2',
      'mode': 'chapter',
      'title': 'Physics',
      'created_at': '2026-09-27T16:00:00Z',
      'finished_at': null,
      'answered': 3,
      'correct': 2,
    });
    expect(open.finished, isFalse);
  });

  test('an opponent reads nested or flat cards', () {
    final nested = RecentOpponent.fromJson(const {
      'user': {'id': 'u2', 'handle': 'riya_s', 'display_name': 'Riya'},
      'h2h': {'wins': 3, 'draws': 1, 'losses': 2},
      'relationship': 'none',
    });
    expect(nested.user.handle, 'riya_s');
    expect(nested.h2h.compact, '3W 1D 2L');
    final flat = RecentOpponent.fromJson(const {
      'id': 'u3',
      'handle': 'kabir',
      'relationship': 'friend',
    });
    expect(flat.user.uid, 'u3');
    expect(flat.relationship, 'friend');
    expect(() => RecentOpponent.fromJson(const {'relationship': 'none'}), throwsFormatException);
  });

  test('ApiProfileRepository sends the documented requests', () async {
    final adapter = FakeAdapter(
      (options) => switch (options.path) {
        '/v1/me/stats' => jsonBody(_stats),
        '/v1/me/opponents' => jsonBody({
          'items': [
            {
              'user': {'id': 'u2', 'handle': 'riya_s'},
            },
          ],
        }),
        _ => jsonBody({'items': <Object?>[], 'next_cursor': null}),
      },
    );
    final repo = ApiProfileRepository(
      ApiClient(Dio(BaseOptions(baseUrl: 'http://api.test'))..httpClientAdapter = adapter),
    );
    await repo.stats(StatsRange.days90);
    await repo.matches();
    await repo.matches(cursor: 'c2');
    await repo.practiceSessions(cursor: 'p2');
    final opponents = await repo.opponents();
    expect(opponents.single.user.handle, 'riya_s');
    expect(
      [
        for (final r in adapter.requests)
          [
            r.path,
            for (final MapEntry(:key, :value) in r.queryParameters.entries) '$key=$value',
          ].join('?'),
      ],
      [
        '/v1/me/stats?range=90d',
        '/v1/me/matches',
        '/v1/me/matches?cursor=c2',
        '/v1/me/practice/sessions?cursor=p2',
        '/v1/me/opponents?days=30',
      ],
    );
  });
}
